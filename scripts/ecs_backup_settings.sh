#!/bin/bash
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

# AWS S3 Bucket Name
S3_BUCKET="s3://ultimaec2"

# Current Date
DATE=$(date +%F)

# Files and Directories to Backup
declare -a PATHS_TO_BACKUP=(
    '/home/ec2-user/config_cf.yaml'
    '/home/ec2-user/.ssh'
    '/etc/ssh/sshd_config'
    '/home/ec2-user/.zshrc'
    '/home/ec2-user/.p10k.zsh'
    '/home/ec2-user/.zprofile'

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