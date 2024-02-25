#!/bin/bash

# Configuration
REMOTE_HOST=$(aws ssm get-parameter --name STANDBY_PUBLIC_IP --with-decryption --query 'Parameter.Value' --output text)
DB_NAME="db0"
PGPORT_SRC="5432"
PGPORT_DEST="5433"
TABLES=("trades" "book" "open_interest" "funding" "liquidations")
TSDBADMIN="tsdbadmin"
TIMESCALEDBPASSWORD=$(aws ssm get-parameter --name timescaledbpassword --with-decryption --query 'Parameter.Value' --output text)
export SOURCE=postgres://postgres:$TIMESCALEDBPASSWORD@localhost:$PGPORT_SRC/$DB_NAME
export TARGET=postgres://postgres:$TIMESCALEDBPASSWORD@localhost:$PGPORT_DEST/$DB_NAME
# Execute a command as postgres user on the remote host
execute_as_postgres() {
    ssh -T postgres@$REMOTE_HOST "export PGPASSWORD='$TIMESCALEDBPASSWORD' $1"
}
# Dump the database roles from the source database
echo "Dump the database roles from the source database"
execute_as_postgres "pg_dumpall -d "$SOURCE" \
  -l $DB_NAME \
  --quote-all-identifiers \
  --roles-only \
  --file=roles.sql"
# Execute the command adding the --no-role-passwords flag. if errors in above commands


# Migrating schema pre-data
echo "Migrating schema pre-data"
execute_as_postgres "pg_dump -U postgres -W \
-h localhost -p $PGPORT_SRC -Fc -v \
--section=pre-data --exclude-schema="_timescaledb*" \
-f dump_pre_data.dump $DB_NAME"
echo "Restoring the dump pre data"
execute_as_postgres "pg_restore -U tsdbadmin -W \
-h localhost -p $PGPORT_DEST --no-owner -Fc \
-v -d tsdb dump_pre_data.dump"

#execute_as_postgres "psql "postgres://tsdbadmin:$TIMESCALEDBPASSWORD@localhost:$PGPORT_DEST/tsdb?sslmode=require""

# Restore the hypertable
# Iterate over the table names
for TABLE_NAME in "${TABLES[@]}"; do
    # Set the time column name based on the table
    if [ "$TABLE_NAME" = "book" ]; then
        TIME_COLUMN_NAME="receipt"
    else
        TIME_COLUMN_NAME="timestamp"
    fi

    # Form the SQL command
    SQL_COMMAND="SELECT create_hypertable('$TABLE_NAME', '$TIME_COLUMN_NAME', chunk_time_interval => INTERVAL '10 minutes');"

    # Execute the command
    PGPASSWORD=$TIMESCALEDBPASSWORD 
    execute_as_postgres "psql "postgres://$TSDBADMIN:$TIMESCALEDBPASSWORD@localhost:$PGPORT_DEST/$DATABASE?sslmode=require" -c "$SQL_COMMAND""
done

# Dump all plain tables and the TimescaleDB catalog from the source database

echo "Ensure that the correct TimescaleDB version is installed"
# Retrieve TimescaleDB extension version from source database
TIMESCALEDB_VERSION=$(execute_as_postgres "psql -t -A -d $SOURCE -c \"SELECT extversion FROM pg_extension WHERE extname = 'timescaledb';\"")
# Update TimescaleDB extension to the retrieved version in the target database
# execute_as_postgres "psql -d $TARGET -c \"ALTER EXTENSION timescaledb UPDATE TO '$TIMESCALEDB_VERSION';\""

# Loop through each table to export and then import data
for TABLE_NAME in "${TABLES[@]}"; do
    echo "Processing table: $TABLE_NAME"

    # Define file name
    FILE_NAME="${TABLE_NAME}.csv"

    # Export data from source table to CSV
    execute_as_postgres "psql -p $PGPORT_SRC -d $DB_NAME -c \"\copy (SELECT * FROM $TABLE_NAME) TO '$FILE_NAME' WITH (FORMAT CSV);\""

    # Import data from CSV into target table
    # Ensure no retention policy is in place for the table
    execute_as_postgres "psql -p $PGPORT_DEST -d $DB_NAME -c \"SELECT remove_retention_policy('$TABLE_NAME');\""
    # Now import the data
    execute_as_postgres "psql -p $PGPORT_DEST -d $DB_NAME -c \"\copy $TABLE_NAME FROM '$FILE_NAME' WITH (FORMAT CSV);\""

    # Cleanup: remove the CSV file from the remote host and local machine
    execute_as_postgres "rm ~/$FILE_NAME"
    rm $FILE_NAME
done

echo "Data migration completed."