#!/bin/bash
SERVER="timescaledb"
# List all failed backups for the server and delete them
failed_backups=$(sudo -i -u barman barman list-backup $SERVER | grep FAILED | awk '{print $2}')
for backup_id in $failed_backups; do
    echo "Deleting failed backup: $backup_id"
    barman delete $SERVER $backup_id
done
# Define local directory and S3 bucket path
local_directory=$(sudo -i -u barman barman show-server "$SERVER" | grep "basebackups_directory" | awk '{print $2}')
echo "$local_directory"
s3_bucket="s3://timescalebackups/$SERVER/base"

# Sync local directory to S3 bucket, including deletion of files not present locally
aws s3 sync "$local_directory" "$s3_bucket" --delete