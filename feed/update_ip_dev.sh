
#!/bin/bash
#sudo chmod +x /home/ec2-user/statarb/feed/update_ip_dev.sh
DB_NAME="db0"
PGUSER="postgres"
PGHOST="localhost"
PGPORT="5432"
PGPASSWORD=$(python3 -c "import yaml; print(yaml.safe_load(open('/config_cf.yaml'))['timescaledb_password'])")

# Logging settings
HOME="/home/ec2-user"
LOG_FILE="$HOME/ts_backups.log"
export PGUSER PGHOST PGPORT PGPASSWORD
IP_FILE="ip_development.txt"
S3_BUCKET="s3://timescalebackups"
PGDATA="/var/lib/pgsql/data/"
# Function to log messages
exec 3>>$LOG_FILE
# Function to log messages and command output to the log file
log_message() {
    local message="$(date +"%Y-%m-%d %T"): $1"
    printf "%-100s\n" "$message" >&3  # Log to the log file via fd3
    printf "%-100s\n" "$message" >&2  # Display on the screen (stderr)

    if [ -n "$2" ]; then
        printf "%-100s\n" "$2" >&3   # Log stdout to the log file via fd3
        printf "%-100s\n" "$2" >&2   # Display stdout on the screen (stderr)
    fi
    if [ -n "$3" ]; then
        printf "%-100s\n" "$3" >&3   # Log stderr to the log file via fd3
        printf "%-100s\n" "$3" >&2   # Display stderr on the screen (stderr)
    fi
}


# Improved error handling within functions
handle_error() {
    local error_message=$1
    log_message "Error: $error_message"
    # Exit the script or perform any necessary cleanup
    exit 1
}

update_pg_hba_for_replication() {
    # AWS S3 Bucket where ip_development.txt is stored
    local s3_bucket=$S3_BUCKET
    local ip_file=$IP_FILE
    local temp_ip_file="/tmp/$ip_file"
    local pg_hba_file="$PGDATA/pg_hba.conf"

    # Download the file from S3
    if aws s3 cp "$s3_bucket/$ip_file" "$temp_ip_file"; then
        log_message "Downloaded $ip_file from S3 bucket."
    else
        handle_error "Failed to download $ip_file from S3 bucket."
    fi

    # Parse the IP address
    if [ -f "$temp_ip_file" ]; then
        local dev_ip=$(cat "$temp_ip_file")
        log_message "Development IP: $dev_ip"
    else
        handle_error "IP file does not exist: $temp_ip_file"
    fi

    # Check and update pg_hba.conf directly on the host
    if grep -q "host all all $dev_ip/32 scram-sha-256" "$pg_hba_file"; then
        log_message "pg_hba.conf already contains an entry for $dev_ip."
        return 0
    else
        echo "host all all $dev_ip/32 scram-sha-256" >> "$pg_hba_file"
        log_message "Updated pg_hba.conf with replication entry for $dev_ip."
        # Reload or restart PostgreSQL configuration
        if ! sudo systemctl restart postgresql; then
            log_message "Failed to restart PostgreSQL service."
            exit 1
        else
            log_message "PostgreSQL service restarted successfully."
        fi
    fi
}

# Call the function to update pg_hba.conf
update_pg_hba_for_replication

57.181.106.64

echo 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCQt84uISxflQO5/wgHA363taxD1I7KTJlcCWpXbBoEen3dKG+iwxp7ldmChufqB03wj7Na+BajCmTtfToDL2HLBksv6q2JbHKrgLFhslBGdMaWl+iXwXhioZhyLd0fMYjEa9sJ1RKOs3GBuqhCAoqvOwf9De8LBghtLMpjlUTycNYN/lauQWUhVOpJjpPIqEPaJYbuc/jD8nL8DjIKdasYvU4yMsEeA0zMm0BelAS8RPvWfXOUdMN1ugBwmCuhir/Yj9dgxrrNkWHvQBlTc9HtryP2pcniw2S5z0r690g0p1JxDov6clLHLYbhWgck1P2zeeFjKXTOJR78eqNC4Q75' >> ~/.ssh/authorized_keys

ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCQt84uISxflQO5/wgHA363taxD1I7KTJlcCWpXbBoEen3dKG+iwxp7ldmChufqB03wj7Na+BajCmTtfToDL2HLBksv6q2JbHKrgLFhslBGdMaWl+iXwXhioZhyLd0fMYjEa9sJ1RKOs3GBuqhCAoqvOwf9De8LBghtLMpjlUTycNYN/lauQWUhVOpJjpPIqEPaJYbuc/jD8nL8DjIKdasYvU4yMsEeA0zMm0BelAS8RPvWfXOUdMN1ugBwmCuhir/Yj9dgxrrNkWHvQBlTc9HtryP2pcniw2S5z0r690g0p1JxDov6clLHLYbhWgck1P2zeeFjKXTOJR78eqNC4Q75