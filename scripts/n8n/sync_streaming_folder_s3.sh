#!/bin/bash
SERVER="timescaledb"
# Define local directory and S3 bucket path
local_directory=$(sudo -i -u barman barman show-server "$SERVER" | grep "basebackups_directory" | awk '{print $2}')
echo "$local_directory"
s3_bucket="s3://timescalebackups/$SERVER/streaming"

# Sync local directory to S3 bucket, including deletion of files not present locally
aws s3 sync "$local_directory" "$s3_bucket" --delete