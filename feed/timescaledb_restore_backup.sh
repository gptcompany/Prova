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
    local s3_backup=$1
    log_message "Downloading backup $s3_backup from S3..."
    aws s3 cp "$S3_BUCKET/$INSTANCE_NAME/$s3_backup" "$LOCAL_BACKUP_PATH" --recursive
    log_message "Download complete."
}

# Function to find the latest full backup either locally or on S3
find_latest_full_backup() {
    local latest_local_backup
    local latest_s3_backup

    latest_local_backup=$(find "$LOCAL_BACKUP_PATH" -name "backrest_backup_info" -exec grep -l "backup-type=full" {} \; | sort | tail -n 1)
    if [ -n "$latest_local_backup" ]; then
        echo "$(basename "$(dirname "$latest_local_backup")")"
        return
    fi

    latest_s3_backup=$(aws s3 ls "$S3_BUCKET/$INSTANCE_NAME/" | grep FULL | sort | tail -n 1 | awk '{print $2}' | sed 's/\/$//')
    if [ -n "$latest_s3_backup" ]; then
        if [ ! -d "$LOCAL_BACKUP_PATH/$latest_s3_backup" ]; then
            download_from_s3 "$latest_s3_backup"
        fi
        echo "$latest_s3_backup"
        return
    fi

    log_message "No full backup found."
    return 1
}

# Function to restore the backup locally
restore_backup() {
    log_message "Restoring backup locally..."

    local full_backup_id
    full_backup_id=$(find_latest_full_backup)

    if [ -z "$full_backup_id" ]; then
        log_message "Failed to find a full backup."
        return 1
    fi

    log_message "Using full backup with ID: $full_backup_id for restoration."
    pg_probackup restore -B "$LOCAL_BACKUP_PATH" -D "$LOCAL_PGDATA_PATH" --instance "$INSTANCE_NAME" --backup-id="$full_backup_id"
    log_message "Full backup $full_backup_id restored."

    # Apply incremental backups if any
    # Add logic here to apply incremental/delta backups if necessary
}

restore_backup
