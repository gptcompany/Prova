#!/bin/bash

# Docker and TimescaleDB settings
CONTAINER_NAME="timescaledb"  # Replace with your actual container name
DB_NAME="db0"
# PostgreSQL settings
PGUSER="postgres"
PGHOST="localhost"
PGPORT="5432"
PGPASSWORD=$(python3 -c "import yaml; print(yaml.safe_load(open('/config_cf.yaml'))['timescaledb_password'])")
export PGUSER PGHOST PGPORT PGPASSWORD

# Backup settings
LOCAL_BACKUP_PATH="/home/sam/ts_backups"
INSTANCE_NAME="timescaledb"
REMOTE_BACKUP_PATH="s3://timescalebackups"
LOCAL_PGDATA_PATH="/home/sam/timescaledb_data"
LOG_FILE="$HOME/ts_backups.log"
S3_CONFIG_PATH="$REMOTE_BACKUP_PATH/backup-folder"
# Function to log messages
log_message() {
    echo "$(date +"%Y-%m-%d %T"): $1" >&2 | tee -a $LOG_FILE 
}
# Improved error handling within functions
handle_error() {
    local error_message=$1
    log_message "Error: $error_message"
    # Exit the script or perform any necessary cleanup
    exit 1
}
# Function to download and apply configuration files from S3
download_and_apply_config_from_s3() {
    local s3_config_path=$1
    local container_name=$2
    local local_config_path="/mnt/data/pg_config_backup"
    local local_archive="$local_config_path/postgres_config_backup.tar.gz"
    local s3_archive="${s3_config_path}/postgres_config_backup.tar.gz"

    log_message "Starting to download and apply configuration files from S3."

    # Create temporary directory for configurations
    mkdir -p "$local_config_path" || handle_error "Failed to create temporary directory for configurations."

    # Check if the local archive matches the one on S3
    if [[ -f "$local_archive" ]]; then
        local local_md5=$(md5sum "$local_archive" | cut -d ' ' -f1)
        local s3_md5=$(aws s3api head-object --bucket "$(echo "$s3_archive" | cut -d '/' -f3)" --key "$(echo "$s3_archive" | cut -d '/' -f4-)" --query 'ETag' --output text | tr -d '"')

        if [[ "$local_md5" != "$s3_md5" ]]; then
            log_message "Local archive differs from S3. Downloading..."
            aws s3 cp "$s3_archive" "$local_archive" || handle_error "Failed to download configuration files from S3."
        else
            log_message "Local archive matches the one on S3. Using local archive."
        fi
    else
        log_message "Local archive not found. Downloading from S3..."
        aws s3 cp "$s3_archive" "$local_archive" || handle_error "Failed to download configuration files from S3."
    fi

    log_message "Decompressing configuration files..."
    tar -xzf "$local_archive" -C "$local_config_path" || handle_error "Failed to decompress configuration files."

    # Replace the current configuration files in the Docker container
    docker cp "$local_config_path/postgresql.conf" "$container_name:/var/lib/postgresql/data/" || handle_error "Failed to copy postgresql.conf to Docker container."
    docker cp "$local_config_path/pg_hba.conf" "$container_name:/var/lib/postgresql/data/" || handle_error "Failed to copy pg_hba.conf to Docker container."
    docker cp "$local_config_path/pg_wal" "$container_name:/var/lib/postgresql/data/" || handle_error "Failed to copy WAL files to Docker container."

    # Clean up the temporary files
    rm -rf "$local_config_path" || handle_error "Failed to clean up temporary files."
    log_message "Configuration files and WAL directory successfully applied from S3."
}




# Function to check if the database exists ######################TODO: a retry logic should be added
check_database_exists() {
    log_message "Checking if database $DB_NAME exists..."
    if ! output=$(docker exec -it $CONTAINER_NAME psql -U $PGUSER -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" 2>&1); then
        handle_error "Failed to check if database exists: $output"
        return 1
    elif echo "$output" | grep -q 1; then
        return 0 # Database exists
    else
        return 1 # Database does not exist
    fi
    # List all databases
    # Example: docker exec -it timescaledb psql -U postgres -c "\l"
    # Check if database exists
    # Example: docker exec -it timescaledb psql -U postgres -tAc "SELECT 1 FROM pg_database WHERE datname='db0'" | grep -q 1;
}
# Create the database if it doesn't exist
create_database_if_not_exists() {
    if check_database_exists; then
        log_message "No need to create the database. It already exists."
    else
        log_message "Creating database $DB_NAME."
        if ! output=$(docker exec -it $CONTAINER_NAME psql -U $PGUSER -c "CREATE DATABASE $DB_NAME" 2>&1); then
            handle_error "Failed to create database: $output"
        else
            log_message "Database $DB_NAME created."
        fi
    fi
    #Example: docker exec -it timescaledb psql -U postgres -c "CREATE DATABASE db0"
}

get_last_applied_backup_info() {
    # Logic to connect to TimescaleDB and retrieve last applied backup information
    # Run the SQL command to get the last applied backup information
    local last_backup_info=$(docker exec -it "$CONTAINER_NAME" psql -U $PGUSER -d $DB_NAME -c "SELECT pg_last_wal_replay_lsn() FROM pg_control_checkpoint();" | tr -d '[:space:]' | grep -E '[0-9A-F]+/[0-9A-F]+')
    log_message "Last applied backup LSN: $last_backup_info"
    echo "$last_backup_info"
    # Example: docker exec -it timescaledb psql -U postgres -d db0 -c "SELECT pg_last_wal_replay_lsn() FROM pg_control_checkpoint();"
    # Example: SELECT pg_last_wal_replay_lsn() FROM pg_control_checkpoint();
}

# Function to list available backups from remote storage
list_remote_backups() {
    # Extracting only the backup identifiers and sorting them chronologically
    aws s3 ls $REMOTE_BACKUP_PATH --recursive | grep '/backup.control' | awk -F '/' '{print $(NF-3) "/" $(NF-2) "/" $(NF-1)}' | sort -t '/' -k2,2 | uniq
    # Example: aws s3 ls s3://timescalebackups/timescaledb/ --recursive | grep '/backup.control' | awk -F '/' '{print $(NF-3) "/" $(NF-2) "/" $(NF-1)}' | sort -t '/' -k2,2 | uniq
}

#TODO: adjust the path
# Function to download the required backup from remote storage
# Example: aws s3 cp s3://timescalebackups/timescaledb/full/S6PB4F /home/sam/ts_backups --recursive
# Function to download the required backup from remote storage
download_backup() {
    local backup_entry=$1
    local backup_type=$(echo $backup_entry | cut -d '/' -f1)
    local backup_date=$(echo $backup_entry | cut -d '/' -f2)
    local backup_id=$(echo $backup_entry | cut -d '/' -f3)
    local s3_backup_path="$REMOTE_BACKUP_PATH/$INSTANCE_NAME/$backup_entry"
    local local_backup_path="$LOCAL_BACKUP_PATH/$INSTANCE_NAME/$backup_entry"
    local pg_probackup_expected_path="$LOCAL_BACKUP_PATH/backups/$INSTANCE_NAME/$backup_id"

    # Verify if the backup is already downloaded and copied correctly
    local s3_file_count=$(aws s3 ls "$s3_backup_path/" --recursive | wc -l)
    local local_file_count=$(find "$local_backup_path" -type f | wc -l)
    local pg_probackup_file_count=$(find "$pg_probackup_expected_path" -type f | wc -l)

    # Download backup if not present or if file count mismatch
    if [ ! -d "$local_backup_path" ] || [ "$s3_file_count" -ne "$local_file_count" ]; then
        log_message "Downloading backup $backup_id from S3 $s3_backup_path into $local_backup_path"
        mkdir -p "$local_backup_path"
        aws s3 cp "$s3_backup_path" "$local_backup_path" --recursive
        # [Recheck file count after download]
    else
        log_message "Backup $backup_id already exists locally with correct file count."
    fi

    # Copy to pg_probackup expected directory if not present or if file count mismatch
    if [ ! -d "$pg_probackup_expected_path" ] || [ "$pg_probackup_file_count" -ne "$local_file_count" ]; then
        log_message "Copying the downloaded backup to the pg_probackup expected directory: $pg_probackup_expected_path"
        mkdir -p "$pg_probackup_expected_path"
        cp -r "$local_backup_path/." "$pg_probackup_expected_path/"
        if [ $? -ne 0 ]; then
            handle_error "Failed to copy the downloaded backup to the pg_probackup expected directory."
            return 1
        else
            log_message "Downloaded backup copied to the pg_probackup expected directory: $pg_probackup_expected_path"
        fi
    else
        log_message "Backup $backup_id already exists in the pg_probackup expected directory with correct file count."
    fi
}

# Function to restore the downloaded backup
# Logic to apply the downloaded full backup to the local TimescaleDB instance
# Example: pg_probackup restore -B /home/sam/ts_backups --instance timescaledb -D /home/sam/timescaledb_data --backup-id=S6PB4F
restore_full_backup() {
    local backup_entry=$1
    local full_backup_id=$(echo $backup_entry | cut -d '/' -f3)
    local local_backup_path="$LOCAL_BACKUP_PATH/$INSTANCE_NAME/$backup_entry" #example: /home/sam/ts_backups/timescaledb/FULL/202401091736/S6PB4F
    local pg_probackup_expected_path="$LOCAL_BACKUP_PATH/backups/$INSTANCE_NAME"
    log_message "Local backup path: $local_backup_path"
    log_message "Preparing to restore full backup: $full_backup_id from $pg_probackup_expected_path"


    # Clear the restore directory if needed
    if [ -d "$LOCAL_PGDATA_PATH" ] && [ "$(ls -A "$LOCAL_PGDATA_PATH")" ]; then
        log_message "Clearing non-empty restore directory $LOCAL_PGDATA_PATH."
        rm -rf "$LOCAL_PGDATA_PATH"/*
    fi

    log_message "Restoring full backup: $backup_id from $local_backup_path"
    if ! pg_probackup restore -B $LOCAL_BACKUP_PATH --instance $INSTANCE_NAME -D $LOCAL_PGDATA_PATH --backup-id=$full_backup_id; then
        handle_error "Failed to restore full backup: $backup_entry"
    fi
    log_message "Full backup restored: $backup_entry"
}
#For example: pg_probackup restore -B /home/sam/ts_backups --instance timescaledb -D /home/sam/timescaledb_data --backup-id=S6PB4F
restore_delta_backup() {
    local backup_entry=$1
    local delta_backup_id=$(echo $backup_entry | cut -d '/' -f3)
    local local_backup_path="$LOCAL_BACKUP_PATH/$INSTANCE_NAME/$backup_entry"
    local pg_probackup_expected_path="$LOCAL_BACKUP_PATH/backups/$INSTANCE_NAME"

    log_message "Restoring delta backup: $delta_backup_id from $local_backup_path"
    log_message "Local backup path: $local_backup_path"
    # Add your restoration command here. Example:
    if ! pg_probackup restore -B $LOCAL_BACKUP_PATH --instance $INSTANCE_NAME -D $LOCAL_PGDATA_PATH --backup-id=$delta_backup_id; then
        handle_error "Failed to restore delta backup: $delta_backup_id"
    fi
    log_message "Delta backup restored: $delta_backup_id"
}

determine_backup_to_apply() {
    local last_applied_backup_info=$1
    local available_backups=$2

    local backups_to_apply=()
    local latest_full_backup=""
    local apply_next=false

    log_message "Determining backups to apply based on available backups and last applied backup information."

    # Find the latest full backup
    for backup in $available_backups; do
        local backup_type=$(echo $backup | cut -d '/' -f1)

        if [[ $backup_type == "FULL" ]]; then
            latest_full_backup=$backup
            log_message "Identified potential latest full backup: $backup"
        fi
    done

    if [ -z "$last_applied_backup_info" ]; then
        log_message "No last applied backup information found. Selecting the latest full backup and subsequent delta backups."
        for backup in $available_backups; do
            if [[ $backup == $latest_full_backup ]]; then
                backups_to_apply+=("$backup")
                apply_next=true
                log_message "Selected full backup: $backup"
            elif [[ $apply_next == true && $backup == *"DELTA"* ]]; then
                backups_to_apply+=("$backup")
                log_message "Added delta backup to apply: $backup"
            fi
        done
    else
        log_message "Last applied backup information found. Selecting appropriate delta backups."
        for backup in $available_backups; do
            local backup_type=$(echo $backup | cut -d '/' -f1)
            local backup_timestamp=$(echo $backup | cut -d '/' -f2)

            if [[ $backup_type == "DELTA" && $backup_timestamp > $last_applied_backup_info ]]; then
                backups_to_apply+=("$backup")
                log_message "Added delta backup to apply: $backup"
            fi
        done
    fi

    if [ ${#backups_to_apply[@]} -eq 0 ]; then
        log_message "Warning: No backups found to apply. This may indicate an issue with the available backups or the state of the database."
        echo "NONE"
    else
        log_message "Determined backups to apply: ${backups_to_apply[*]}"
        echo "${backups_to_apply[@]}"
    fi
}




# Function to check if the TimescaleDB Docker container is running
is_container_running() {
    local running_status=$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)
    if [ $? -ne 0 ]; then
        handle_error "Failed to inspect Docker container status."
        return 1  # Assume not running if the status check fails
    elif [ "$running_status" == "true" ]; then
        return 0
    else
        return 1
    fi
}

# Function to stop the TimescaleDB Docker container
stop_timescaledb_container() {
    docker stop $CONTAINER_NAME 2>/dev/null
    if [ $? -ne 0 ]; then
        handle_error "Failed to stop Docker container."
    fi
    # Example: docker stop timescaledb
}

# Function to start the TimescaleDB Docker container and check its status
start_timescaledb_container_and_check() {
    docker start "$CONTAINER_NAME"
    local max_attempts=5
    local attempt=1
    local running_status

    while [ $attempt -le $max_attempts ]; do
        log_message "Checking if TimescaleDB container is running (Attempt $attempt/$max_attempts)."
        running_status=$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)
        if [ "$running_status" == "true" ]; then
            log_message "TimescaleDB container is running."
            sleep 7
            return 0
        fi
        attempt=$((attempt+1))
        sleep 7  # Adjust the sleep time as necessary
    done

    log_message "Failed to start TimescaleDB container after $max_attempts attempts."
    return 1
}

# Main script execution flow
{   
    log_message "Starting backup restoration process."
    # Change ownership
    if ! sudo chown -R $(whoami):$(whoami) /home/sam/ts_backups; then
        handle_error "Failed to change ownership of /home/sam/ts_backups"
    fi

    # Change permissions
    if ! sudo chmod -R u+rwx /home/sam/ts_backups; then
        handle_error "Failed to change permissions of /home/sam/ts_backups"
    fi

    # Ensure the container is running before proceeding
    if ! is_container_running; then
        log_message "TimescaleDB container is not running. Attempting to start."
        if ! start_timescaledb_container_and_check; then
            handle_error "Unable to start TimescaleDB container."
        fi
    fi

    # Ensure the database exists before proceeding
    create_database_if_not_exists

    # Retrieve the last applied backup information
    last_applied_backup_info=$(get_last_applied_backup_info)

    # List available backups from remote storage
    available_backups=$(list_remote_backups)

    # Determine the appropriate backup to apply
    #backup_to_apply=$(determine_backup_to_apply "$last_applied_backup_info" "$available_backups")

    backup_ids_to_apply=($(determine_backup_to_apply "$last_applied_backup_info" "$available_backups"))
    # Print the backups to apply
    log_message "Backups to apply: ${backup_ids_to_apply[*]}"

    if [[ "${backup_ids_to_apply[@]}" == "NONE" ]]; then
        log_message "No new backups to apply. Backup restoration process is not needed."
    else
        # If there are backups to apply, proceed with the restoration process
        for backup_entry in "${backup_ids_to_apply[@]}"; do
            backup_type=$(echo $backup_entry | cut -d '/' -f1)
            backup_id=$(echo $backup_entry | cut -d '/' -f3)

            if is_container_running; then
                stop_timescaledb_container
            fi
            # Download and apply configuration from S3
            download_and_apply_config_from_s3 $S3_CONFIG_PATH $CONTAINER_NAME
            # Download and apply the determined backup
            download_backup "$backup_entry"
            if [[ $backup_type == "FULL" ]]; then
                restore_full_backup "$backup_entry"
            elif [[ $backup_type == "DELTA" ]]; then
                restore_delta_backup "$backup_entry"
            fi

            # Start the container after the backup is applied
            start_timescaledb_container
        done
    fi
} || handle_error "An unexpected error occurred during the backup restoration process."




