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
    psql -h "$REMOTE_HOST" -p "$1" -d "$2" -U postgres -tAc "$3"
}

# Function to verify data synchronization for a single table
verify_table_data_synchronization() {
    local table=$1
    local timestamp_column="timestamp"  # Default timestamp column
    if [ "$table" == "book" ]; then
        timestamp_column="receipt"  # Adjust based on actual schema
    fi
    log_message "Verifying data synchronization for table: $table within the last day using $timestamp_column column"

    local verify_query_count="SELECT COUNT(*) FROM $table WHERE \"$timestamp_column\" >= now() - interval '1 day';"
    local verify_query_checksum="SELECT md5(array_agg(t::text)::text) FROM (SELECT * FROM $table WHERE \"$timestamp_column\" >= now() - interval '1 day' ORDER BY \"$timestamp_column\") t;"

    # Execute verification queries (example for count, adjust similarly for checksum)
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

# Main execution loop
log_message "Starting data synchronization verification process..."
for table in "${TABLES[@]}"; do
    verify_table_data_synchronization "$table"
done
log_message "Data synchronization verification process completed."
