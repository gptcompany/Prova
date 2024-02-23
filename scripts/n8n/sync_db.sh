#!/bin/bash

# Configuration
REMOTE_HOST=$(aws ssm get-parameter --name STANDBY_PUBLIC_IP --with-decryption --query 'Parameter.Value' --output text)
DB_NAME="db0"
PGPORT_SRC="5432"
PGPORT_DEST="5433"
TABLES=("trades" "book" "open_interest" "funding" "liquidations") # Define your table names here
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
ensure_timescaledb() {
    log_message "Ensuring TimescaleDB extension is installed and preloaded..."
    execute_as_postgres "psql -p $PGPORT_DEST -d $DB_NAME -c 'CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE;'"
    # Attempt to reload TimescaleDB extension to ensure it's properly preloaded
    execute_as_postgres "psql -p $PGPORT_DEST -d $DB_NAME -c '\dx' | grep timescaledb"
    if [ $? -ne 0 ]; then
        log_message "TimescaleDB extension not found after attempting to load. Please ensure it is installed and included in shared_preload_libraries in your PostgreSQL configuration."
        exit 1
    else
        log_message "TimescaleDB extension is confirmed installed."
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

# Function to synchronize data using FDW
copy_new_records_fdw() {
    # Adjusted to correctly reference primary keys and existing columns in the synchronization logic
    local sync_sql_trades="INSERT INTO trades SELECT * FROM dblink('dbname=$DB_NAME host=localhost port=$PGPORT_SRC user=postgres password=$TIMESCALEDBPASSWORD','SELECT exchange, symbol, side, amount, price, timestamp, receipt, id FROM trades') AS source(exchange TEXT, symbol TEXT, side TEXT, amount DOUBLE PRECISION, price DOUBLE PRECISION, timestamp TIMESTAMPTZ, receipt TIMESTAMPTZ, id BIGINT) ON CONFLICT (exchange, symbol, timestamp, id) DO NOTHING;"
    
    local sync_sql_book="INSERT INTO book SELECT * FROM dblink('dbname=$DB_NAME host=localhost port=$PGPORT_SRC user=postgres password=$TIMESCALEDBPASSWORD','SELECT exchange, symbol, data, receipt, update_type FROM book') AS source(exchange TEXT, symbol TEXT, data JSONB, receipt TIMESTAMPTZ, update_type TEXT) ON CONFLICT (exchange, symbol, receipt, update_type) DO NOTHING;"
    
    # Define similar SQL statements for 'open_interest', 'funding', and 'liquidations' based on their respective schemas

    execute_as_postgres "psql -p $PGPORT_DEST -d $DB_NAME -c \"$sync_sql_trades\""
    execute_as_postgres "psql -p $PGPORT_DEST -d $DB_NAME -c \"$sync_sql_book\""
    # Execute similar commands for other tables
}

# Main execution flow
log_message "Checking if PostgreSQL server is ready on source database..."
if sudo -i -u barman /bin/bash -c "ssh postgres@$REMOTE_HOST 'pg_isready -p $PGPORT_SRC'"; then
    log_message "PostgreSQL server is ready. Starting data synchronization process..."
    ensure_timescaledb
    ensure_setup
    copy_new_records_fdw
    log_message "Data synchronization completed."
else
    log_message "PostgreSQL server is not ready. Attempt to try again in 180 seconds."
    exit 1
fi
