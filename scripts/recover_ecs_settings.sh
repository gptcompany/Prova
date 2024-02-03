#!/bin/bash

# Define the S3 bucket name
S3_BUCKET="s3://ultimaec2"

# Function to fetch the latest backup date from S3
get_latest_backup_date() {
    aws s3 ls "${S3_BUCKET}/" | sort | tail -n 1 | awk '{print $2}' | sed 's/\/$//'
}

# Function to recover all files from the latest backup on S3
recover_all_from_s3() {
    local latest_backup_date=$(get_latest_backup_date)
    local s3_backup_path="${S3_BUCKET}/${latest_backup_date}"

    # List all objects in the latest backup
    local objects=$(aws s3 ls "${s3_backup_path}" --recursive | awk '{print $4}')

    # Iterate over each object to recover
    for object in $objects; do
        local object_path="${object#${latest_backup_date}/}"  # Remove the date from the object path
        local target_path="/${object_path}"  # Construct the absolute target path

        # Prompt for confirmation before copying the file
        read -p "Recover ${target_path} from ${S3_BUCKET}/${object}? (Y/N): " choice
        if [[ $choice =~ ^[Yy]$ ]]; then
            echo "Recovering ${target_path} from ${S3_BUCKET}/${object}..."
            # Copy the file to the target path
            sudo aws s3 cp "${S3_BUCKET}/${object}" "${target_path}"
        else
            echo "Skipping ${target_path}."
        fi
    done
}

# Main recovery process
echo "Recovering from the latest backup date: $(get_latest_backup_date)"
recover_all_from_s3
echo "Recovery from S3 completed."
