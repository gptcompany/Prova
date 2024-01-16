#!/bin/bash
#set -eux

# PostgreSQL settings
DB_NAME="db0"
PGUSER="postgres"
PGHOST="localhost"
PGPORT="5432"
PGPASSWORD=$(python3 -c "import yaml; print(yaml.safe_load(open('/config_cf.yaml'))['timescaledb_password'])")
export PGUSER PGHOST PGPORT PGPASSWORD
# Paths and settings
#BACKUP_PATH="/home/ec2-user/ts_backups"
INSTANCE_NAME="timescaledb"
S3_BUCKET="s3://timescalebackups"
LOCAL_BACKUP_PATH="/home/sam/ts_backups"
LOCAL_PGDATA_PATH="/home/sam/timescaledb_data"
LOG_FILE="$HOME/ts_backups.log"

# Function to log messages
log_message() {
    echo "$(date +"%Y-%m-%d %T"): $1" | tee -a $LOG_FILE
}

# Function to check if the latest FULL backup has been restored locally
check_full_backup_restored() {
    log_message "Checking if the latest full backup has been restored locally." >&2
    local last_full_backup_info=$(pg_probackup show -B $LOCAL_BACKUP_PATH --instance $INSTANCE_NAME | grep ' FULL ' | grep -v 'ERROR' | tail -1)
    log_message "Last full backup info: $last_full_backup_info" >&2

    if [ -z "$last_full_backup_info" ]; then
        log_message "No full backup found locally." >&2
        return 1
    else
        local backup_id=$(echo "$last_full_backup_info" | awk '{print $3}')
        local backup_status=$(echo "$last_full_backup_info" | awk '{print $5}')
        log_message "Last full backup ID: $backup_id, Status: $backup_status" >&2

        if [ "$backup_status" = "OK" ] || [ "$backup_status" = "DONE" ]; then
            log_message "Full backup $backup_id has been successfully restored." >&2
            return 0
        else
            log_message "Full backup $backup_id has not been restored." >&2
            return 2
        fi
    fi
}

# Function to check if a backup already exists locally
backup_exists_locally() {
    local backup_path=$1
    log_message "Checking if backup $backup_path exists locally." >&2
    if [ -d "$LOCAL_BACKUP_PATH/$backup_path" ]; then
        log_message "Backup $backup_path already exists locally." >&2
        return 0
    else
        log_message "Backup $backup_path don't exists locally." >&2
        return 1
    fi
}

# Function to download the backup from S3
download_from_s3() {
    local s3_backup=$1
    log_message "Preparing to download backup $s3_backup from S3." >&2
    if backup_exists_locally "$s3_backup"; then
        log_message "Skipping download, backup $s3_backup already exists locally." >&2
        return 0
    fi
    log_message "Downloading backup $s3_backup from S3..." >&2
    aws s3 cp "$S3_BUCKET/$INSTANCE_NAME/$s3_backup" "$LOCAL_BACKUP_PATH" --recursive
    if [ $? -eq 0 ]; then
        log_message "Download complete." >&2
        return 0
    else
        log_message "Error in downloading backup from S3." >&2
        return 1
    fi
}

# Function to find the latest full backup either locally or on S3
find_latest_full_backup() {
    log_message "Searching for the latest full backup in S3." >&2
    local latest_full_backup_info=$(aws s3 ls "$S3_BUCKET/$INSTANCE_NAME/FULL/" --recursive | awk -F 'FULL/' '{print $2}' | sort -t '/' -k1,1 -k2,2 | tail -n 1)
    log_message "Latest full backup info: $latest_full_backup_info" >&2

    if [ -n "$latest_full_backup_info" ]; then
        local backup_date=$(echo "$latest_full_backup_info" | cut -d '/' -f 1)
        local backup_id=$(echo "$latest_full_backup_info" | cut -d '/' -f 2)
        local full_backup_path="FULL/$backup_date/$backup_id"
        log_message "Full backup path: $full_backup_path" >&2

        if [ ! -d "$LOCAL_BACKUP_PATH/$full_backup_path" ]; then
            download_from_s3 "$full_backup_path"
            if [ $? -ne 0 ]; then
                log_message "Error in downloading full backup." >&2
                return 1
            fi
        fi
        echo "$full_backup_path"
        return 0
    else
        log_message "No full backup found in S3." >&2
        return 1
    fi
}

# Function to apply delta backups after restoring the full backup
apply_delta_backups() {
    local full_backup_date="$1"
    log_message "Applying delta backups after full backup date: $full_backup_date" >&2
    local delta_backups=$(aws s3 ls "$S3_BUCKET/$INSTANCE_NAME/DELTA/" --recursive | awk -F 'DELTA/' '{print $2}' | grep "^$full_backup_date" | sort -t '/' -k1,1 -k2,2)
    log_message "Delta backups: $delta_backups" >&2

    for backup_info in $delta_backups; do
        local backup_date=$(echo "$backup_info" | cut -d '/' -f 1)
        local backup_id=$(echo "$backup_info" | cut -d '/' -f 2)
        local delta_backup_path="DELTA/$backup_date/$backup_id"
        log_message "Applying delta backup: $delta_backup_path" >&2

        if [ ! -d "$LOCAL_BACKUP_PATH/$delta_backup_path" ]; then
            download_from_s3 "$delta_backup_path"
            if [ $? -ne 0 ]; then
                log_message "Error in downloading delta backup." >&2
                continue
            fi
        fi

        pg_probackup restore -B "$LOCAL_BACKUP_PATH" -D "$LOCAL_PGDATA_PATH" --instance "$INSTANCE_NAME" --backup-id="$backup_id" --incremental-mode=checksum
        if [ $? -ne 0 ]; then
            log_message "Error in applying delta backup: $delta_backup_path" >&2
        else
            log_message "Delta backup $delta_backup_path applied successfully." >&2
        fi
    done
}

# Function to restore the backup locally
restore_backup() {
    log_message "Starting backup restoration process." >&2
    local full_backup_id=$(find_latest_full_backup)
    log_message "Full backup ID for restoration: $full_backup_id" >&2

    if [ -z "$full_backup_id" ]; then
        log_message "Failed to find a full backup." >&2
        return 1
    fi

    if [ -d "$LOCAL_PGDATA_PATH" ] && [ "$(ls -A "$LOCAL_PGDATA_PATH")" ]; then
        log_message "Clearing non-empty restore directory $LOCAL_PGDATA_PATH." >&2
        rm -rf "$LOCAL_PGDATA_PATH"/*
    fi

    pg_probackup restore -B "$LOCAL_BACKUP_PATH" -D "$LOCAL_PGDATA_PATH" --instance "$INSTANCE_NAME" --backup-id="$full_backup_id"
    if [ $? -eq 0 ]; then
        log_message "Full backup $full_backup_id restored successfully." >&2
    else
        log_message "Error in restoring full backup $full_backup_id." >&2
        return 1
    fi

    local full_backup_date=$(echo "$full_backup_id" | awk -F '/' '{print $2}')
    apply_delta_backups "$full_backup_date"
    if [ $? -eq 0 ]; then
        log_message "All backups (full and delta) restored successfully." >&2
    else
        log_message "Error in applying delta backups." >&2
    fi
}
check_full_backup_restored
restore_backup
