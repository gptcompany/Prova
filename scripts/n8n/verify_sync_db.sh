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
# Function to verify data checksum for a single table, adjusted to your schema
verify_table_data_checksum() {
    local table=$1
    log_message "Verifying data checksum for table: $table"

    # Adjust checksum query based on actual columns
    local checksum_query=""
    case "$table" in
        "trades"|"liquidations")
            checksum_query="SELECT md5(array_agg(t::text)::text) FROM (SELECT * FROM $table ORDER BY exchange, symbol, timestamp, id) t;"
            ;;
        "book")
            checksum_query="SELECT md5(array_agg(t::text)::text) FROM (SELECT * FROM $table ORDER BY exchange, symbol, receipt, update_type) t;"
            ;;
        "open_interest"|"funding")
            checksum_query="SELECT md5(array_agg(t::text)::text) FROM (SELECT * FROM $table ORDER BY exchange, symbol, timestamp) t;"
            ;;
        *)
            log_message "Unknown table: $table. Skipping checksum verification."
            return
            ;;
    esac

    local checksum_source=$(execute_as_postgres "psql -p \"$PGPORT_SOURCE\" -d \"$DB_NAME_SOURCE\" -tAc \"$checksum_query\"")
    local checksum_target=$(execute_as_postgres "psql -p \"$PGPORT_TARGET\" -d \"$DB_NAME_TARGET\" -tAc \"$checksum_query\"")

    if [ "$checksum_source" = "$checksum_target" ]; then
        log_message "Data checksum verification successful for table: $table"
    else
        log_message "Data checksum verification failed for table: $table - Checksums do not match"
    fi
}

# Main execution loop
log_message "Starting data synchronization verification process..."
for table in "${TABLES[@]}"; do
    verify_table_data_checksum "$table"
done
log_message "Data synchronization verification process completed."
