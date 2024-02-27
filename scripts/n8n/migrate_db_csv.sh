#!/bin/bash
# Redirect stdout and stderr to a log file and also echo it
exec > >(tee -a ~/migrate_db.log) 2>&1

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
SEGMENTBY_COLUMN="exchange"
# Execute a command as postgres user on the remote host
execute_as_postgres() {
    ssh -T postgres@$REMOTE_HOST "PGPASSWORD='$TIMESCALEDBPASSWORD' $1"
}

# Function to retry a command multiple times
retry_command() {
    local command=$1
    local attempts=0
    local max_attempts=1
    local sleep_seconds=3
    local success=0

    while [ $attempts -lt $max_attempts ]; do
        attempts=$((attempts+1))
        echo "Attempt $attempts"
        
        if output=$(execute_as_postgres "$command" 2>&1); then
            echo "Command succeeded [OKAY]."
            success=1
            break
        else
            error_message=$output
            echo "Command failed [KO]. " #Error: $error_message"
            if [ $attempts -lt $max_attempts ]; then
                echo "Retrying in $sleep_seconds seconds..."
                # execute_as_postgres "sudo systemctl restart postgresql"
                sleep $sleep_seconds
            else
                # echo "Reached maximum attempts. Not retrying."
            fi
        fi
    done
    
    # if [ $success -eq 0 ]; then
    #     echo "The command has failed after $max_attempts attempts."
    # fi

    return $success
}
echo "Identifying and removing existing retention policies in the source DB"
for TABLE_NAME in "${TABLES[@]}"; do
    echo "Processing retention policy for table: $TABLE_NAME"
    
    # Identify existing retention policies for the table
    echo "Identifying existing retention policies for $TABLE_NAME"
    retry_command "psql -p $PGPORT_SRC -d $DB_NAME -c \"SELECT * FROM timescaledb_information.jobs WHERE proc_name = 'policy_retention' AND hypertable_name = '$TABLE_NAME';\""
    
    # Remove the retention policy if exists
    echo "Removing retention policy for $TABLE_NAME if exists"
    retry_command "psql -p $PGPORT_SRC -d $DB_NAME -c \"SELECT remove_retention_policy('$TABLE_NAME', if_exists => TRUE);\""
done

# Dump and restore schema
echo "Dumping the database roles from the source database"
retry_command "pg_dumpall -p $PGPORT_SRC -d '$SOURCE' -l '$DB_NAME' --quote-all-identifiers --roles-only --file=roles.sql"

echo "Migrating schema pre-data"
retry_command "PGPASSWORD='$TIMESCALEDBPASSWORD' pg_dump -U postgres -h localhost -p $PGPORT_SRC -Fc -v --section=pre-data --exclude-schema='_timescaledb*' -f dump_pre_data.dump $DB_NAME"

echo "Restoring the dump pre-data"
retry_command "PGPASSWORD='$TIMESCALEDBPASSWORD' pg_restore -U postgres -h localhost -p $PGPORT_DEST --no-owner -Fc -v -d $DB_NAME dump_pre_data.dump"

# Convert tables to hypertables in target db
for TABLE_NAME in "${TABLES[@]}"; do
    echo "Processing table: $TABLE_NAME"
    
    # Define time column name based on the table
    TIME_COLUMN_NAME="timestamp"
    if [ "$TABLE_NAME" = "book" ]; then
        TIME_COLUMN_NAME="receipt"
    fi
    
    # Check if the table exists before converting to hypertable
    echo "Checking if $TABLE_NAME exists"
    retry_command "psql -p $PGPORT_DEST -d $DB_NAME -c \"SELECT to_regclass('public.$TABLE_NAME');\""

    # Convert table to hypertable
    echo "Converting $TABLE_NAME to hypertable"
    retry_command "psql -p $PGPORT_DEST -d $DB_NAME -c \"SELECT create_hypertable('$TABLE_NAME', '$TIME_COLUMN_NAME', if_not_exists => TRUE, chunk_time_interval => INTERVAL '10 minutes');\""
done

# Data export, import, and ensure compression
echo "Looping through each table to export, import data"
for TABLE_NAME in "${TABLES[@]}"; do
    FILE_NAME="${TABLE_NAME}.csv"
    # Export data from source table to CSV
    # execute_as_postgres "psql -d $DB_NAME -c \"\copy (SELECT * FROM $TABLE_NAME) TO '$FILE_NAME' WITH (FORMAT CSV);\""
    psql_copy_cmd1="psql -p $PGPORT_SRC -d $DB_NAME -c \"\copy (SELECT * FROM $TABLE_NAME) TO '/var/lib/postgresql/$FILE_NAME' WITH (FORMAT CSV);\""
    retry_command "$psql_copy_cmd1"
    # Check and remove retention policy if it exists
    echo "Checking and removing retention policy for $TABLE_NAME if exists..."
    remove_policy_cmd="psql -p $PGPORT_DEST -d $DB_NAME -c \"SELECT remove_retention_policy('public.$TABLE_NAME', if_exists => TRUE);\""
    retry_command "$remove_policy_cmd"

    # Import data from CSV into target table
    echo "Importing data into $TABLE_NAME"
    # execute_as_postgres "psql -d $DB_NAME -c \"\copy $TABLE_NAME FROM '$FILE_NAME' WITH (FORMAT CSV);\""
    # Create temporary table
    # Insert data from temporary table into target table, skipping duplicates
    psql_copy_cmd="psql -p $PGPORT_DEST -d $DB_NAME -c \"
    BEGIN;
    CREATE TEMP TABLE temp_$TABLE_NAME AS TABLE $TABLE_NAME WITH NO DATA;
    COPY temp_$TABLE_NAME FROM '/var/lib/postgresql/$FILE_NAME' WITH (FORMAT CSV);
    INSERT INTO $TABLE_NAME SELECT * FROM temp_$TABLE_NAME ON CONFLICT DO NOTHING;
    DROP TABLE temp_$TABLE_NAME;
    COMMIT;
    \""
    
    # Call retry_command function with the constructed psql copy command
    retry_command "$psql_copy_cmd"

    echo "Cleanup: remove the CSV file"
    retry_command "rm /var/lib/postgresql/$FILE_NAME"
done
#Migrate schema post-data
echo "Dump the schema post-data from your source database"
retry_command "PGPASSWORD='$TIMESCALEDBPASSWORD' pg_dump -U postgres -h localhost -p $PGPORT_SRC -Fc -v --section=post-data --exclude-schema='_timescaledb*' -f dump_post_data.dump $DB_NAME"

echo "Restoring the dump post-data"
retry_command "PGPASSWORD='$TIMESCALEDBPASSWORD' pg_restore -U postgres -h localhost -p $PGPORT_DEST --no-owner -Fc -v -d $DB_NAME dump_post_data.dump"

echo "Data migration completed."






