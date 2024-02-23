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

# Function to ensure required extensions are installed
ensure_extensions_installed() {
    log_message "Ensuring required extensions are installed..."
    execute_as_postgres "psql -p $PGPORT_DEST -d $DB_NAME -c 'CREATE EXTENSION IF NOT EXISTS postgres_fdw;'"
}

# Function to set up foreign data wrapper and create foreign tables directly
setup_fdw() {
    log_message "Setting up Foreign Data Wrapper..."

    execute_as_postgres "psql -p $PGPORT_DEST -d $DB_NAME -c \"CREATE SERVER IF NOT EXISTS source_db FOREIGN DATA WRAPPER postgres_fdw OPTIONS (dbname '$DB_NAME', host 'localhost', port '$PGPORT_SRC');\""
    log_message "Foreign Data Wrapper Server Configuration Updated."

    execute_as_postgres "psql -p $PGPORT_DEST -d $DB_NAME -c \"CREATE USER MAPPING IF NOT EXISTS FOR CURRENT_USER SERVER source_db OPTIONS (user 'postgres', password '$TIMESCALEDBPASSWORD');\""
    
    # Directly create foreign tables instead of importing schema
    for table in "${TABLES[@]}"; do
        # Drop the foreign table if it exists to avoid conflicts
        execute_as_postgres "psql -p $PGPORT_DEST -d $DB_NAME -c \"DROP FOREIGN TABLE IF EXISTS foreign_$table CASCADE;\""
        
        # Create the foreign table
        execute_as_postgres "psql -p $PGPORT_DEST -d $DB_NAME -c \"CREATE FOREIGN TABLE foreign_$table LIKE public.$table INCLUDING ALL SERVER source_db OPTIONS (schema_name 'public', table_name '$table');\""
    done
}

# Adjusted data synchronization function
copy_new_records_fdw() {
    for table in "${TABLES[@]}"; do
        log_message "Synchronizing new records for table $table..."
        # Insert data from foreign tables to local tables
        execute_as_postgres "psql -p $PGPORT_DEST -d $DB_NAME -c \"INSERT INTO public.$table SELECT * FROM foreign_$table ON CONFLICT DO NOTHING;\""
    done
}


# Main Execution Flow
log_message "Checking if PostgreSQL server is ready on source database..."
sudo -i -u barman /bin/bash -c "ssh postgres@$REMOTE_HOST 'pg_isready -p $PGPORT_SRC'"
if [ $? -eq 0 ]; then
    log_message "PostgreSQL server is ready. Starting data synchronization process..."
    ensure_extensions_installed
    setup_fdw
    copy_new_records_fdw
    log_message "Data synchronization completed."
else
    log_message "PostgreSQL server is not ready. Attempt to try again in 180 seconds."
    exit 1
fi
