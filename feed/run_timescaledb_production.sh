#!/bin/bash
# Production Environment Setup Script for PostgreSQL with TimescaleDB on EC2 Instance
sudo chmod +x /home/ec2-user/statarb/feed/run_timescaledb_production.sh
#PGPASSWORD=$(grep 'timescaledb_password' /config_cf.yaml | awk '{print $2}' | tr -d '"')
DB_NAME="db0"
PGUSER="postgres"
PGHOST="localhost"
PGPORT="5432"
PGPASSWORD=$(python3 -c "import yaml; print(yaml.safe_load(open('/config_cf.yaml'))['timescaledb_password'])")
CONTAINER_NAME="timescaledb"
sudo chmod +x /home/ec2-user/statarb/feed/timescaledb_backup.sh
BACKUP_SCRIPT_PATH="/home/ec2-user/statarb/feed/timescaledb_backup.sh"
# Logging settings
HOME="/home/ec2-user"
LOG_FILE="$HOME/ts_backups.log"
# AWS CloudWatch settings
AWS_LOG_GROUP="Timescaledb"
AWS_LOG_STREAM="production"
AWS_LOG_REGION="ap-northeast-1"
export PGUSER PGHOST PGPORT PGPASSWORD AWS_LOG_REGION AWS_LOG_GROUP
# Function to log messages
# Global variable to track if the log group and stream have been verified/created
LOG_GROUP_VERIFIED=false
LOG_STREAM_VERIFIED=false
IP_FILE="ip_development.txt"
S3_BUCKET="s3://timescalebackups"
REPLICATION_SLOT="timescale"
PGDATA="/var/lib/postgresql/data"
DUMP_FOLDER="/home/ec2-user/timescaledb_backups"
sudo mkdir -p $DUMP_FOLDER
sudo chown ec2-user $DUMP_FOLDER
sudo chmod 700 $DUMP_FOLDER
DUMP_FILE_TO_S3="$DUMP_FOLDER/prod_backup.sql"
DUMP_FILE="/backups/prod_backup.sql"
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


# Improved error handling within functions
handle_error() {
    local error_message=$1
    log_message "Error: $error_message"
    # Exit the script or perform any necessary cleanup
    exit 1
}
# Enhanced function to check Docker container status
check_container_status() {
    local container_name=$1
    local exists=$(docker ps -a --format "{{.Names}}" | grep -w $container_name)

    if [ -z "$exists" ]; then
        log_message "Container $container_name does not exist."
        return 1
    else
        local status=$(docker inspect --format="{{.State.Running}}" $container_name)
        if [ "$status" == "false" ]; then
            log_message "Container $container_name is not running."
            return 2
        else
            log_message "Container $container_name is running."
            return 0
        fi
    fi
}

# Modified retry_command function to handle different types of commands including functions
retry_command() {
    local cmd="$1"
    local max_attempts="$2"
    shift 2
    local args=("$@") # Remaining arguments
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        log_message "Attempting command: $cmd ${args[*]} (Attempt $attempt)"
        output=$(eval "$cmd ${args[*]}")
        if [ $? -eq 0 ]; then
            sleep 3
            log_message "Command succeeded (Attempt $attempt):" "$output"  # Log stdout
            return 0  # Command or function succeeded, exit loop
        else
            log_message "Command failed (Attempt $attempt). Retrying..." "$output"  # Log stderr
            ((attempt++))
            sleep 5  # Adjust sleep duration between retries
        fi
    done

    log_message "Max attempts reached. Command failed."
    handle_error "Command failed after $max_attempts attempts: $cmd"
}



# Starting the TimescaleDB Docker container

start_container(){
    # First, check the status of the container
    check_container_status $CONTAINER_NAME
    local container_status=$?

    if [ $container_status -eq 0 ]; then
        log_message "Container $CONTAINER_NAME is already running."
    elif [ $container_status -eq 1 ]; then
        # Container does not exist, need to create and start it
        log_message "Container $CONTAINER_NAME does not exist. Creating and starting container."
        docker run -d \
        --name $CONTAINER_NAME \
        --restart "always" \
        -e PGDATA=$PGDATA \
        -e POSTGRES_USER="$PGUSER" \
        -e POSTGRES_PASSWORD="$PGPASSWORD" \
        -e POSTGRES_LOG_MIN_DURATION_STATEMENT=1000 \
        -e POSTGRES_LOG_ERROR_VERBOSITY=default \
        -e POSTGRES_INITDB_ARGS="--wal_level=logical --max_wal_senders=5 --max_replication_slots=5" \
        -p $PGPORT:$PGPORT \
        -v $HOME/timescaledb_data:$PGDATA:z \
        -v $DUMP_FOLDER:/backups:z \
        --log-driver="awslogs" \
        --log-opt awslogs-region=$AWS_LOG_REGION \
        --log-opt awslogs-group=$AWS_LOG_GROUP \
        --log-opt awslogs-create-group=true \
        timescale/timescaledb:latest-pg14

        # Check if the container started correctly
        if [ $? -eq 0 ]; then
            log_message "Container $CONTAINER_NAME started successfully."
            # Wait a bit for the container to initialize
            sleep 10
            # Additional check to confirm the container is running after initialization
            check_container_status $CONTAINER_NAME
            if [ $? -ne 0 ]; then
                log_message "Error: Container $CONTAINER_NAME failed to start."
                handle_error "Container failed to start"
            fi
        else
            log_message "Error: Failed to start container $CONTAINER_NAME."
            handle_error "Failed to start container"
        fi
    elif [ $container_status -eq 2 ]; then
        log_message "Container $CONTAINER_NAME exists but is not running. Starting container."
        docker start $CONTAINER_NAME
        if [ $? -ne 0 ]; then
            log_message "Error: Failed to start existing container $CONTAINER_NAME."
            handle_error "Failed to start existing container"
        fi
    fi
}


# Setting up logical
setting_logical() {
    local needs_restart=false
    local current_setting

    # Check if 'wal_level' is set to 'logical'
    current_setting=$(docker exec timescaledb psql -U $PGUSER -t -c "SHOW wal_level;" | tr -d '[:space:]')
    if [ "$current_setting" != "logical" ]; then
        log_message "Setting 'wal_level' to 'logical'. Current setting: $current_setting"
        docker exec timescaledb psql -U $PGUSER -c "ALTER SYSTEM SET wal_level = logical;"
        needs_restart=true
    else
        log_message "'wal_level' is already set to 'logical'."
    fi

    # Check 'max_wal_senders'
    current_setting=$(docker exec timescaledb psql -U $PGUSER -t -c "SHOW max_wal_senders;" | tr -d '[:space:]')
    if [ "$current_setting" -ne 5 ]; then
        log_message "Setting 'max_wal_senders' to 5. Current setting: $current_setting"
        docker exec timescaledb psql -U $PGUSER -c "ALTER SYSTEM SET max_wal_senders = 5;"
        needs_restart=true
    else
        log_message "'max_wal_senders' is already set to 5."
    fi

    # Check 'max_replication_slots'
    current_setting=$(docker exec timescaledb psql -U $PGUSER -t -c "SHOW max_replication_slots;" | tr -d '[:space:]')
    if [ "$current_setting" -ne 5 ]; then
        log_message "Setting 'max_replication_slots' to 5. Current setting: $current_setting"
        docker exec timescaledb psql -U $PGUSER -c "ALTER SYSTEM SET max_replication_slots = 5;"
        needs_restart=true
    else
        log_message "'max_replication_slots' is already set to 5."
    fi

    # Apply the changes and restart if necessary
    if [ "$needs_restart" = true ]; then
        docker exec timescaledb psql -U $PGUSER -c "SELECT pg_reload_conf();"
        log_message "Configuration reloaded, restarting the Docker container to apply changes."

        # Restart the Docker container
        docker restart $CONTAINER_NAME

        # Check if the container restart was successful
        if [ $? -eq 0 ]; then
            log_message "Docker container $CONTAINER_NAME restarted successfully."
            
            # Check if PostgreSQL is ready after the restart
            sleep 10  # Wait for a few seconds to allow PostgreSQL to start
            docker exec timescaledb pg_isready -U $PGUSER -h localhost -p $PGPORT -d $DB_NAME -t 30
            if [ $? -eq 0 ]; then
                log_message "PostgreSQL is ready and accepting connections."
            else
                log_message "Error: PostgreSQL is not ready after container restart."
                handle_error "PostgreSQL is not ready after container restart"
            fi
        else
            log_message "Error: Failed to restart Docker container $CONTAINER_NAME."
            handle_error "Failed to restart Docker container"
        fi
    else
        log_message "No changes needed in replication settings."
    fi
}


setting_explain(){
    
    docker exec -it timescaledb psql -U $PGUSER -c "LOAD 'auto_explain';"
    docker exec -it timescaledb psql -U $PGUSER -c "SET auto_explain.log_min_duration = '3s';"
    docker exec -it timescaledb psql -U $PGUSER -c "SET auto_explain.log_analyze = true;"
    docker exec -it timescaledb psql -U $PGUSER -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"
}
# pgBadger can be run on log files to generate detailed reports. This is typically done outside of the Docker container.
setting_performance() {
    if docker exec -it timescaledb psql -U $PGUSER -d $DB_NAME -c "VACUUM (VERBOSE, ANALYZE) book" > /dev/null 2>&1 &&
       docker exec -it timescaledb psql -U $PGUSER -d $DB_NAME -c "VACUUM (VERBOSE, ANALYZE) trades" > /dev/null 2>&1 &&
       docker exec -it timescaledb psql -U $PGUSER -d $DB_NAME -c "REINDEX DATABASE $DB_NAME;" > /dev/null 2>&1; then
        return 0  # Success
    else
        return 1  # Failure
    fi

    # Example: Creating an index on the 'timestamp' column
    # docker exec -it timescaledb psql -U $PGUSER -c "CREATE INDEX ON my_table (timestamp);"
}
setting_cronjob() {
    local backup_script="$BACKUP_SCRIPT_PATH"

    if [ -x "$backup_script" ]; then
        # Remove existing cron jobs for the script
        log_message "Removing any existing cron jobs for $backup_script"
        crontab -l | grep -v "$backup_script" | crontab -

        # Add the cron job
        log_message "Adding new cron job for $backup_script"
        (crontab -l 2>/dev/null; echo "0 * * * * sudo $backup_script") | crontab - #(crontab -l 2>/dev/null; echo "*/5 * * * * sudo $backup_script") | crontab -
        log_message "Backup cronjob scheduled to run every hour"

        # Print currently scheduled jobs
        log_message "Checking current cron jobs:"
        crontab -l
    else
        log_message "Error: Backup script $backup_script not found or not executable"
        handle_error "Backup script not found or not executable"
    fi
}
check_and_install_cronie() {
    if ! command -v crontab &> /dev/null; then
        log_message "cronie is not installed. Installing cronie."
        sudo yum install -y cronie
        sudo /bin/systemctl start crond.service

        # Check if the crond service is running
        if ps -ef | grep -q '[c]rond'; then
            log_message "crond service is running."
        else
            handle_error "crond service failed to start."
            exit 1
        fi
    else
        log_message "cronie is already installed."

        # Verify that crond service is running
        if ps -ef | grep -q '[c]rond'; then
            log_message "crond service is running."
        else
            log_message "crond service is not running. Attempting to start crond."
            sudo /bin/systemctl start crond.service
            if ps -ef | grep -q '[c]rond'; then
                log_message "crond service started successfully."
            else
                handle_error "Failed to start crond service."
                exit 1
            fi
        fi
    fi
}
update_pg_hba_for_replication() {
    # AWS S3 Bucket where ip_development.txt is stored
    local s3_bucket=$S3_BUCKET
    local ip_file=$IP_FILE
    local temp_ip_file="/tmp/$ip_file"
    # Path to pg_hba.conf within the Docker container
    local pg_hba_file="/var/lib/postgresql/data/pg_hba.conf"

    # Download the file from S3
    if aws s3 cp "$s3_bucket/$ip_file" "$temp_ip_file"; then
        log_message "Downloaded $ip_file from S3 bucket."
    else
        handle_error "Failed to download $ip_file from S3 bucket."
    fi

    # Parse the IP address
    if [ -f "$temp_ip_file" ]; then
        local dev_ip=$(cat "$temp_ip_file")
        log_message "Development IP: $dev_ip"
    else
        handle_error "IP file does not exist: $temp_ip_file"
    fi

    # Check and update pg_hba.conf within the Docker container
    if docker exec $CONTAINER_NAME bash -c "grep -q '$dev_ip/32' $pg_hba_file"; then
        log_message "pg_hba.conf already contains an entry for $dev_ip."
        return 0
    else
        docker exec $CONTAINER_NAME bash -c "echo 'host replication all $dev_ip/32 scram-sha-256' >> $pg_hba_file"
        log_message "Updated pg_hba.conf with replication entry for $dev_ip."
        # Reload PostgreSQL configuration inside the container without using pg_ctl
        docker exec $CONTAINER_NAME bash -c "kill -HUP \$(cat /var/lib/postgresql/.s.PGSQL.$PGPORT.pid)"
        log_message "PostgreSQL configuration reloaded."
    fi

}
create_logical_replication_slot() {
    local slot_name=$REPLICATION_SLOT

    if [ -z "$slot_name" ]; then
        log_message "Error: No slot name provided for create_logical_replication_slot function."
        handle_error "No slot name provided"
    fi

    if docker exec $CONTAINER_NAME psql -U $PGUSER -tAc "SELECT 1 FROM pg_replication_slots WHERE slot_name = '$slot_name' AND slot_type = 'logical';" | grep -q 1; then
        log_message "Logical replication slot $slot_name already exists."
    else
        docker exec $CONTAINER_NAME psql -U $PGUSER -c "SELECT pg_create_logical_replication_slot('$slot_name', 'pgoutput');"
        log_message "Logical replication slot $slot_name created successfully."
    fi
}

create_replication_slot() {
    local slot_name=$REPLICATION_SLOT  # Name of the replication slot to create

    if [ -z "$slot_name" ]; then
        log_message "Error: No slot name provided for create_replication_slot function."
        handle_error "No slot name provided"
    fi

    # Check if the replication slot already exists
    if docker exec $CONTAINER_NAME psql -U $PGUSER -tAc "SELECT 1 FROM pg_replication_slots WHERE slot_name = '$slot_name';" | grep -q 1; then
        log_message "Replication slot $slot_name already exists."
    else
        # Create the replication slot
        local create_slot_command="SELECT pg_create_physical_replication_slot('$slot_name');"
        if docker exec $CONTAINER_NAME psql -U $PGUSER -c "$create_slot_command"; then
            log_message "Replication slot $slot_name created successfully."
        else
            log_message "Error: Failed to create replication slot $slot_name."
            handle_error "Failed to create replication slot"
        fi
    fi
}
# Function to create a publication for all tables
create_publication() {
    log_message "Creating a publication for all tables..."

    # Check if the publication already exists (modify this check as needed)
    if docker exec $CONTAINER_NAME psql -U $PGUSER -d $DB_NAME -c "\dRp+" | grep -q 'my_publication'; then
        log_message "Publication 'my_publication' already exists."
    else
        # Create the publication
        docker exec $CONTAINER_NAME psql -U $PGUSER -d $DB_NAME -c "
            CREATE PUBLICATION my_publication FOR ALL TABLES;
        "
        log_message "Publication 'my_publication' created for all tables."
    fi
}
# Function to create a database dump
create_database_dump() {
    local dump_file=$DUMP_FILE

    if [ -f "$DUMP_FILE_TO_S3" ]; then
        log_message "Dump file $DUMP_FILE_TO_S3 already exists. Skipping dump creation."
        return 0
    else
        log_message "Creating database dump..."
        docker exec timescaledb pg_dump -U $PGUSER -d $DB_NAME -F c -f "$dump_file"

        if [ $? -eq 0 ]; then
            log_message "Database dump created successfully at $dump_file"
        else
            handle_error "Failed to create database dump"
            return 1
        fi
    fi
}

upload_to_s3() {
    local dump_file=$DUMP_FILE_TO_S3
    local s3_upload_path="$S3_BUCKET/$INSTANCE_NAME/prod_backup.sql"

    # Check if the local dump file exists
    if [ ! -f "$dump_file" ]; then
        handle_error "The local dump file $dump_file not found."
        return 1
    fi

    # Check if the dump file already exists on S3
    if aws s3 ls "$s3_upload_path" &>/dev/null; then
        log_message "Dump file $s3_upload_path already exists on S3. Skipping upload."
        return 0
    else
        log_message "Uploading backup $dump_file to S3..."
        sudo aws s3 cp $dump_file $s3_upload_path

        if [ $? -eq 0 ]; then
            log_message "Upload to S3 bucket $s3_upload_path completed."
        else
            handle_error "Failed to upload the dump file to S3."
            return 1
        fi
    fi
}



# cleanup_old_backups() {
#     log_message "Cleaning up old backups..."
#     find "$DUMP_FILE" -mtime +7 -exec sudo rm {} \;
#     log_message "Old backups cleaned up."
# }
retry_command start_container 3
retry_command create_publication 1
retry_command create_logical_replication_slot 2
#retry_command create_replication_slot 2
retry_command update_pg_hba_for_replication 3
retry_command setting_logical 3
retry_command setting_explain 3
retry_command "setting_performance" 3
if [ $? -eq 0 ]; then
    log_message "Setting_performance ran successfully"
else
    log_message "Setting_performance failed"
fi

retry_command check_and_install_cronie 2
retry_command setting_cronjob 2
retry_command create_database_dump 3
retry_command upload_to_s3 3
# Call the cleanup function after successful upload
# retry_command cleanup_old_backups 1


### COMMANDS IF NEED TO PERFORM FRESH SETUP ###

# docker exec -it timescaledb psql -U postgres -c "DROP DATABASE IF EXISTS db0;"
# sudo sh -c 'crontab -l 2>/dev/null | grep -v "/home/ec2-user/statarb/feed/timescaledb_backup.sh" | crontab -'
# sudo crontab -l
# docker exec -u postgres timescaledb psql -U postgres -c "SELECT pg_drop_replication_slot('timescale');" 
# aws s3 rm s3://timescalebackups/timescaledb/prod_backup.sql
# sudo rm /home/ec2-user/timescaledb_backups/prod_backup.sql
# docker stop timescaledb
# docker rm timescaledb


