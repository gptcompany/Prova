#!/bin/bash
# DEVELOPMENT Environment Setup Script for PostgreSQL with TimescaleDB on local pc instance
# chmod +x /home/ec2-user/statarb/feed/run_timescaledb.sh
DB_NAME="db0"
PGUSER="postgres"
PGHOST="localhost"
PGPORT="5432"
#PGPASSWORD=$(grep 'timescaledb_password' /config_cf.yaml | awk '{print $2}' | tr -d '"')
PGPASSWORD=$(python3 -c "import yaml; print(yaml.safe_load(open('/config_cf.yaml'))['timescaledb_password'])")
export PGUSER PGHOST PGPORT PGPASSWORD
CONTAINER_NAME="timescaledb"
PROD_DB_HOST="57.181.106.64"  # Production Database IP

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
        mkdir -p ~/timescaledb_data
        docker run -d \
        --name $CONTAINER_NAME \
        --restart "always" \
        -e PGDATA=/var/lib/postgresql/data \
        -e POSTGRES_USER="$PGUSER" \
        -e POSTGRES_PASSWORD="$PGPASSWORD" \
        -e POSTGRES_LOG_MIN_DURATION_STATEMENT=1000 \
        -e POSTGRES_LOG_ERROR_VERBOSITY=default \
        -p $PGPORT:$PGPORT \
        -v /home/sam/timescaledb_data:/var/lib/postgresql/data:z \
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
# Function to initialize data for replication
initialize_replication_data() {
    log_message "Initializing replication data from production server..."
    pg_basebackup -h $PROD_DB_HOST -D ~/timescaledb_data -U $REPLICATION_USER -v -P --wal-method=stream --write-recovery-conf --slot=your_slot_name
    if [ $? -eq 0 ]; then
        log_message "Replication data initialized successfully."
    else
        log_message "Error: Failed to initialize replication data."
        handle_error "Failed to initialize replication data"
    fi
}

# Main script execution
retry_command start_container 3
initialize_replication_data 1