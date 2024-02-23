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

# Ensure required extensions are installed
ensure_extensions_installed() {
    log_message "Ensuring required extensions are installed..."
    execute_as_postgres "psql -p $PGPORT_DEST -d $DB_NAME -c 'CREATE EXTENSION IF NOT EXISTS postgres_fdw;'"
}

# Set up foreign data wrapper
setup_fdw() {
    log_message "Setting up Foreign Data Wrapper..."
    execute_as_postgres "psql -p $PGPORT_DEST -d $DB_NAME -c \"CREATE SERVER IF NOT EXISTS source_db FOREIGN DATA WRAPPER postgres_fdw OPTIONS (dbname '$DB_NAME', host 'localhost', port '$PGPORT_SRC');\""
    log_message "Updating Foreign Data Wrapper Server Configuration..."
    execute_as_postgres "psql -p $PGPORT_DEST -d $DB_NAME -c \"ALTER SERVER source_db OPTIONS (SET host 'localhost');\""
    execute_as_postgres "psql -p $PGPORT_DEST -d $DB_NAME -c \"CREATE USER MAPPING IF NOT EXISTS FOR CURRENT_USER SERVER source_db OPTIONS (user 'postgres', password '$TIMESCALEDBPASSWORD');\""
}

# Function to synchronize data using FDW
copy_new_records_fdw() {
    for table in "${TABLES[@]}"; do
        log_message "Synchronizing new records for table $table..."
        execute_as_postgres "psql -p $PGPORT_DEST -d $DB_NAME -c \"INSERT INTO public.$table SELECT * FROM public.$table ON CONFLICT DO NOTHING;\""
    done
}
# Assuming previous setup and configuration steps are correct

# Function to synchronize data using FDW with diagnostic logging
copy_new_records_fdw_debug() {
    for table in "${TABLES[@]}"; do
        log_message "Attempting to synchronize new records for table $table..."
        
        # Diagnostic: Count records in source table
        record_count_source=$(execute_as_postgres "psql -p $PGPORT_SRC -d $DB_NAME -c \"SELECT COUNT(*) FROM $table;\"")
        log_message "Source table $table record count: $record_count_source"
        
        # Attempt to synchronize records
        result=$(execute_as_postgres "psql -p $PGPORT_DEST -d $DB_NAME -c \"INSERT INTO public.$table SELECT * FROM public.$table WHERE NOT EXISTS (SELECT 1 FROM public.$table WHERE source_id = destination_id) ON CONFLICT DO NOTHING RETURNING *;\"")
        log_message "Synchronization result for table $table: $result"
    done
}

# Replace the call to `copy_new_records_fdw` with `copy_new_records_fdw_debug` in the main execution flow

# Main Execution Flow
log_message "Checking if PostgreSQL server is ready on source database..."
if sudo -i -u barman /bin/bash -c "ssh postgres@$REMOTE_HOST 'pg_isready -p $PGPORT_SRC'"; then
    log_message "PostgreSQL server is ready. Starting data synchronization process..."
    ensure_extensions_installed
    setup_fdw
    # Instead of checking and importing schema for each table in a DO block, handle this manually or ensure it's pre-configured.
    copy_new_records_fdw_debug
    log_message "Data synchronization completed."
else
    log_message "PostgreSQL server is not ready. Attempt to try again in 180 seconds."
    exit 1
fi
