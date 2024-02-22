#!/bin/bash

# Configuration
REMOTE_HOST=$(aws ssm get-parameter --name STANDBY_PUBLIC_IP --with-decryption --query 'Parameter.Value' --output text)
DB_NAME_SOURCE="db0"
DB_NAME_TARGET="db0"
PGPORT_SOURCE="5432"
PGPORT_TARGET="5433"
TABLES=("trades" "book" "open_interest" "funding" "liquidations")
LOG_FILE="/tmp/data_sync_verification.log"

# Function to log messages
log_message() {
    echo "$(date +"%Y-%m-%d %T") - $1" | tee -a "$LOG_FILE"
}

# Function to dynamically determine the timestamp range for verification based on the latest recovery operation
get_verification_timestamp_range() {
    # Placeholder for fetching the last recovery timestamp; adjust as needed
    # This could be replaced with a command to fetch this timestamp from recovery logs or metadata
    echo "now() - interval '1 day'"
}
# Execute a command as postgres user on the remote host
execute_as_postgres() {
    ssh -T postgres@$REMOTE_HOST "$1"
}

# Function to verify data synchronization for a single table
# Function to verify data synchronization for a single table
verify_table_data_synchronization() {
    local table=$1
    local timestamp_range=$(get_verification_timestamp_range)
    log_message "Verifying data synchronization for table: $table within $timestamp_range"

    # Construct verification queries
    local verify_query_count="SELECT COUNT(*) FROM $table WHERE timestamp >= $timestamp_range;"
    local verify_query_checksum="SELECT md5(array_agg(t::text)::text) FROM (SELECT * FROM $table WHERE timestamp >= $timestamp_range ORDER BY timestamp) t;"

    # Execute verification queries on source and target databases
    local count_source=$(execute_as_postgres "psql -p "$PGPORT_SOURCE" -d "$DB_NAME_SOURCE" -tAc "$verify_query_count"")
    local count_target=$(execute_as_postgres "psql -p "$PGPORT_TARGET" -d "$DB_NAME_TARGET" -tAc "$verify_query_count"")
    local checksum_source=$(execute_as_postgres "psql -p "$PGPORT_SOURCE" -d "$DB_NAME_SOURCE" -tAc "$verify_query_checksum"")
    local checksum_target=$(execute_as_postgres "psql -p "$PGPORT_TARGET" -d "$DB_NAME_TARGET" -tAc "$verify_query_checksum"")

    # Log the results for review
    log_message "Source count: $count_source, Target count: $count_target"
    log_message "Source checksum: $checksum_source, Target checksum: $checksum_target"

    # Compare counts and checksums for the specified range
    if [[ "$count_source" -eq "$count_target" && "$checksum_source" == "$checksum_target" ]]; then
        log_message "Verification successful for table: $table"
    else
        log_message "Verification failed for table: $table - Counts or checksums do not match"
    fi
}

# Main execution loop
log_message "Starting data synchronization verification process..."
for table in "${TABLES[@]}"; do
    verify_table_data_synchronization "$table"
done
log_message "Data synchronization verification process completed."
