#!/bin/bash

# Database and AWS S3 settings
LOG_FILE="$HOME/ts_backups.log"
SERVER="timescaledb"


# Function to log messages
exec 3>>$LOG_FILE
env >&3
log_message() {
    local message="$(date +"%Y-%m-%d %T"): $1"
    echo "$message" >&3  # Log to the log file
    echo "$message" >&2  # Display on the screen
    if [ -n "$2" ]; then
        echo "$2" >&3  # Log stdout to the log file
        echo "$2" >&2  # Display stdout on the screen
    fi
    if [ -n "$3" ]; then
        echo "$3" >&3  # Log stderr to the log file
        echo "$3" >&2  # Display stderr on the screen
    fi
}

# Function to get basebackups directory from barman show-server
get_basebackups_directory() {
    # Extract the basebackups_directory path
    local basebackups_directory=$(barman show-server "$SERVER" | grep "basebackups_directory" | awk '{print $2}')
    echo "$basebackups_directory"
}

# Function to check for existing full backup in basebackups_directory
check_full_backup_exists() {
    local basebackups_directory=$(get_basebackups_directory)
    
    # Ensure the basebackups_directory was successfully retrieved
    if [ -z "$basebackups_directory" ]; then
        log_message "Failed to retrieve basebackups directory for $SERVER"
        echo "false"
        return
    fi

    # List all backups for the server
    local backups=$(barman list-backup "$SERVER")
    log_message "Available Backups:" "$backups"

    # Check if backups variable is empty or does not contain valid backup entries
    if [[ -z "$backups" || "$backups" == *"No backups available"* ]]; then
        log_message "No backups found for $SERVER"
        echo "false"
        return
    fi

    # Iterate over each listed backup to check if a matching directory exists
    local backup_exists="false"
    while read -r backup_line; do
        # Proceed only if the line contains a valid backup entry
        if [[ -n "$backup_line" && "$backup_line" != *"No backups available"* ]]; then
            # Extract the backup name/ID - adjust based on your barman version's output format
            local backup_name=$(echo "$backup_line" | awk '{print $2}')
            
            # Form the expected directory path for this backup
            local backup_dir="$basebackups_directory/$backup_name"
            
            # Check if this directory exists
            if [ -d "$backup_dir" ]; then
                backup_exists="true"
                log_message "Full backup $backup_name exists in base folder $backup_dir"
                break # A matching directory is found, no need to check further
            fi
        fi
    done <<< "$backups"

    echo "$backup_exists"
}


# Check Barman status
log_message "Checking Barman status for timescaledb..."
barman_output=$(barman check timescaledb)
log_message "Barman Check Output:" "$barman_output"

# Determine backup type
log_message "Determining the type of backup to perform..."
if [[ $(check_full_backup_exists) == "true" ]]; then
    backup_type="incremental"
else
    backup_type="full"
fi
log_message "Backup type determined: $backup_type"

# # Perform backup
# log_message "Performing $backup_type backup..."
# if [ "$backup_type" == "incremental" ]; then
#     barman_output=$(barman backup --reuse=link "$SERVER")
# else
#     barman_output=$(barman backup "$SERVER")
# fi
# log_message "Backup Output:" "$barman_output"

# # List backups
# log_message "Listing available backups..."
# barman_output=$(barman list-backup timescaledb)
# log_message "Available Backups:" "$barman_output"
