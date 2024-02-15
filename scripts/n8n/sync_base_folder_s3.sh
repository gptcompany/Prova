#!/bin/bash
SERVER="timescaledb"
# List all failed backups for the server and delete them
failed_backups=$(sudo -i -u barman barman list-backup $SERVER | grep FAILED | awk '{print $2}')
# Check if there are any failed backups
if [ -z "$failed_backups" ]; then
    echo "No failed backups."
else
    echo "Failed backups: $failed_backups"
    for backup_id in $failed_backups; do
        echo "Deleting failed backup: $backup_id"
        sudo -i -u barman barman delete $SERVER $backup_id
    done
fi
# Define local directory and S3 bucket path
local_directory=$(sudo -i -u barman barman show-server "$SERVER" | grep "basebackups_directory" | awk '{print $2}')
echo "Local directory: $local_directory"
s3_bucket="s3://timescalebackups/$SERVER/base"

# Sync local directory to S3 bucket, including deletion of files not present locally
aws s3 sync "$local_directory" "$s3_bucket" --delete