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
    local recent_period='1 day' # Adjust this value based on your synchronization frequency
    log_message "Verifying recent data synchronization for table: $table"

    # Adjusted verification query to focus on recent records
    local verify_query="SELECT COUNT(*) FROM $table WHERE last_updated > now() - INTERVAL '$recent_period';"

    # Execute verification query on source and target databases
    local count_source=$(execute_as_postgres "psql -h $REMOTE_HOST -p $PGPORT_SOURCE -d $DB_NAME_SOURCE -tAc \"$verify_query\"")
    local count_target=$(execute_as_postgres "psql -h $REMOTE_HOST -p $PGPORT_TARGET -d $DB_NAME_TARGET -tAc \"$verify_query\"")

    # Log the counts for review
    log_message "Recent count in source ($DB_NAME_SOURCE): $count_source"
    log_message "Recent count in target ($DB_NAME_TARGET): $count_target"

    # Compare counts for recent data
    if [ "$count_source" -eq "$count_target" ]; then
        log_message "Recent data verification successful for table: $table"
    else
        log_message "Recent data verification failed for table: $table - Source: $count_source, Target: $count_target"
    fi
}


# Function to verify data checksum for a single table
verify_table_data_checksum() {
    local table=$1
    log_message "Verifying data checksum for table: $table"

    # Checksum query
    local checksum_query="SELECT md5(array_agg(t::text)::text) FROM (SELECT * FROM $table ORDER BY primary_key_column) t;"

    local checksum_source=$(execute_as_postgres "psql -h $REMOTE_HOST -p $PGPORT_SOURCE -d $DB_NAME_SOURCE -tAc \"$checksum_query\"")
    local checksum_target=$(execute_as_postgres "psql -h $REMOTE_HOST -p $PGPORT_TARGET -d $DB_NAME_TARGET -tAc \"$checksum_query\"")

    if [ "$checksum_source" = "$checksum_target" ]; then
        log_message "Data checksum verification successful for table: $table"
    else
        log_message "Data checksum verification failed for table: $table - Checksums do not match"
    fi
}

# Main execution loop
log_message "Starting data synchronization verification process..."
for table in "${TABLES[@]}"; do
    verify_table_data "$table"
    verify_table_data_checksum "$table"
done
log_message "Data synchronization verification process completed."
