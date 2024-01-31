#!/bin/bash

# Database and AWS S3 settings
PGUSER="barman"
PGHOST=$(python3 -c "import yaml; print(yaml.safe_load(open('/config_cf.yaml'))['pg_host'])")
PGPORT="5432"
PGPASSWORD=$(python3 -c "import yaml; print(yaml.safe_load(open('/config_cf.yaml'))['timescaledb_password'])")
S3_BUCKET="s3://timescalebackups"
LOG_FILE="$HOME/ts_backups.log"
export PGUSER PGHOST PGPORT PGPASSWORD
env >&3
# Function to log messages
exec 3>>$LOG_FILE
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

# Check Barman status
log_message "Checking Barman status for timescaledb..."
barman_output=$(barman check timescaledb)
log_message "Barman Check Output:" "$barman_output"

# Determine backup type
log_message "Determining the type of backup to perform..."
last_backup_info=$(barman list-backup timescaledb | head -1)
if [[ $last_backup_info == *"Size: 0 B"* ]]; then
    backup_type="incremental"
else
    backup_type="full"
fi
log_message "Backup type determined: $backup_type"

# Perform backup
log_message "Performing $backup_type backup..."
if [ "$backup_type" == "incremental" ]; then
    barman_output=$(barman backup --reuse=link timescaledb)
else
    barman_output=$(barman backup timescaledb)
fi
log_message "Backup Output:" "$barman_output"

# List backups
log_message "Listing available backups..."
barman_output=$(barman list-backup timescaledb)
log_message "Available Backups:" "$barman_output"
