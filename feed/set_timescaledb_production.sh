#!/bin/bash
# DEVELOPMENT Environment Setup Script for PostgreSQL with TimescaleDB on local pc instance
# chmod +x /home/ec2-user/statarb/feed/run_timescaledb.sh
# Environment (set this to either 'development' or 'production')
ENVIRONMENT="production"
DB_NAME="db0"
PGUSER="postgres"
PGHOST="localhost"
PGPORT="5432"
PGPASSWORD=$(python3 -c "import yaml; print(yaml.safe_load(open('/config_cf.yaml'))['timescaledb_password'])")
export PGUSER PGHOST PGPORT PGPASSWORD
CONTAINER_NAME="timescaledb"
TABLES=("book" "trades")
# Associative array declaration
declare -A table1_config
declare -A table2_config

# Configuration for table1 (e.g., 'trades')
table1_config[name]="trades"
table1_config[time_column]="timestamp"
table1_config[chunk_interval]="10 minutes"
table1_config[segmentby_column]="exchange, symbol"
table1_config[orderby_column]="timestamp, id"
table1_config[compress_interval]="10 minutes"
table1_config[retention_interval]="7 days"  # Use only for production

# Configuration for table2 (e.g., 'book')
table2_config[name]="book"
# ... similarly, fill the settings for table2

# Add configurations to an array
table_configs=(table1_config table2_config)

# Function to log messages
log_message() {
    local message="$(date +"%Y-%m-%d %T"): $1"
    echo "$message" >&2  # Display on the screen (stderr)
}

# Improved error handling within functions
handle_error() {
    local error_message=$1
    log_message "Error: $error_message"
    exit 1
}

# Retry mechanism
retry() {
    local n=1
    local max=2
    local delay=5
    while true; do
        "$@" && break || {
            if [[ $n -lt $max ]]; then
                ((n++))
                log_message "Command failed. Attempt $n/$max:"
                sleep $delay;
            else
                log_message "The command has failed after $n attempts."
                return 1
            fi
        }
    done
}

# Table configurations
declare -A trades_config
declare -A book_config

# Configuration for 'trades' table
trades_config[name]="trades"
trades_config[create_command]="CREATE TABLE trades (
    exchange TEXT,
    symbol TEXT,
    side TEXT,
    amount DOUBLE PRECISION,
    price DOUBLE PRECISION,
    timestamp TIMESTAMPTZ,
    receipt TIMESTAMPTZ,
    id BIGINT,
    PRIMARY KEY (exchange, symbol, timestamp, id)
);"
trades_config[time_column]="timestamp"
trades_config[chunk_interval]="10 minutes"
trades_config[segmentby_column]="exchange, symbol"
trades_config[orderby_column]="timestamp, id"
trades_config[compress_interval]="10 minutes"
trades_config[retention_interval]="7 days"  # Only for production

# Configuration for 'book' table
book_config[name]="book"
book_config[create_command]="CREATE TABLE book (
    exchange TEXT,
    symbol TEXT,
    bid DOUBLE PRECISION,
    ask DOUBLE PRECISION,
    timestamp TIMESTAMPTZ,
    PRIMARY KEY (exchange, symbol, timestamp)
);"
book_config[time_column]="timestamp"
book_config[chunk_interval]="10 minutes"
book_config[segmentby_column]="exchange, symbol"
book_config[orderby_column]="timestamp"
book_config[compress_interval]="10 minutes"
#book_config[retention_interval]="7 days"  # Only for production


# Add configurations to an array
table_configs=(trades_config book_config)

# Function to create hypertable
create_hypertable() {
    local -n config=$1
    local table_name=${config[name]}
    local create_command=${config[create_command]}
    local time_column=${config[time_column]}
    local chunk_interval=${config[chunk_interval]}

    docker exec -it $CONTAINER_NAME psql -U $PGUSER -d $DB_NAME -c "\dt" | grep -q $table_name
    if [ $? -ne 0 ]; then
        docker exec -it $CONTAINER_NAME psql -U $PGUSER -d $DB_NAME -c "$create_command SELECT create_hypertable('$table_name', '$time_column', chunk_time_interval => INTERVAL '$chunk_interval');"
        log_message "Hypertable $table_name created."
    else
        log_message "Hypertable $table_name already exists."
    fi
}

# Function to enable compression
enable_compression() {
    local -n config=$1
    local table_name=${config[name]}
    local segmentby_column=${config[segmentby_column]}
    local orderby_column=${config[orderby_column]}
    local compress_interval=${config[compress_interval]}

    docker exec -it $CONTAINER_NAME psql -U $PGUSER -d $DB_NAME -c "ALTER TABLE $table_name SET (timescaledb.compress, timescaledb.compress_segmentby = '$segmentby_column', timescaledb.compress_orderby = '$orderby_column'); SELECT add_compression_policy('$table_name', INTERVAL '$compress_interval', if_not_exists => true);"
    log_message "Compression enabled for $table_name."
}

# Function to set retention policy (only for production)
set_retention_policy() {
    local -n config=$1
    local table_name=${config[name]}
    local retention_interval=${config[retention_interval]}

    docker exec -it $CONTAINER_NAME psql -U $PGUSER -d $DB_NAME -c "SELECT add_retention_policy('$table_name', INTERVAL '$retention_interval', if_not_exists => true);"
    log_message "Retention policy set for $table_name."
}
# Function to check and create the database if it doesn't exist
ensure_database_exists() {
    log_message "Ensuring database $DB_NAME exists..."
    if ! docker exec -it $CONTAINER_NAME psql -U $PGUSER -tAc "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME'" | grep -q 1; then
        log_message "Database $DB_NAME does not exist. Creating database..."
        docker exec -it $CONTAINER_NAME psql -U $PGUSER -c "CREATE DATABASE $DB_NAME;"
        if [ $? -ne 0 ]; then
            handle_error "Failed to create database $DB_NAME"
            return 1
        fi
    else
        log_message "Database $DB_NAME already exists."
    fi
}



# Main Logic 
# Ensure the database exists
retry ensure_database_exists
# Apply configurations to each table
for table_config_name in "${table_configs[@]}"; do
    retry create_hypertable $table_config_name
    retry enable_compression $table_config_name

    if [ "$ENVIRONMENT" == "production" ]; then
        retry set_retention_policy $table_config_name
    fi
done

log_message "TimescaleDB setup completed."