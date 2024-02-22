#!/bin/bash

# Configuration
REMOTE_HOST=$(aws ssm get-parameter --name STANDBY_PUBLIC_IP --with-decryption --query 'Parameter.Value' --output text)
DB_NAME="db0"
PGPORT_SRC="5432"
PGPORT_DEST="5433"
TABLES=("trades" "book" "open_interest" "funding" "liquidations") # Add your table names here

# Log message function
log_message() {
    echo "$(date +"%Y-%m-%d %T") - $1"
}

# Execute a command as postgres user on the remote host
execute_as_postgres() {
    ssh -T postgres@$REMOTE_HOST "$1"
}

# Compare and synchronize schema
compare_and_sync_schema() {
    for table in "${TABLES[@]}"; do
        log_message "Checking schema for table $table..."
        # Dump schema from source and destination tables and compare
        execute_as_postgres "pg_dump -p $PGPORT_SRC -d $DB_NAME -t $table --schema-only" > /tmp/schema_src_$table.sql
        execute_as_postgres "pg_dump -p $PGPORT_DEST -d $DB_NAME -t $table --schema-only" > /tmp/schema_dest_$table.sql

        # Compare schemas
        DIFF=$(diff /tmp/schema_src_$table.sql /tmp/schema_dest_$table.sql)
        if [ "$DIFF" != "" ]; then
            log_message "Schema differences found for table $table. Synchronizing..."
            # Apply the source schema to the destination
            cat /tmp/schema_src_$table.sql | execute_as_postgres "psql -p $PGPORT_DEST -d $DB_NAME"
        else
            log_message "No schema differences found for table $table."
        fi
    done
}

# Directly copy new records using dblink
copy_new_records_dblink() {
    for table in "${TABLES[@]}"; do
        log_message "Copying new records for table $table..."

        # Command to copy new records using dblink
        CMD_COPY="
        INSERT INTO $table
        SELECT * FROM dblink('dbname=$DB_NAME port=$PGPORT_SRC host=localhost user=postgres',
        'SELECT * FROM $table WHERE timestamp > (SELECT COALESCE(MAX(timestamp), ''1970-01-01''::timestamp) FROM $table)') AS t1
        ON CONFLICT DO NOTHING;"
        
        execute_as_postgres "$CMD_COPY"
    done
}

# Main

# Check and synchronize schemas
compare_and_sync_schema

# Copy new records
copy_new_records_dblink

# Cleanup temp files
rm /tmp/schema_src_*.sql
rm /tmp/schema_dest_*.sql

log_message "Data synchronization completed."
