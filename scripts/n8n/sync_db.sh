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

# Function to set up foreign data wrapper
setup_fdw() {
    log_message "Setting up Foreign Data Wrapper..."
    
    # Create server connection
    # Adjust the FDW setup to use localhost for the source database connection
    execute_as_postgres "psql -p $PGPORT_DEST -d $DB_NAME -c \"CREATE SERVER IF NOT EXISTS source_db FOREIGN DATA WRAPPER postgres_fdw OPTIONS (dbname '$DB_NAME', host 'localhost', port '$PGPORT_SRC');\""
    
    # Create user mapping
    # Replace 'your_remote_user' and 'your_password' with actual credentials
    execute_as_postgres "psql -p $PGPORT_DEST -d $DB_NAME -c \"CREATE USER MAPPING IF NOT EXISTS FOR CURRENT_USER SERVER source_db OPTIONS (user 'postgres', password '$TIMESCALEDBPASSWORD');\""
    
    # Import foreign schema for each table
    for table in "${TABLES[@]}"; do
        execute_as_postgres "psql -p $PGPORT_DEST -d $DB_NAME -c \"IMPORT FOREIGN SCHEMA public LIMIT TO ($table) FROM SERVER source_db INTO public;\""
    done
}

# Function to synchronize data using FDW
copy_new_records_fdw() {
    for table in "${TABLES[@]}"; do
        log_message "Synchronizing new records for table $table..."
        
        # Directly copy new records using FDW with ON CONFLICT DO NOTHING
        execute_as_postgres "psql -p $PGPORT_DEST -d $DB_NAME -c \"INSERT INTO $table SELECT * FROM $table@source_db ON CONFLICT DO NOTHING;\""
    done
}

# Main Execution Flow
ensure_extensions_installed
setup_fdw
copy_new_records_fdw

log_message "Data synchronization completed."
