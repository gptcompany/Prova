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
copy_new_records_fdw() {
    # Define connection string for dblink outside of the heredoc
    local conn_str="dbname=$DB_NAME host=localhost port=$PGPORT_SRC user=postgres password=$TIMESCALEDBPASSWORD"

    # Use the connection string in the heredoc with variables already expanded
    trades_commands=$(cat <<EOF
BEGIN;
LOAD 'timescaledb';
CREATE TEMP TABLE IF NOT EXISTS temp_trades (LIKE trades INCLUDING ALL);
INSERT INTO temp_trades (exchange, symbol, side, amount, price, timestamp, receipt, id)
SELECT exchange, symbol, side, amount, price, timestamp, receipt, id FROM dblink('${conn_str}', 'SELECT exchange, symbol, side, amount, price, timestamp, receipt, id FROM trades') AS source_table(exchange TEXT, symbol TEXT, side TEXT, amount DOUBLE PRECISION, price DOUBLE PRECISION, timestamp TIMESTAMPTZ, receipt TIMESTAMPTZ, id BIGINT);
INSERT INTO trades SELECT * FROM temp_trades ON CONFLICT DO NOTHING;
DROP TABLE temp_trades;
COMMIT;
EOF
)
    execute_as_postgres "psql -p $PGPORT_DEST -d $DB_NAME -c \"$trades_commands\""

    # Repeat for 'book' with appropriate modifications
}
setup_schema() {
    # Step 1: Optionally, dump schema from source database (run this on the source database or a machine with access to it)
    pg_dump -h $REMOTE_HOST -U postgres -p $PGPORT_SRC -d $DB_NAME --schema-only --no-owner --no-acl --file="source_schema.sql"
    
    # Step 2: Apply schema to target database if necessary (e.g., if 'trades' table doesn't exist)
    if ! execute_as_postgres "psql -p $PGPORT_DEST -d $DB_NAME -c \"SELECT to_regclass('public.trades')\" | grep -q '^public.trades$'"; then
        log_message "Applying schema to target database..."
        execute_as_postgres "psql -p $PGPORT_DEST -d $DB_NAME -f source_schema.sql"
    else
        log_message "Required schema already set up on target database."
    fi
}

# Main Execution Flow
log_message "Checking if PostgreSQL server is ready on source database..."
if sudo -i -u barman /bin/bash -c "ssh postgres@$REMOTE_HOST 'pg_isready -p $PGPORT_SRC'"; then
    log_message "PostgreSQL server is ready. Starting data synchronization process..."
    #ensure_timescaledb_preloaded
    #check_timescaledb_preload
    #ensure_setup
    setup_schema
    copy_new_records_fdw
    log_message "Data synchronization completed."
else
    log_message "PostgreSQL server is not ready. Attempt to try again in 180 seconds."
    exit 1
fi

