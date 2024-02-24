#!/bin/bash

# Configuration
REMOTE_HOST=$(aws ssm get-parameter --name STANDBY_PUBLIC_IP --with-decryption --query 'Parameter.Value' --output text)
DB_NAME="db0"
PGPORT_SRC="5432"
PGPORT_DEST="5433"
TABLES=("trades" "book" "open_interest" "funding" "liquidations")
TIMESCALEDBPASSWORD=$(aws ssm get-parameter --name timescaledbpassword --with-decryption --query 'Parameter.Value' --output text)
export SOURCE=postgres://postgres:$TIMESCALEDBPASSWORD@localhost:$PGPORT_SRC/$DB_NAME
export TARGET=postgres://postgres:$TIMESCALEDBPASSWORD@localhost:$PGPORT_DEST/$DB_NAME
# Execute a command as postgres user on the remote host
execute_as_postgres() {
    ssh -T postgres@$REMOTE_HOST "$1"
}

execute_as_postgres timescaledb-backfill stage --source $SOURCE --target $TARGET --until '2016-01-02T00:00:00' #dynamic set the until date fetching the last date in the source instance and setting this date 
execute_as_postgres timescaledb-backfill copy --source $SOURCE --target $TARGET
execute_as_postgres timescaledb-backfill verify --source $SOURCE --target $TARGET
execute_as_postgres timescaledb-backfill clean --target $TARGET
