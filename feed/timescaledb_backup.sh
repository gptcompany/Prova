#!/bin/bash

# PostgreSQL settings
DB_NAME="db0"
PGUSER="postgres"
PGHOST="localhost"
PGPORT="5432"
PGPASSWORD="Timescaledb2023"
export PGPASSWORD
# echo "Password: $PGPASSWORD"

# pg_probackup settings
BACKUP_PATH="/home/ec2-user/ts_backups"
INSTANCE_NAME="timescaledb"

# AWS S3 settings
S3_BUCKET="s3://tsbackups"

# Date and time format for backup naming
DATE_FORMAT=$(date +"%Y%m%d%H%M%S")
# Logging settings
LOG_FILE="$HOME/ts_backups.log"
# Function to log messages
log_message() {
    echo "$(date +"%Y-%m-%d %T"): $1" | tee -a $LOG_FILE
}
# Function to perform a pg_probackup
perform_backup() {
    log_message "Starting DELTA backup for instance $INSTANCE_NAME..."
    pg_probackup backup -B $BACKUP_PATH -b DELTA -U $PGUSER -d $DB_NAME --instance $INSTANCE_NAME --stream -h $PGHOST -p $PGPORT --compress --compress-algorithm=zlib --compress-level=5

    if [ $? -ne 0 ]; then
        log_message "Backup operation failed."
        return 1
    fi

    log_message "Backup completed successfully."
    
    log_message "Cleaning old backups on $INSTANCE_NAME..."
    pg_probackup delete -B $BACKUP_PATH --instance $INSTANCE_NAME --delete-wal --retention-redundancy=2 --retention-window=7

    if [ $? -ne 0 ]; then
        log_message "Failed to clean old backups."
        return 1
    fi

    log_message "Cleaning completed successfully."
    return 0
}



# Function to upload the backup to S3
upload_to_s3() {
    # Identify the most recent backup directory
    local latest_backup_dir=$(ls -t $BACKUP_PATH/backups/$INSTANCE_NAME | head -n 1)
    if [ -z "$latest_backup_dir" ]; then
        log_message "No backup directory found."
        return 1
    fi
    local full_backup_path="$BACKUP_PATH/backups/$INSTANCE_NAME/$latest_backup_dir"

    log_message "Uploading backup $latest_backup_dir to S3..."
    aws s3 cp $full_backup_path $S3_BUCKET/$INSTANCE_NAME/$DATE_FORMAT --recursive
    log_message "Upload to S3 bucket $S3_BUCKET/$INSTANCE_NAME/$DATE_FORMAT completed."
}



# Check if a full backup is needed
full_backup_needed() {
    local last_full_backup=$(pg_probackup show -B $BACKUP_PATH --instance $INSTANCE_NAME | grep ' FULL ' | tail -1)
    if [ -z "$last_full_backup" ]; then
        return 0 # Full backup needed
    else
        return 1 # Full backup not needed
    fi
}

# Function to perform a Full backup
perform_full_backup() {
    log_message "Starting FULL backup for instance $INSTANCE_NAME..."
    pg_probackup backup -B $BACKUP_PATH -b FULL -U $PGUSER -d $DB_NAME --instance $INSTANCE_NAME --stream -h $PGHOST -p $PGPORT --compress --compress-algorithm=zlib --compress-level=5

    if [ $? -eq 0 ]; then
        log_message "FULL Backup completed successfully."
        return 0
    else
        log_message "FULL Backup failed."
        return 1
    fi
}

# Function to check for a full backup in S3
check_full_backup_in_s3() {
    log_message "Checking for full backup in S3..."
    # This command lists the contents of your S3 bucket and looks for a full backup identifier
    # Modify the grep pattern as per your naming convention for full backups
    if aws s3 ls $S3_BUCKET/$INSTANCE_NAME/ | grep -q 'FULL'; then
        log_message "Full backup found in S3."
        return 0
    else
        log_message "No full backup found in S3."
        return 1
    fi
}

# Perform the backup (Full or Delta)
if full_backup_needed && check_full_backup_in_s3; then
    perform_backup 
else
    perform_full_backup # Your existing function for Delta backup
fi

# Perform upload to S3
upload_to_s3
if [ $? -ne 0 ]; then
    log_message  "Upload to S3 failed"
    exit 1
fi

exit 0
