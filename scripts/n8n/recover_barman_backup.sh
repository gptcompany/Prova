#!/bin/bash

# Define server identifier and remote PostgreSQL instance
SERVER_ID="timescaledb"
REMOTE_HOST=$(aws ssm get-parameter --name STANDBY_PUBLIC_IP --with-decryption --query 'Parameter.Value' --output text)
REMOTE_PGDATA_PATH=$(ssh postgres@$REMOTE_HOST "psql -p 5432 -t -c 'SHOW data_directory;'")
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

# Execute the recovery
# This command assumes you can run commands remotely via SSH as the PostgreSQL user
sudo -i -u barman /bin/bash -c "barman recover --remote-ssh-command 'ssh postgres@${REMOTE_HOST}' $SERVER_ID $LATEST_BACKUP_ID $REMOTE_PGDATA_PATH"

# Check the status of PostgreSQL running on port 5432

# sudo -i -u barman /bin/bash -c "ssh -v postgres@timescaledb.mywire.org 'pg_isready -p 5432'"
sudo -i -u barman /bin/bash -c "ssh postgres@$REMOTE_HOST 'pg_isready -p 5432'"

