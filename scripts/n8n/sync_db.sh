#!/bin/bash

# Configuration
REMOTE_HOST=$(aws ssm get-parameter --name STANDBY_PUBLIC_IP --with-decryption --query 'Parameter.Value' --output text)
DB_NAME="db0"
PGPORT_SRC="5432"
PGPORT_DEST="5433"
TABLES=("trades" "book" "open_interest" "funding" "liquidations")
TIMESCALEDBPASSWORD=$(aws ssm get-parameter --name timescaledbpassword --with-decryption --query 'Parameter.Value' --output text)

# Log message function
log_message() {
    echo "$(date +"%Y-%m-%d %T") - $1"
}

# Execute a command as postgres user on the remote host
execute_as_postgres() {
    ssh -T postgres@$REMOTE_HOST "$1"
}

# Ensure TimescaleDB extension is installed and preloaded
ensure_timescaledb_preloaded() {
    log_message "Ensuring TimescaleDB extension is installed and preloaded..."
    local check_extension="psql -p $PGPORT_DEST -d $DB_NAME -c 'CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE;'"
    local check_preload="psql -p $PGPORT_DEST -d $DB_NAME -c '\dx' | grep timescaledb"
    
    execute_as_postgres "$check_extension"
    execute_as_postgres "$check_preload" || log_message "TimescaleDB extension not found. Ensure it is installed and included in shared_preload_libraries in postgresql.conf and restart PostgreSQL."
}

# Check if TimescaleDB is preloaded properly
check_timescaledb_preload() {
    local preload_check="psql -p $PGPORT_DEST -d $DB_NAME -c 'SHOW shared_preload_libraries;' | grep timescaledb"
    if execute_as_postgres "$preload_check"; then
        log_message "TimescaleDB is preloaded."
    else
        log_message "TimescaleDB is not preloaded. Please add 'timescaledb' to shared_preload_libraries in your postgresql.conf and restart PostgreSQL."
    fi
}

# Ensure required extensions are installed and FDW setup
ensure_setup() {
    log_message "Ensuring setup..."
    execute_as_postgres "psql -p $PGPORT_DEST -d $DB_NAME -c 'CREATE EXTENSION IF NOT EXISTS postgres_fdw;'"
    execute_as_postgres "psql -p $PGPORT_DEST -d $DB_NAME -c \"CREATE SERVER IF NOT EXISTS source_db FOREIGN DATA WRAPPER postgres_fdw OPTIONS (dbname '$DB_NAME', host 'localhost', port '$PGPORT_SRC');\""
    execute_as_postgres "psql -p $PGPORT_DEST -d $DB_NAME -c \"ALTER SERVER source_db OPTIONS (SET host 'localhost');\""
    execute_as_postgres "psql -p $PGPORT_DEST -d $DB_NAME -c \"CREATE USER MAPPING IF NOT EXISTS FOR CURRENT_USER SERVER source_db OPTIONS (user 'postgres', password '$TIMESCALEDBPASSWORD');\""
}
# Function to synchronize data using FDW, adjusted for TimescaleDB hypertables
copy_new_records_fdw() {
    # Adjusted to correctly reference primary keys and existing columns in the synchronization logic
    # Note: You might need to adjust the conflict columns based on your hypertable's primary key and unique constraints
    local sync_sql_template="INSERT INTO %s SELECT * FROM dblink('dbname=$DB_NAME host=localhost port=$PGPORT_SRC user=postgres password=$TIMESCALEDBPASSWORD','SELECT %s FROM %s') AS source(%s) ON CONFLICT (%s) DO NOTHING;"

    # Define sync SQL for each table based on its schema and unique constraints
    local sync_sql_trades=$(printf "$sync_sql_template" "trades" "exchange, symbol, side, amount, price, timestamp, receipt, id" "trades" "exchange TEXT, symbol TEXT, side TEXT, amount DOUBLE PRECISION, price DOUBLE PRECISION, timestamp TIMESTAMPTZ, receipt TIMESTAMPTZ, id BIGINT" "exchange, symbol, timestamp, id")
    
    local sync_sql_book=$(printf "$sync_sql_template" "book" "exchange, symbol, data, receipt, update_type" "book" "exchange TEXT, symbol TEXT, data JSONB, receipt TIMESTAMPTZ, update_type TEXT" "exchange, symbol, receipt, update_type")
    
    # Execute the constructed SQL commands to synchronize data
    execute_as_postgres "psql -p $PGPORT_DEST -d $DB_NAME -c \"$sync_sql_trades\""
    execute_as_postgres "psql -p $PGPORT_DEST -d $DB_NAME -c \"$sync_sql_book\""

    # You can similarly define and execute sync SQL for 'open_interest', 'funding', and 'liquidations' tables
    # Ensure to define the SELECT list and source column definitions to match each table's schema
}

# Rest of your script remains unchanged...

# Main Execution Flow
log_message "Checking if PostgreSQL server is ready on source database..."
if sudo -i -u barman /bin/bash -c "ssh postgres@$REMOTE_HOST 'pg_isready -p $PGPORT_SRC'"; then
    log_message "PostgreSQL server is ready. Starting data synchronization process..."
    ensure_timescaledb_preloaded
    check_timescaledb_preload
    ensure_setup
    copy_new_records_fdw
    log_message "Data synchronization completed."
else
    log_message "PostgreSQL server is not ready. Attempt to try again in 180 seconds."
    exit 1
fi

