#!/bin/bash

# PostgreSQL settings
DB_NAME="db0"
PGUSER="postgres"
PGHOST="0.0.0.0"
PGPORT="5432"

# pg_probackup settings
BACKUP_PATH="~/ts_backups"
INSTANCE_NAME="timescaledb"

# AWS S3 settings
S3_BUCKET="s3://tsbakups"
S3_PATH="~/ts_backups"

# Date and time format for backup naming
DATE_FORMAT=$(date +"%Y%m%d%H%M%S")

# Function to perform a pg_probackup
perform_backup() {
    echo "Starting backup for instance $INSTANCE_NAME..."
    pg_probackup backup -B $BACKUP_PATH -b DELTA -U $PGUSER -d $DB_NAME --instance $INSTANCE_NAME --stream
    echo "Backup completed."
}

# Function to upload the backup to S3
upload_to_s3() {
    echo "Uploading backup to S3..."
    aws s3 cp $BACKUP_PATH/$INSTANCE_NAME/backups s3://$S3_BUCKET/$S3_PATH/$INSTANCE_NAME/$DATE_FORMAT --recursive
    echo "Upload completed."
}

# Perform the backup and then upload to S3
perform_backup
upload_to_s3

exit 0
