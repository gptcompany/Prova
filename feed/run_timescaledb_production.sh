#!/bin/bash
# Production Environment Setup Script for PostgreSQL with TimescaleDB on EC2 Instance
chmod +x /home/ec2-user/statarb/feed/run_timescaledb.sh
DB_NAME="db0"
PGUSER="postgres"
PGHOST="localhost"
PGPORT="5432"
#PGPASSWORD=$(grep 'timescaledb_password' /config_cf.yaml | awk '{print $2}' | tr -d '"')
PGPASSWORD=$(python3 -c "import yaml; print(yaml.safe_load(open('/config_cf.yaml'))['timescaledb_password'])")
export PGUSER PGHOST PGPORT PGPASSWORD
CONTAINER_NAME="timescaledb"
BACKUP_SCRIPT_PATH="/home/ec2-user/statarb/feed/timescaledb_backup.sh"
# Function to log messages
log_message() {
    echo "$(date +"%Y-%m-%d %T"): $1" >&2 
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
    local status=$(docker inspect --format="{{.State.Running}}" $container_name 2>/dev/null)

    if [ $? -eq 1 ]; then
        log_message "Container $container_name does not exist."
        return 1
    elif [ "$status" == "false" ]; then
        log_message "Container $container_name is not running."
        return 2
    else
        log_message "Container $container_name is running."
        return 0
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
        eval "$cmd ${args[*]}" && sleep 3 && return 0  # Command or function succeeded, exit loop
        log_message "Command failed (Attempt $attempt). Retrying..."
        ((attempt++))
        sleep 5  # Adjust sleep duration between retries
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
        -e PGDATA=/var/lib/postgresql/data \
        -e POSTGRES_USER="$PGUSER" \
        -e POSTGRES_PASSWORD="$PGPASSWORD" \
        -e POSTGRES_LOG_MIN_DURATION_STATEMENT=1000 \
        -e POSTGRES_LOG_ERROR_VERBOSITY=default \
        -p $PGPORT:$PGPORT \
        -v /home/ec2-user/timescaledb_data:/var/lib/postgresql/data:z \
        --log-driver="awslogs" \
        --log-opt awslogs-region=ap-northeast-1 \
        --log-opt awslogs-group=Timescaledb \
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


# Setting up streaming replication
setting_replica() {
    docker exec -it timescaledb psql -U $PGUSER -c "ALTER SYSTEM SET wal_level = replica;"
    docker exec -it timescaledb psql -U $PGUSER -c "ALTER SYSTEM SET max_wal_senders = 5;"
    docker exec -it timescaledb psql -U $PGUSER -c "ALTER SYSTEM SET max_replication_slots = 5;"
}
setting_explain(){
    docker exec -it timescaledb psql -U $PGUSER -c "SELECT pg_reload_conf();"
    docker exec -it timescaledb psql -U $PGUSER -c "LOAD 'auto_explain';"
    docker exec -it timescaledb psql -U $PGUSER -c "SET auto_explain.log_min_duration = '3s';"
    docker exec -it timescaledb psql -U $PGUSER -c "SET auto_explain.log_analyze = true;"
    docker exec -it timescaledb psql -U $PGUSER -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"
}
# pgBadger can be run on log files to generate detailed reports. This is typically done outside of the Docker container.
setting_performance(){
    docker exec -it timescaledb psql -U $PGUSER -d $DB_NAME -c "VACUUM (VERBOSE, ANALYZE) book"
    docker exec -it timescaledb psql -U $PGUSER -d $DB_NAME -c "VACUUM (VERBOSE, ANALYZE) trades"
    docker exec -it timescaledb psql -U $PGUSER -d $DB_NAME -c "REINDEX DATABASE $DB_NAME;"

    # Example: Creating an index on the 'timestamp' column
    # docker exec -it timescaledb psql -U $PGUSER -c "CREATE INDEX ON my_table (timestamp);"
}
setting_cronjob() {
    local backup_script="$1"

    if [ -x "$backup_script" ]; then
        # Remove existing cron jobs for the script
        log_message "Removing any existing cron jobs for $backup_script"
        crontab -l | grep -v "$backup_script" | crontab -

        # Add the cron job
        log_message "Adding new cron job for $backup_script"
        (crontab -l 2>/dev/null; echo "0 * * * * $backup_script") | crontab -
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
            log_message "Error: crond service failed to start."
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
                log_message "Error: Failed to start crond service."
                exit 1
            fi
        fi
    fi
}

retry_command start_container 3
retry_command setting_replica 3
retry_command setting_explain 3
retry_command setting_performance 3
retry_command check_and_install_cronie 2
retry_command setting_cronjob 2 $BACKUP_SCRIPT_PATH

