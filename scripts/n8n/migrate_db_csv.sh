#!/bin/bash

# Configuration
REMOTE_HOST=$(aws ssm get-parameter --name STANDBY_PUBLIC_IP --with-decryption --query 'Parameter.Value' --output text)
DB_NAME="db0"
PGPORT_SRC="5432"
PGPORT_DEST="5433"
TABLES=("trades" "book" "open_interest" "funding" "liquidations")
TSDBADMIN="tsdbadmin"
TIMESCALEDBPASSWORD=$(aws ssm get-parameter --name timescaledbpassword --with-decryption --query 'Parameter.Value' --output text)
SOURCE=postgres://postgres:$TIMESCALEDBPASSWORD@localhost:$PGPORT_SRC/$DB_NAME
TARGET=postgres://postgres:$TIMESCALEDBPASSWORD@localhost:$PGPORT_DEST/$DB_NAME

# Execute a command as postgres user on the remote host
execute_as_postgres() {
    ssh -T postgres@$REMOTE_HOST "PGPASSWORD='$TIMESCALEDBPASSWORD' $1"
}

# Dump and restore schema
echo "Dumping the database roles from the source database"
execute_as_postgres "pg_dumpall -d '$SOURCE' -l '$DB_NAME' --quote-all-identifiers --roles-only --file=roles.sql"

echo "Migrating schema pre-data"
execute_as_postgres "PGPASSWORD='$TIMESCALEDBPASSWORD' pg_dump -U postgres -h localhost -p $PGPORT_SRC -Fc -v --section=pre-data --exclude-schema='_timescaledb*' -f dump_pre_data.dump $DB_NAME"

echo "Restoring the dump pre-data"
execute_as_postgres "PGPASSWORD='$TIMESCALEDBPASSWORD' pg_restore -U postgres -h localhost -p $PGPORT_DEST --no-owner -Fc -v -d $DB_NAME dump_pre_data.dump"

# Convert tables to hypertables
for TABLE_NAME in "${TABLES[@]}"; do
    echo "Processing table: $TABLE_NAME"
    
    # Define time column name based on the table
    TIME_COLUMN_NAME="timestamp"
    if [ "$TABLE_NAME" = "book" ]; then
        TIME_COLUMN_NAME="receipt"
    fi
    
    # Check if the table exists before converting to hypertable
    echo "Checking if $TABLE_NAME exists"
    execute_as_postgres "psql -d $DB_NAME -c \"SELECT to_regclass('public.$TABLE_NAME');\""

    # Convert table to hypertable
    echo "Converting $TABLE_NAME to hypertable"
    execute_as_postgres "psql -d $DB_NAME -c \"SELECT create_hypertable('$TABLE_NAME', '$TIME_COLUMN_NAME', if_not_exists => TRUE, chunk_time_interval => INTERVAL '10 minutes');\""
done

# Data export, import, and ensure compression
echo "Looping through each table to export, import data, and ensure compression"
for TABLE_NAME in "${TABLES[@]}"; do
    FILE_NAME="${TABLE_NAME}.csv"
    
    # Export data from source table to CSV
    execute_as_postgres "psql -d $DB_NAME -c \"\copy (SELECT * FROM $TABLE_NAME) TO '$FILE_NAME' WITH (FORMAT CSV);\""

    # Check and remove retention policy if it exists
    echo "Checking and removing retention policy for $TABLE_NAME if exists..."
    remove_policy_cmd="psql -p $PGPORT_DEST -d $DB_NAME -c \"SELECT remove_retention_policy('public.$TABLE_NAME', if_exists => TRUE);\""
    execute_as_postgres "$remove_policy_cmd"

    # Import data from CSV into target table
    echo "Importing data into $TABLE_NAME"
    execute_as_postgres "psql -d $DB_NAME -c \"\copy $TABLE_NAME FROM '$FILE_NAME' WITH (FORMAT CSV);\""

    # Ensure compression is enabled for the hypertable
    echo "Ensuring compression is enabled for $TABLE_NAME"
    compression_cmd="psql -p $PGPORT_DEST -d $DB_NAME -c \"ALTER TABLE $TABLE_NAME SET (timescaledb.compress, timescaledb.compress_segmentby = 'YOUR_COLUMN'); SELECT add_compression_policy('$TABLE_NAME', INTERVAL '7 days', if_not_exists => TRUE);\""
    execute_as_postgres "$compression_cmd"
    
    # Cleanup: remove the CSV file
    execute_as_postgres "rm ~/$FILE_NAME"
done

echo "Data migration completed."




