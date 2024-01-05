#!/bin/bash

# PostgreSQL settings
DB_NAME="db0"
PGUSER="postgres"
PGHOST="localhost"
PGPORT="5432"
#PGPASSWORD=$(/home/sam/.local/share/pypoetry/venv/bin/yq e '.timescaledb_password' /config_cf.yaml)

# pg_probackup settings
BACKUP_PATH="/home/ec2-user/ts_backups"
INSTANCE_NAME="timescaledb"

# AWS S3 settings
S3_BUCKET="s3://tsbackups"

# Local paths for backup
LOCAL_BACKUP_PATH="/home/sam/ts_backups" # Define your local backup path
LOCAL_PGDATA_PATH="/home/sam/timescaledb_data" # Define your local PostgreSQL data path

# Date and time format for backup naming
DATE_FORMAT=$(date +"%Y%m%d%H%M%S")
# Logging settings
LOG_FILE="$HOME/ts_backups.log"
# Function to log messages
log_message() {
    echo "$(date +"%Y-%m-%d %T"): $1" | tee -a $LOG_FILE
}
# Function to download the backup from S3
download_from_s3() {
    log_message  "Downloading backup from S3..."
    # List the backups in S3, find the latest one, and trim to get just the directory name
    LATEST_BACKUP=$(aws s3 ls $S3_BUCKET/$INSTANCE_NAME/ | sort | tail -n 1 | awk '{print $2}' | sed 's/\/$//')
    if [ -z "$LATEST_BACKUP" ]; then
        log_message "No backup found on S3."
        return 1
    fi
    # Download the latest backup
    aws s3 cp $S3_BUCKET/$INSTANCE_NAME/$LATEST_BACKUP $LOCAL_BACKUP_PATH --recursive
    log_message "Download complete."
}

# Function to restore the backup locally
restore_backup() {
    log_message "Restoring backup locally..."
    log_message "Checking for existing full backup in $LOCAL_BACKUP_PATH..."


    # Debug: List all files found
    log_message "Files in backup directory:"
    find $LOCAL_BACKUP_PATH -name "backrest_backup_info" -exec ls -l {} \;



    local latest_full_backup=$(find $LOCAL_BACKUP_PATH -name "backrest_backup_info" -exec grep -l "backup-type=full" {} \; | sort | tail -n 1)

    if [ -n "$latest_full_backup" ]; then
        log_message "Latest full backup found locally: $latest_full_backup"
        # Extract backup ID from the path
        local full_backup_id=$(basename $(dirname $latest_full_backup))
        log_message "Using local full backup with ID: $full_backup_id for restoration."
    else
        log_message "No full backup found locally. Checking in S3..."
        # Place the logic here to download the latest full backup from S3
        # Download the backup from S3
        download_from_s3
        if [ $? -ne 0 ]; then
            log_message  "Download from S3 failed"
            exit 1
        fi
        # After downloading, recheck for the latest full backup
        latest_full_backup=$(find $LOCAL_BACKUP_PATH -name "backrest_backup_info" -exec grep -l "backup-type=full" {} \; | sort | tail -n 1)
        if [ -z "$latest_full_backup" ]; then
            log_message "No full backup found in S3 either."
            return 1
        fi
        local full_backup_id=$(basename $(dirname $latest_full_backup))
    fi

    # Restore the full backup
    pg_probackup restore -B $LOCAL_BACKUP_PATH -D $LOCAL_PGDATA_PATH --instance $INSTANCE_NAME --backup-id=$full_backup_id
    log_message "Full backup $full_backup_id restored."


    # Apply Delta backups in order
    local incremental_backups=$(find $LOCAL_BACKUP_PATH -name "backrest_backup_info" -exec grep -l "backup-type=delta" {} \; | sort)
    for backup_info in $incremental_backups; do
        local backup_id=$(basename $(dirname $backup_info))
        pg_probackup restore -B $LOCAL_BACKUP_PATH -D $LOCAL_PGDATA_PATH --instance $INSTANCE_NAME --backup-id=$backup_id
        log_message "Incremental backup $backup_id applied."
    done

    log_message "Backup restoration completed."
}


# Function to delete the backup from S3
delete_from_s3() {
    log_message  "Deleting backup from S3..."
    aws s3 rm $S3_BUCKET/$INSTANCE_NAME/$DATE_FORMAT --recursive
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

# # Download the backup from S3
# download_from_s3
# if [ $? -ne 0 ]; then
#     log_message  "Download from S3 failed"
#     exit 1
# fi

restore_backup
if [ $? -ne 0 ]; then
    log_message  "Restore failed"
    exit 1
fi

# verify_restoration
# if [ $? -ne 0 ]; then
#     log_message  "Verification of restoration failed"
#     exit 1
# fi

#delete_from_s3
