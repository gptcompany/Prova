#!/bin/bash

# PostgreSQL settings
DB_NAME="db0"
PGUSER="postgres"
PGHOST="0.0.0.0"
PGPORT="5432"

# pg_probackup settings
BACKUP_PATH="/home/ec2-user/ts_backups"
INSTANCE_NAME="timescaledb"

# AWS S3 settings
S3_BUCKET="s3://tsbakups"
S3_PATH="/home/ec2-user/ts_backups"
# Local paths for backup
LOCAL_BACKUP_PATH="/home/sam/ts_backups" # Define your local backup path
LOCAL_PGDATA_PATH="/home/sam/timescaledb_data" # Define your local PostgreSQL data path

# Date and time format for backup naming
DATE_FORMAT=$(date +"%Y%m%d%H%M%S")

# Function to perform a pg_probackup
perform_backup() {
    echo "Starting backup for instance $INSTANCE_NAME..."
    pg_probackup backup -B $BACKUP_PATH -b DELTA -U $PGUSER -d $DB_NAME --instance $INSTANCE_NAME --stream
    echo "Backup completed."
}

# Function to upload the backup to S3
upload_to_s3() {
    echo "Uploading backup to S3..."
    aws s3 cp $BACKUP_PATH/$INSTANCE_NAME/backups s3://$S3_BUCKET/$S3_PATH/$INSTANCE_NAME/$DATE_FORMAT --recursive
    echo "Upload completed."
}
# Function to download the backup from S3
download_from_s3() {
    echo "Downloading backup from S3..."
    aws s3 cp s3://$S3_BUCKET/$S3_PATH/$INSTANCE_NAME/$DATE_FORMAT $LOCAL_BACKUP_PATH --recursive
}

# Function to restore the backup locally
restore_backup() {
    echo "Restoring backup locally..."
    pg_probackup restore -B $LOCAL_BACKUP_PATH -D $LOCAL_PGDATA_PATH --instance $INSTANCE_NAME
}

# Function to delete the backup from S3
delete_from_s3() {
    echo "Deleting backup from S3..."
    aws s3 rm s3://$S3_BUCKET/$S3_PATH/$INSTANCE_NAME/$DATE_FORMAT --recursive
}
# Function to verify restoration
verify_restoration() {
    echo "Verifying restoration..."
    local verification_query="SELECT COUNT(*) FROM your_table;"  # Replace with your verification query
    local result=$(psql -U $PGUSER -d $DB_NAME -c "$verification_query" -t -A)

    if [ "$result" -gt 0 ]; then  # Example condition, adjust as needed
        echo "Verification successful: $result"
        return 0
    else
        echo "Verification failed"
        return 1
    fi
}


# Perform the DELTA backup
perform_backup
if [ $? -ne 0 ]; then
    echo "Backup failed"
    exit 1
fi
# Perform upload to S3
upload_to_s3
if [ $? -ne 0 ]; then
    echo "Upload to S3 failed"
    exit 1
fi
# Download the backup from S3
download_from_s3
if [ $? -ne 0 ]; then
    echo "Download from S3 failed"
    exit 1
fi

restore_backup
if [ $? -ne 0 ]; then
    echo "Restore failed"
    exit 1
fi

verify_restoration
if [ $? -ne 0 ]; then
    echo "Verification of restoration failed"
    exit 1
fi

delete_from_s3

exit 0
