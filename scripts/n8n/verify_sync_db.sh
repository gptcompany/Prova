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

# Execute a command as postgres user on the remote host
# Execute a command as postgres user on the remote host
execute_as_postgres() {
    ssh -T postgres@$REMOTE_HOST "$1"
}

# Function to verify data synchronization for a single table
verify_table_data() {
    local table=$1
    log_message "Verifying data for table: $table"

    # Verification query for record count
    local verify_query_count="SELECT COUNT(*) FROM $table;"

    # Verification query for data checksum, adjusted for each table's unique identifiers
    local verify_query_checksum=""
    case $table in
        trades)
            verify_query_checksum="SELECT md5(array_agg(t::text)::text) FROM (SELECT * FROM $table ORDER BY exchange, symbol, timestamp, id) t;"
            ;;
        book)
            verify_query_checksum="SELECT md5(array_agg(t::text)::text) FROM (SELECT * FROM $table ORDER BY exchange, symbol, receipt, update_type) t;"
            ;;
        open_interest)
            verify_query_checksum="SELECT md5(array_agg(t::text)::text) FROM (SELECT * FROM $table ORDER BY exchange, symbol, timestamp) t;"
            ;;
        funding)
            verify_query_checksum="SELECT md5(array_agg(t::text)::text) FROM (SELECT * FROM $table ORDER BY exchange, symbol, timestamp) t;"
            ;;
        liquidations)
            verify_query_checksum="SELECT md5(array_agg(t::text)::text) FROM (SELECT * FROM $table ORDER BY exchange, symbol, timestamp, id) t;"
            ;;
        *)
            log_message "Unknown table: $table. Skipping checksum verification."
            return
            ;;
    esac

    # Execute verification queries on source and target databases
    local count_source=$(execute_as_postgres "psql -p "$PGPORT_SOURCE" -d "$DB_NAME_SOURCE" -tAc "$verify_query_count"")
    local count_target=$(execute_as_postgres "psql -p "$PGPORT_TARGET" -d "$DB_NAME_TARGET" -tAc "$verify_query_count"")

    local checksum_source=$(execute_as_postgres "psql -p "$PGPORT_SOURCE" -d "$DB_NAME_SOURCE" -tAc "$verify_query_checksum"")
    local checksum_target=$(execute_as_postgres "psql -p "$PGPORT_TARGET" -d "$DB_NAME_TARGET" -tAc "$verify_query_checksum"")

    # Log the results for review
    log_message "Count in source ($DB_NAME_SOURCE): $count_source"
    log_message "Count in target ($DB_NAME_TARGET): $count_target"
    log_message "Checksum in source ($DB_NAME_SOURCE): $checksum_source"
    log_message "Checksum in target ($DB_NAME_TARGET): $checksum_target"

    # Compare counts and checksums
    if [ "$count_source" -eq "$count_target" ] && [ "$checksum_source" = "$checksum_target" ]; then
        log_message "Verification successful for table: $table"
    else
        log_message "Verification failed for table: $table - Counts or checksums do not match"
    fi
}

# Main execution loop
log_message "Starting data synchronization verification process..."
for table in "${TABLES[@]}"; do
    verify_table_data "$table"
done
log_message "Data synchronization verification process completed."
