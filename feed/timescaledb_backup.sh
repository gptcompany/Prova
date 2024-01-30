#!/bin/bash
env >&3
sudo chmod +x /home/ec2-user/statarb/feed/timescaledb_backup.sh
# PostgreSQL settings
#PGPASSWORD=$(grep 'timescaledb_password' /config_cf.yaml | awk '{print $2}' | tr -d '"')
DB_NAME="db0"
PGUSER="postgres"
PGHOST="localhost"
PGPORT="5432"
PGPASSWORD=$(python3 -c "import yaml; print(yaml.safe_load(open('/config_cf.yaml'))['timescaledb_password'])")
export PGUSER PGHOST PGPORT PGPASSWORD
# pg_probackup settings
BACKUP_PATH="/home/ec2-user/ts_backups"
INSTANCE_NAME="timescaledb"
# AWS S3 settings
S3_BUCKET="s3://timescalebackups"
# Logging settings
HOME="/home/ec2-user"
LOG_FILE="$HOME/ts_backups.log"
# AWS CloudWatch settings
AWS_LOG_GROUP="Timescaledb"
AWS_LOG_STREAM="production"
AWS_LOG_REGION="ap-northeast-1"
export PGUSER PGHOST PGPORT PGPASSWORD AWS_LOG_REGION AWS_LOG_GROUP

# Function to log messages
exec 3>>$LOG_FILE
# Function to log messages and command output to the log file
log_message() {
    local message="$(date +"%Y-%m-%d %T"): $1"
    echo "$message" >&3  # Log to the log file via fd3
    echo "$message" >&2  # Display on the screen (stderr)
    if [ -n "$2" ]; then
        echo "$2" >&3   # Log stdout to the log file via fd3
        echo "$2" >&2   # Display stdout on the screen (stderr)
    fi
    if [ -n "$3" ]; then
        echo "$3" >&3   # Log stderr to the log file via fd3
        echo "$3" >&2   # Display stderr on the screen (stderr)
    fi
}

# Function to clean up old backups
cleanup_old_backups() {
    log_message "Cleaning up old backups..."
    find "$BACKUP_PATH/backups/$INSTANCE_NAME" -type d -mtime +7 -exec sudo rm -rf {} \;
    log_message "Old backups cleaned up."
}

# Function to upload the backup to S3
upload_to_s3() {
    local backup_id_to_upload=$1
    local backup_type=$2  # New argument for backup type
    local backup_path="$BACKUP_PATH/backups/$INSTANCE_NAME/$backup_id_to_upload"
    local backup_datetime=$(date +"%Y%m%d%H%M") # Current date in YYYYMMDD format
    #DEBUG
    # echo "###########$backup_path###########"
    # echo "***********$backup_id_to_upload**************"
    

    if [ ! -d "$backup_path" ]; then
        log_message "Backup directory $backup_path not found." >&2
        return 1
    fi
    # Use backup_type in constructing the S3 upload path or for other purposes
    local s3_upload_path="$S3_BUCKET/$INSTANCE_NAME/$backup_type/$backup_datetime/$backup_id_to_upload"
    log_message "Uploading backup $backup_id_to_upload to S3..." >&2
    aws s3 cp $backup_path $s3_upload_path --recursive
    log_message "Upload to S3 bucket $s3_upload_path completed." >&2

    # Call the cleanup function after successful upload
    cleanup_old_backups
}


# Function to get the latest FULL backup ID locally on instance
get_latest_full_backup_id() {
    local last_full_backup
    #Check for last full backup locally on instance
    last_full_backup=$(pg_probackup show -B $BACKUP_PATH --instance $INSTANCE_NAME | grep ' FULL ' | grep -v 'ERROR' | tail -1)
    if [ -z "$last_full_backup" ]; then
    # nothing is echoed to standard output
        log_message "Error checking last full backup or backup not found!" >&2
        echo ""
    else
        local latest_full_backup_id=$(echo "$last_full_backup" | awk '{print $3}')
        # Only the latest_full_backup_id is echoed to standard output
        log_message "Last full backup: $latest_full_backup_id" >&2
        echo "$latest_full_backup_id"
    fi
}

# Function to perform a pg_probackup and capture backup ID
perform_backup() {
    local backup_mode=$1 # FULL or DELTA
    
    local backup_output
    log_message "Starting $backup_mode backup for instance $INSTANCE_NAME..." >&2  # Redirect to standard error
    
    backup_output=$(pg_probackup backup -B $BACKUP_PATH -b $backup_mode -U $PGUSER -d $DB_NAME --instance $INSTANCE_NAME --stream -h $PGHOST -p $PGPORT --compress --compress-algorithm=zlib --compress-level=9 2>&1)
    echo "$backup_output" >&2 # Redirect to standard error
    if [ $? -ne 0 ]; then
        log_message "Backup operation failed." >&2  # Redirect to standard error
        return 1
    fi
    
    local backup_id_from_info=$(echo "$backup_output" | grep -oP 'INFO: Backup \K\S+(?= completed)')
    local backup_id_from_id=$(echo "$backup_output" | grep -oP 'backup ID: \K\S+(?=,)')

    # Debug messages redirected to standard error
    #echo "check $backup_id_from_info *** check $backup_id_from_id ***" >&2

    if [ -z "$backup_id_from_info" ] || [ -z "$backup_id_from_id" ]; then
        log_message "Failed to capture backup ID." >&2  # Redirect to standard error
        return 1
    fi

    if [ "$backup_id_from_info" != "$backup_id_from_id" ]; then
        log_message "Mismatch in captured backup IDs: $backup_id_from_info and $backup_id_from_id." >&2  # Redirect to standard error
        return 1
    else
        local backup_id=$backup_id_from_info
    fi

    # Only the backup_id is echoed to standard output
    echo "$backup_id"
}


# Function to check for backup in S3
check_backup_in_s3() {
    local backup_id=$1
    log_message "Checking for backup $backup_id in S3..."

    # List all potential backup folders under FULL and DELTA
    local backup_folders=$(aws s3 ls "$S3_BUCKET/$INSTANCE_NAME/" --recursive | grep -E 'FULL|DELTA' | awk '{print $4}')

    for folder in $backup_folders; do
        if [[ $folder == *"$backup_id"* ]]; then
            log_message "Backup $backup_id found in S3 under $folder."
            return 0
        fi
    done

    log_message "No backup $backup_id found in S3."
    return 1
}




# Decide whether to perform a Full or Delta backup
perform_required_backup() {
    local latest_full_backup_id=$(get_latest_full_backup_id)

    if [ -n "$latest_full_backup_id" ]; then
        if check_backup_in_s3 "$latest_full_backup_id"; then
            local backup_type="DELTA"
            local delta_backup_id=$(perform_backup DELTA)
            if [ -n "$delta_backup_id" ]; then
                log_message "Delta id: $delta_backup_id" >&2
                upload_to_s3 "$delta_backup_id" "$backup_type"
            else
                log_message "Delta backup failed or no new backup was created."
            fi
        else
            local backup_type="FULL"
            log_message "Latest full id: $latest_full_backup_id" >&2
            upload_to_s3 "$latest_full_backup_id" "$backup_type"
        fi
    else
        local backup_type="FULL"
        local full_backup_id=$(perform_backup FULL)
        if [ -n "$full_backup_id" ]; then
            upload_to_s3 "$full_backup_id" "$backup_type"
        else
            log_message "Full backup failed or no new full backup was created." >&2
        fi
    fi
}


# Execute the backup decision logic
perform_required_backup

exit 0