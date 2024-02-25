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

# Function to execute a command as postgres user on the remote host
execute_as_postgres() {
    ssh -T postgres@$REMOTE_HOST "PGPASSWORD='$TIMESCALEDBPASSWORD' $1"
}

# Function to check if a table exists and then convert it to a hypertable
check_and_create_hypertable() {
    local table_name=$1
    local time_column_name=$2

    # Check if the table exists
    local check_exists_cmd="psql -p $PGPORT_DEST -d $DB_NAME -c \"SELECT to_regclass('public.$table_name');\""
    local table_exists=$(execute_as_postgres "$check_exists_cmd" | grep -v to_regclass | grep -v row | grep -v -- '---' | grep -v '(' | tr -d '[:space:]')

    # If the table exists, convert it to a hypertable
    if [ "$table_exists" = "public.$table_name" ]; then
        echo "Table $table_name exists. Converting to hypertable..."
        local hypertable_cmd="psql -p $PGPORT_DEST -d $DB_NAME -c \"SELECT create_hypertable('$table_name', '$time_column_name', if_not_exists => TRUE, chunk_time_interval => INTERVAL '10 minutes');\""
        execute_as_postgres "$hypertable_cmd"
    else
        echo "Table $table_name does not exist. Skipping hypertable conversion."
    fi
}

# Function to remove retention policy if it exists
remove_retention_policy_if_exists() {
    local table_name=$1
    echo "Checking and removing retention policy for $table_name if exists..."
    local remove_policy_cmd="psql -p $PGPORT_DEST -d $DB_NAME -c \"SELECT remove_retention_policy('public.$table_name', if_exists => TRUE);\""
    execute_as_postgres "$remove_policy_cmd"
}

echo "Dump the database roles from the source database"
execute_as_postgres 'pg_dumpall -d "'"$SOURCE"'" -l '"$DB_NAME"' --quote-all-identifiers --roles-only --file=roles.sql'

echo "Migrating schema pre-data"
execute_as_postgres "PGPASSWORD='$TIMESCALEDBPASSWORD' pg_dump -U postgres -h localhost -p $PGPORT_SRC -Fc -v --section=pre-data --exclude-schema='_timescaledb*' -f dump_pre_data.dump $DB_NAME"
echo "Restoring the dump pre data"
execute_as_postgres "PGPASSWORD='$TIMESCALEDBPASSWORD' pg_restore -U postgres -h localhost -p $PGPORT_DEST --no-owner -Fc -v -d $DB_NAME dump_pre_data.dump"

# Loop through each table to convert to hypertable and handle retention policy
for TABLE_NAME in "${TABLES[@]}"; do
    # Determine the correct time column name
    TIME_COLUMN_NAME="timestamp"
    if [ "$TABLE_NAME" = "book" ]; then
        TIME_COLUMN_NAME="receipt"
    fi

    # Check if the table exists and convert it to a hypertable
    check_and_create_hypertable "$TABLE_NAME" "$TIME_COLUMN_NAME"
    # Remove retention policy if it exists
    remove_retention_policy_if_exists "$TABLE_NAME"
done

echo "Data migration completed."
