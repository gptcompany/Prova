#!/bin/bash

# Configuration
REMOTE_HOST=$(aws ssm get-parameter --name STANDBY_PUBLIC_IP --with-decryption --query 'Parameter.Value' --output text)
DB_NAME_SOURCE="db0"
DB_NAME_TARGET="db0"
PGPORT_SOURCE="5432"
PGPORT_TARGET="5433"
TABLES=("trades" "book" "open_interest" "funding" "liquidations")
LOG_FILE="/tmp/data_sync_verification.log"
TIMESCALEDBPASSWORD=$(aws ssm get-parameter --name timescaledbpassword --with-decryption --query 'Parameter.Value' --output text)
SOURCE=postgres://postgres:$TIMESCALEDBPASSWORD@localhost:$PGPORT_SOURCE/$DB_NAME_SOURCE
TARGET=postgres://postgres:$TIMESCALEDBPASSWORD@localhost:$PGPORT_TARGET/$DB_NAME_TARGET
# Calculate a fixed timestamp for verification
FIXED_TIMESTAMP=$(date +"%Y-%m-%d %T") # or use another method to get the exact timestamp you need

# Function to log messages
log_message() {
    echo "$(date +"%Y-%m-%d %T") - $1" | tee -a "$LOG_FILE"
}

# Execute a command as postgres user on the remote host
execute_as_postgres() {
    psql -h "$REMOTE_HOST" -p "$1" -d "$2" -U postgres -tAc "$3"
}

# Function to verify data synchronization for a single table
verify_table_data_synchronization() {
    local table=$1
    local fixed_timestamp=$2  # Added fixed timestamp as a parameter
    local timestamp_column="timestamp"  # Default timestamp column
    if [ "$table" == "book" ]; then
        timestamp_column="receipt"  # Adjust based on actual schema
    fi
    log_message "Verifying data synchronization for table: $table using $timestamp_column column with fixed timestamp: $fixed_timestamp"

    local verify_query_count="SELECT COUNT(*) FROM $table WHERE \"$timestamp_column\" >= TIMESTAMP '$fixed_timestamp' - interval '1 day';"
    local verify_query_checksum="SELECT md5(array_agg(t::text)::text) FROM (SELECT * FROM $table WHERE \"$timestamp_column\" >= TIMESTAMP '$fixed_timestamp' - interval '1 day' ORDER BY \"$timestamp_column\") t;"

    # Execute verification queries
    local count_source=$(execute_as_postgres "$PGPORT_SOURCE" "$DB_NAME_SOURCE" "$verify_query_count")
    local count_target=$(execute_as_postgres "$PGPORT_TARGET" "$DB_NAME_TARGET" "$verify_query_count")
    local checksum_source=$(execute_as_postgres "$PGPORT_SOURCE" "$DB_NAME_SOURCE" "$verify_query_checksum")
    local checksum_target=$(execute_as_postgres "$PGPORT_TARGET" "$DB_NAME_TARGET" "$verify_query_checksum")

    # Log the results
    log_message "Source count: $count_source, Target count: $count_target"
    log_message "Source checksum: $checksum_source, Target checksum: $checksum_target"

    # Compare counts and checksums
    if [[ "$count_source" -eq "$count_target" && "$checksum_source" == "$checksum_target" ]]; then
        log_message "Verification successful for table: $table"
    else
        log_message "Verification failed for table: $table - Counts or checksums do not match"
    fi
}
# Function to run ANALYZE on a database
run_analyze() {
    local db_connection_string=$1
    log_message "Running ANALYZE on database: $db_connection_string"
    psql "$db_connection_string" -c "ANALYZE;"
}
# Main execution loop
log_message "Starting data synchronization verification process..."
# Run ANALYZE on both databases
run_analyze "$TARGET"
run_analyze "$SOURCE"
for table in "${TABLES[@]}"; do
    verify_table_data_synchronization "$table" "$FIXED_TIMESTAMP"
done
log_message "Data synchronization verification process completed."
