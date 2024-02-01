#!/bin/bash

# AWS S3 Bucket Name
S3_BUCKET="s3://timescaledbinstance"
echo "RUN WITH SUDO!"
# Paths that were backed up (must match backup script)
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
    '/home/ubuntu/.p10k.zsh'
    '/home/ubuntu/.zprofile'
    '/home/ubuntu/.zshrc'
)

# Function to Fetch the Latest Backup Date from S3
get_latest_backup_date() {
    aws s3 ls "${S3_BUCKET}/" | sort | tail -n 1 | awk '{print $2}' | sed 's/\/$//'
}

# Function to Recover a File or Directory from S3
recover_from_s3() {
    local path=$1
    local latest_backup_date=$(get_latest_backup_date)
    local s3_path="${S3_BUCKET}/${latest_backup_date}${path}"
    echo "Recovering ${path} from ${s3_path}..."
    aws s3 cp "$s3_path" "$path" --recursive
}

# Main Recovery Process
LATEST_BACKUP_DATE=$(get_latest_backup_date)
echo "Recovering from the latest backup date: $LATEST_BACKUP_DATE"

for path in "${PATHS_TO_BACKUP[@]}"; do
    recover_from_s3 "$path"
done

echo "Recovery from S3 completed."
