#!/bin/bash

# AWS S3 Bucket Name
S3_BUCKET="s3://timescaledb"

# Current Date
DATE=$(date +%F)

# Files and Directories to Backup
declare -a PATHS_TO_BACKUP=(
    '/var/lib/redis/server.key'
    '/var/lib/redis/server.crt'
    '/var/lib/redis/ca.crt'
    '/etc/redis/redis.conf'
    '/etc/postgresql/15/main/postgresql.conf'
    '/etc/postgresql/15/main/pg_hba.conf'
    '/home/ubuntu/.ssh'
    '/home/postgres/.ssh'
    '/etc/ssh/sshd_config'
)

# Function to Upload a File or Directory to S3
upload_to_s3() {
    local path=$1
    local s3_path="${S3_BUCKET}/${DATE}${path}"
    echo "Uploading ${path} to ${s3_path}..."
    if [ -d "$path" ]; then
        # It's a directory
        echo "Uploading directory ${path} to ${s3_path}..."
        aws s3 cp "$path" "$s3_path" --recursive
    elif [ -f "$path" ]; then
        # It's a file
        echo "Uploading file ${path} to ${s3_path}..."
        aws s3 cp "$path" "$s3_path"
    else
        echo "Warning: Path not found or not a regular file/directory - $path"
    fi

}

# Main Backup Process
for path in "${PATHS_TO_BACKUP[@]}"; do
    if [ -e "$path" ]; then
        upload_to_s3 "$path"
    else
        echo "Warning: Path not found - $path"
    fi
done

echo "Backup to S3 completed."