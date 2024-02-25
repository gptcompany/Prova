#!/bin/bash
# Environment (set this to either 'development' or 'production')
ENVIRONMENT="development"
DB_NAME="db0"
PGUSER="postgres"
PGHOST=$(aws ssm get-parameter --name STANDBY_PUBLIC_IP --with-decryption --query 'Parameter.Value' --output text)
PGPORT="5433"
PGPASSWORD=$(aws ssm get-parameter --name timescaledbpassword --with-decryption --query 'Parameter.Value' --output text)
export PGUSER PGHOST PGPORT PGPASSWORD

# Function to log messages
log_message() {
    local message="$(date +"%Y-%m-%d %T"): $1"
    echo "$message" >&2
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

# Declare table configurations
declare -A trades_config
declare -A book_config
declare -A oi_config
declare -A funding_config
declare -A liquidations_config

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
    data JSONB,
    receipt TIMESTAMPTZ,
    update_type TEXT,
    PRIMARY KEY (exchange, symbol, receipt, update_type)
);"
book_config[time_column]="receipt"
book_config[chunk_interval]="10 minutes"
book_config[segmentby_column]="exchange, symbol"  # Ensure this matches Python logic
book_config[orderby_column]="receipt, update_type"  # Ensure this matches Python logic
book_config[compress_interval]="10 minutes"
book_config[retention_interval]="7 days"  # Only for production

# Existing configurations for 'trades' and 'book' tables...

# Additional table configurations for oi, funding, and liquidations
oi_config[name]="open_interest"
oi_config[create_command]="CREATE TABLE open_interest (
    exchange TEXT,
    symbol TEXT,
    open_interest DOUBLE PRECISION,
    timestamp TIMESTAMPTZ,
    PRIMARY KEY (exchange, symbol, timestamp)
);"
oi_config[time_column]="timestamp"
oi_config[chunk_interval]="10 minutes"
oi_config[segmentby_column]="exchange, symbol"
oi_config[orderby_column]="timestamp"
oi_config[compress_interval]="10 minutes"
oi_config[retention_interval]="7 days"  # Only for production

funding_config[name]="funding"
funding_config[create_command]="CREATE TABLE funding (
    exchange TEXT,
    symbol TEXT,
    mark_price DOUBLE PRECISION,
    rate DOUBLE PRECISION,
    timestamp TIMESTAMPTZ,
    next_funding_time TIMESTAMPTZ,
    PRIMARY KEY (exchange, symbol, timestamp)
);"
funding_config[time_column]="timestamp"
funding_config[chunk_interval]="10 minutes"
funding_config[segmentby_column]="exchange, symbol"
funding_config[orderby_column]="timestamp"
funding_config[compress_interval]="10 minutes"
funding_config[retention_interval]="7 days"  # Only for production

liquidations_config[name]="liquidations"
liquidations_config[create_command]="CREATE TABLE liquidations (
    exchange TEXT,
    symbol TEXT,
    side TEXT,
    quantity DOUBLE PRECISION,
    price DOUBLE PRECISION,
    timestamp TIMESTAMPTZ,
    id BIGINT,
    PRIMARY KEY (exchange, symbol, timestamp, id)
);"
liquidations_config[time_column]="timestamp"
liquidations_config[chunk_interval]="10 minutes"
liquidations_config[segmentby_column]="exchange, symbol"
liquidations_config[orderby_column]="timestamp, id"
liquidations_config[compress_interval]="10 minutes"
liquidations_config[retention_interval]="7 days"  # Only for production

# Add new table configurations to the array
table_configs=(trades_config book_config oi_config funding_config liquidations_config)

# Function to create hypertable
create_hypertable() {
    local -n config=$1
    local table_name=${config[name]}
    local create_command=${config[create_command]}
    local time_column=${config[time_column]}
    local chunk_interval=${config[chunk_interval]}
    if  psql -U $PGUSER -h $PGHOST -p $PGPORT -d $DB_NAME -c "SELECT * FROM timescaledb_information.tables WHERE table_name = '$table_name';" | grep -q $table_name; then
        log_message "Creating hypertable $table_name."
        psql -U $PGUSER -h $PGHOST -p $PGPORT -d $DB_NAME -c "SELECT create_hypertable('$table_name', '$time_column', chunk_time_interval => INTERVAL '$chunk_interval');"
    fi
    # Check if the table is already a hypertable
    if  psql -U $PGUSER -h $PGHOST -p $PGPORT -d $DB_NAME -c "SELECT * FROM timescaledb_information.hypertables WHERE hypertable_name = '$table_name';" | grep -q $table_name; then
        log_message "Hypertable $table_name already exists."
    else
        log_message "Creating hypertable $table_name."
        psql -U $PGUSER -h $PGHOST -p $PGPORT -d $DB_NAME -c "$create_command"
        psql -U $PGUSER -h $PGHOST -p $PGPORT -d $DB_NAME -c "SELECT create_hypertable('$table_name', '$time_column', chunk_time_interval => INTERVAL '$chunk_interval');"
    fi
}


# Function to enable compression
enable_compression() {
    local -n config=$1
    local table_name=${config[name]}
    local segmentby_column=${config[segmentby_column]}
    local orderby_column=${config[orderby_column]}
    local compress_interval=${config[compress_interval]}

    # Check if compression is already enabled
    log_message "Checking compression for $table_name."
    if ! psql -U $PGUSER -h $PGHOST -p $PGPORT -d $DB_NAME -c "SELECT * FROM timescaledb_information.hypertables WHERE hypertable_name = '$table_name';" | grep -q $table_name; then
        log_message "Compression already enabled for $table_name."
    else
        log_message "Enabling compression for $table_name."
        psql -U $PGUSER -h $PGHOST -p $PGPORT -d $DB_NAME -c "ALTER TABLE $table_name SET (timescaledb.compress, timescaledb.compress_segmentby = '$segmentby_column', timescaledb.compress_orderby = '$orderby_column');"
        psql -U $PGUSER -h $PGHOST -p $PGPORT -d $DB_NAME -c "SELECT add_compression_policy('$table_name', INTERVAL '$compress_interval', if_not_exists => true);"
    fi
}


# Function to set retention policy (only for production)
set_retention_policy() {
    local -n config=$1
    local table_name=${config[name]}
    local retention_interval=${config[retention_interval]}

    psql -U $PGUSER -h $PGHOST -p $PGPORT -d $DB_NAME -c "SELECT add_retention_policy('$table_name', INTERVAL '$retention_interval', if_not_exists => true);"
    log_message "Retention policy set for $table_name."
}

# Function to check and create the database if it doesn't exist
ensure_database_exists() {
    log_message "Ensuring database $DB_NAME exists..."
    if ! psql -U $PGUSER -h $PGHOST -p $PGPORT -tAc "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME'" | grep -q 1; then
        log_message "Database $DB_NAME does not exist. Creating database..."
        psql -U $PGUSER -h $PGHOST -p $PGPORT -c "CREATE DATABASE $DB_NAME;"
        if [ $? -ne 0 ]; then
            handle_error "Failed to create database $DB_NAME"
            return 1
        fi
    else
        log_message "Database $DB_NAME already exists."
    fi
}
# Function to check if psql is installed
check_psql_installed() {
    if ! command -v psql > /dev/null; then
        log_message "psql (PostgreSQL command-line tool) is not installed. Please install it to proceed."
        exit 1
    else
        log_message "psql is installed."
    fi
}
# Function to check if TimescaleDB is installed
check_timescaledb_installed() {
    log_message "Checking if TimescaleDB is installed..."
    if psql -U $PGUSER -h $PGHOST -p $PGPORT -d $DB_NAME -c "SELECT 1 FROM pg_extension WHERE extname='timescaledb';" | grep -q 1; then
        log_message "TimescaleDB is installed."

    else
        log_message "TimescaleDB is not installed in $DB_NAME. Installing:"
        psql -U $PGUSER -h $PGHOST -p $PGPORT -d $DB_NAME -c "CREATE EXTENSION IF NOT EXISTS timescaledb;"
    fi
    log_message "Checking if TimescaleDB is installed..."
    if psql -U $PGUSER -h $PGHOST -p $PGPORT -d $DB_NAME -c "SELECT 1 FROM pg_extension WHERE extname='timescaledb';" | grep -q 1; then
        log_message "TimescaleDB is installed."
    else
        log_message "TimescaleDB is not installed in $DB_NAME."
        exit 1
    fi
}
# Main Logic

# Ensure the database exists
retry ensure_database_exists
# Check if TimescaleDB is installed
check_timescaledb_installed
for table_config_name in "${table_configs[@]}"; do
    retry create_hypertable $table_config_name
    retry enable_compression $table_config_name

    if [ "$ENVIRONMENT" == "production" ]; then
        retry set_retention_policy $table_config_name
    fi
done

log_message "TimescaleDB setup completed."
