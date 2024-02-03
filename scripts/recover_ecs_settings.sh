#!/bin/bash

# AWS S3 Bucket Name
S3_BUCKET=$1

# Function to Fetch the Latest Backup Date from S3
get_latest_backup_date() {
    aws s3 ls "${S3_BUCKET}/" | sort | tail -n 1 | awk '{print $2}' | sed 's/\/$//'
}

# Function to Recover all Files from the Latest Backup on S3
recover_all_from_s3() {
    local latest_backup_date=$(get_latest_backup_date)
    local s3_backup_path="${S3_BUCKET}/${latest_backup_date}"

    # List all objects in the latest backup and download each
    aws s3 ls "${s3_backup_path}" --recursive | awk '{print $4}' | while read -r object; do
        local local_path="/${object#${latest_backup_date}/}"  # Strip the date prefix from S3 object path
        local dir_path=$(dirname "${local_path}")
        mkdir -p "${dir_path}"  # Create the directory structure if it doesn't exist
        echo "Recovering ${local_path} from ${s3_backup_path}/${object}..."
        aws s3 cp "${s3_backup_path}/${object}" "${local_path}"
    done
}

# Main Recovery Process
echo "Recovering from the latest backup date: $(get_latest_backup_date)"
recover_all_from_s3
echo "Recovery from S3 completed."
