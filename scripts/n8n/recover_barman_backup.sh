#!/bin/bash

# Define server identifier and remote PostgreSQL instance
SERVER_ID="timescaledb"
REMOTE_HOST="timescaledb.mywire.org"
#REMOTE_PGDATA_PATH="/var/lib/postgresql/15/main" # Update with actual data directory path on the remote host
REMOTE_PGDATA_PATH=$(ssh postgres@$REMOTE_HOST "psql -t -c 'SHOW data_directory;'")
echo "Remote PostgreSQL data directory: $REMOTE_PGDATA_PATH"
# Get the latest backup ID for the server
LATEST_BACKUP_ID=$(sudo -i -u barman barman list-backup $SERVER_ID | head -n 1 | awk '{print $2}')
sudo -i -u barman barman list-backup $SERVER_ID
echo "Latest backup : $LATEST_BACKUP_ID"
# Check if a backup ID was found
if [ -z "$LATEST_BACKUP_ID" ]; then
    echo "No backup found for server $SERVER_ID"
    exit 1
fi

echo "Restoring the latest backup: $LATEST_BACKUP_ID"

# Execute the recovery, replacing placeholders as necessary
# This command assumes you can run commands remotely via SSH as the PostgreSQL user
# ssh postgres@$REMOTE_HOST "barman recover --remote-ssh-command 'ssh postgres@$REMOTE_HOST' $SERVER_ID $LATEST_BACKUP_ID $REMOTE_PGDATA_PATH"

# echo "Restore process initiated for backup $LATEST_BACKUP_ID to $REMOTE_HOST"
