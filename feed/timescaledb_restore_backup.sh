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
# Logging settings
LOG_FILE="~/ts_backup.log"
# Function to log messages
log_message() {
    echo "$(date +"%Y-%m-%d %T"): $1" | tee -a $LOG_FILE
}
# Function to download the backup from S3
download_from_s3() {
    log_message  "Downloading backup from S3..."
    # List the backups in S3 and sort them to find the most recent one
    LATEST_BACKUP=$(aws s3 ls $S3_BUCKET/$S3_PATH/$INSTANCE_NAME/ | sort | tail -n 1 | awk '{print $4}')
    # Download the latest backup
    aws s3 cp s3://$S3_BUCKET/$S3_PATH/$INSTANCE_NAME/$LATEST_BACKUP $LOCAL_BACKUP_PATH --recursive
    #aws s3 cp s3://$S3_BUCKET/$S3_PATH/$INSTANCE_NAME/$DATE_FORMAT $LOCAL_BACKUP_PATH --recursive
    log_message "Download complete."
}

# Function to restore the backup locally
restore_backup() {
    log_message  "Restoring backup locally..."
    pg_probackup restore -B $LOCAL_BACKUP_PATH -D $LOCAL_PGDATA_PATH --instance $INSTANCE_NAME
    log_message "Backup restored"
}

# Function to delete the backup from S3
delete_from_s3() {
    log_message  "Deleting backup from S3..."
    aws s3 rm s3://$S3_BUCKET/$S3_PATH/$INSTANCE_NAME/$DATE_FORMAT --recursive
    log_message "Backup deleted successfully"
}
# Function to verify restoration
verify_restoration() {
    log_message  "Verifying restoration..."
    local verification_query="SELECT COUNT(*) FROM book;"  # Replace with your verification query
    local result=$(psql -U $PGUSER -d $DB_NAME -c "$verification_query" -t -A)

    if [ "$result" -gt 0 ]; then  # Example condition, adjust as needed
        log_message  "Verification successful: $result"
        return 0
    else
        log_message  "Verification failed"
        return 1
    fi
}

# Download the backup from S3
download_from_s3
if [ $? -ne 0 ]; then
    log_message  "Download from S3 failed"
    exit 1
fi

restore_backup
if [ $? -ne 0 ]; then
    log_message  "Restore failed"
    exit 1
fi

verify_restoration
if [ $? -ne 0 ]; then
    log_message  "Verification of restoration failed"
    exit 1
fi

delete_from_s3
