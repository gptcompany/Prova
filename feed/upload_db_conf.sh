#!/bin/bash
#chmod +x upload_db_conf.sh

CONTAINER_NAME="timescaledb"
# AWS S3 settings
S3_BUCKET_PATH="s3://timescalebackups/backup-folder/"
# Function to log messages
log_message() {
    echo "$(date +"%Y-%m-%d %T"): $1" >&2 
}
# Improved error handling within functions
handle_error() {
    local error_message=$1
    log_message "Error: $error_message"
    # Exit the script or perform any necessary cleanup
    exit 1
}
# Function to backup necessary PostgreSQL configuration files and upload to S3
backup_and_upload_to_s3() {
    local container_name=$1
    local backup_path="/pg_conf_backup"
    local s3_bucket_path=$2
    
    # Create a backup directory
    mkdir -p $backup_path

    # Backup configuration files and WAL directory
    # Stop PG
    docker stop $container_name

    # Wait for a moment to ensure all processes are ceased
    sleep 7

    # Copy 
    docker cp $container_name:/var/lib/postgresql/data/postgresql.conf $backup_path
    docker cp $container_name:/var/lib/postgresql/data/pg_hba.conf $backup_path
    docker cp $container_name:/var/lib/postgresql/data/pg_wal $backup_path

    # Compress the backup
    tar -czf $backup_path/postgres_config_backup.tar.gz -C $backup_path .

    # Construct S3 upload path
    local s3_upload_path="${s3_bucket_path}postgres_config_backup.tar.gz"

    # Upload to S3
    if aws s3 cp $backup_path/postgres_config_backup.tar.gz $s3_upload_path; then
        log_message "Backup successfully uploaded to S3"
    else
        handle_error "Failed to upload backup to S3"
    fi

    # Clean up local backup files
    rm -rf $backup_path
    # Restart PostgreSQL server
    docker start $container_name 

    log_message "PostgreSQL server restarted"
}

backup_and_upload_to_s3 $CONTAINER_NAME $S3_BUCKET_PATH
