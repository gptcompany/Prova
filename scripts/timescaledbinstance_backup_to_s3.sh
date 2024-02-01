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
S3_BUCKET="s3://timescaledbinstance"

# Current Date
DATE=$(date +%F)
log_message "RUN WITH SUDO!"
# Paths that were backed up (must match recover script)
declare -a PATHS_TO_BACKUP=(
    '/var/lib/redis/server.key'
    '/var/lib/redis/server.crt'
    '/var/lib/redis/ca.crt'
    '/etc/redis/redis.conf'
    '/etc/postgresql/15/main/postgresql.conf'
    '/etc/postgresql/15/main/pg_hba.conf'
    '/etc/ssh/sshd_config'
    '/home/ubuntu/.ssh'
    '/home/postgres/.ssh'
    '/home/ubuntu/.p10k.zsh'
    '/home/ubuntu/.zprofile'
    '/home/ubuntu/.zshrc'
    
)

# Function to Upload a File or Directory to S3
upload_to_s3() {
    local path=$1
    local s3_path="${S3_BUCKET}/${DATE}${path}"
    log_message "Uploading ${path} to ${s3_path}..."
    if [ -d "$path" ]; then
        # It's a directory
        log_message "Uploading directory ${path} to ${s3_path}..."
        aws s3 cp "$path" "$s3_path" --recursive
    elif [ -f "$path" ]; then
        # It's a file
        log_message "Uploading file ${path} to ${s3_path}..."
        aws s3 cp "$path" "$s3_path"
    else
        log_message "Warning: Path not found or not a regular file/directory - $path"
    fi

}

# Main Backup Process
for path in "${PATHS_TO_BACKUP[@]}"; do
    if [ -e "$path" ]; then
        upload_to_s3 "$path"
    else
        log_message "Warning: Path not found - $path"
    fi
done

log_message "Backup to S3 completed."