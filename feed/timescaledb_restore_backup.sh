#!/bin/bash
set -eux

# PostgreSQL settings
DB_NAME="db0"
PGUSER="postgres"
PGHOST="localhost"
PGPORT="5432"
# Uncomment the following line if you want to use it
# PGPASSWORD=$(/home/sam/.local/share/pypoetry/venv/bin/yq e '.timescaledb_password' /config_cf.yaml)

# pg_probackup settings
BACKUP_PATH="/home/ec2-user/ts_backups"
INSTANCE_NAME="timescaledb"

# AWS S3 settings
S3_BUCKET="s3://timescalebackups"

# Local paths for backup
LOCAL_BACKUP_PATH="/home/sam/ts_backups"
LOCAL_PGDATA_PATH="/home/sam/timescaledb_data"

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
    log_message "Downloading backup from S3..."
    local latest_backup
    latest_backup=$(aws s3 ls $S3_BUCKET/$INSTANCE_NAME/ | sort | tail -n 1 | awk '{print $2}' | sed 's/\/$//')
    if [ -z "$latest_backup" ]; then
        log_message "No backup found on S3."
        return 1
    fi
    aws s3 cp "$S3_BUCKET/$INSTANCE_NAME/$latest_backup" "$LOCAL_BACKUP_PATH" --recursive
    log_message "Download complete."
}

# Function to restore the backup locally
restore_backup() {
    log_message "Restoring backup locally..."
    log_message "Checking for existing full backup in $LOCAL_BACKUP_PATH..."

    log_message "Files in backup directory:"
    find "$LOCAL_BACKUP_PATH" -name "backrest_backup_info" -exec ls -l {} \;

    local latest_full_backup
    latest_full_backup=$(find "$LOCAL_BACKUP_PATH" -name "backrest_backup_info" -exec grep -l "backup-type=full" {} \; | sort | tail -n 1)

    if [ -z "$latest_full_backup" ]; then
        log_message "No full backup found locally. Checking in S3..."
        download_from_s3 || { log_message "Failed to download from S3."; return 1; }
        latest_full_backup=$(find "$LOCAL_BACKUP_PATH" -name "backrest_backup_info" -exec grep -l "backup-type=full" {} \; | sort | tail -n 1)
        if [ -z "$latest_full_backup" ]; then
            log_message "No full backup found in S3 either."
            return 1
        fi
    fi

    local full_backup_id
    full_backup_id=$(basename "$(dirname "$latest_full_backup")")
    log_message "Using local full backup with ID: $full_backup_id for restoration."
    pg_probackup restore -B "$LOCAL_BACKUP_PATH" -D "$LOCAL_PGDATA_PATH" --instance "$INSTANCE_NAME" --backup-id="$full_backup_id"
    log_message "Full backup $full_backup_id restored."

    local incremental_backups
    incremental_backups=$(find "$LOCAL_BACKUP_PATH" -name "backrest_backup_info" -exec grep -l "backup-type=delta" {} \; | sort)
    for backup_info in $incremental_backups; do
        local backup_id
        backup_id=$(basename "$(dirname "$backup_info")")
        pg_probackup restore -B "$LOCAL_BACKUP_PATH" -D "$LOCAL_PGDATA_PATH" --instance "$INSTANCE_NAME" --backup-id="$backup_id"
        log_message "Incremental backup $backup_id applied."
    done

    log_message "Backup restoration completed."
}

restore_backup
