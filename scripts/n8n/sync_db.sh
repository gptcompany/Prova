#!/bin/bash

# Configuration
PGUSER="postgres"
PGPASSWORD=$(aws ssm get-parameter --name timescaledbpassword --with-decryption --query 'Parameter.Value' --output text)
REMOTE_HOST=$(aws ssm get-parameter --name STANDBY_PUBLIC_IP --with-decryption --query 'Parameter.Value' --output text)
DB_NAME="db0"
PGPORT_SRC="5432"
PGPORT_DEST="5433"
TABLES=("trades" "book" "open_interest" "funding" "liquidations") # Add your table names here

# Log message function
log_message() {
    echo "$(date +"%Y-%m-%d %T") - $1"
}

# Compare and synchronize schema
compare_and_sync_schema() {
    for table in "${TABLES[@]}"; do
        log_message "Checking schema for table $table..."
        # Dump schema from source and destination tables
        pg_dump -h $REMOTE_HOST -p $PGPORT_SRC -U $PGUSER -d $DB_NAME -t $table --schema-only > /tmp/schema_src_$table.sql
        pg_dump -h $REMOTE_HOST -p $PGPORT_DEST -U $PGUSER -d $DB_NAME -t $table --schema-only > /tmp/schema_dest_$table.sql

        # Compare schemas (this is a simple diff, you might need a more sophisticated comparison for complex schemas)
        DIFF=$(diff /tmp/schema_src_$table.sql /tmp/schema_dest_$table.sql)
        if [ "$DIFF" != "" ]; then
            log_message "Schema differences found for table $table. Synchronizing..."
            # Apply the source schema to the destination (be careful with this operation in production environments)
            psql -h $REMOTE_HOST -p $PGPORT_DEST -U $PGUSER -d $DB_NAME < /tmp/schema_src_$table.sql
        else
            log_message "No schema differences found for table $table."
        fi
    done
}

# Identify new records and copy
copy_new_records() {
    for table in "${TABLES[@]}"; do
        # Identify the latest timestamp or ID in the destination database
        LATEST=$(psql -h $REMOTE_HOST -p $PGPORT_DEST -U $PGUSER -d $DB_NAME -tAc "SELECT MAX(timestamp) FROM $table;")
        log_message "Latest record timestamp in $table on destination is $LATEST"

        # Copy new records to a CSV file
        psql -h $REMOTE_HOST -p $PGPORT_SRC -U $PGUSER -d $DB_NAME -c "\COPY (SELECT * FROM $table WHERE timestamp > '$LATEST') TO '/tmp/$table.csv' CSV HEADER;"

        # Import new records into the destination database, handling duplicates
        psql -h $REMOTE_HOST -p $PGPORT_DEST -U $PGUSER -d $DB_NAME -c "\COPY $table FROM '/tmp/$table.csv' CSV HEADER ON CONFLICT DO NOTHING;"
    done
}

# Main
export PGPASSWORD

# Check and synchronize schemas
compare_and_sync_schema

# Copy new records
copy_new_records

# Cleanup temp files
rm /tmp/schema_src_*.sql
rm /tmp/schema_dest_*.sql
rm /tmp/*.csv

log_message "Data synchronization completed."
