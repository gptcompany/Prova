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
# Dump the database roles from the source database
execute_as_postgres "pg_dumpall -d "$SOURCE" \
  -l $DB_NAME \
  --quote-all-identifiers \
  --roles-only \
  --file=roles.sql"
# Execute the command adding the --no-role-passwords flag. if errors in above commands


# Dump all plain tables and the TimescaleDB catalog from the source database
execute_as_postgres "pg_dump -d "$SOURCE" \
  --format=plain \
  --quote-all-identifiers \
  --no-tablespaces \
  --no-owner \
  --no-privileges \
  --exclude-table-data='_timescaledb_internal.*' \
  --file=dump.sql"

# Ensure that the correct TimescaleDB version is installed
# Retrieve TimescaleDB extension version from source database
TIMESCALEDB_VERSION=$(execute_as_postgres "psql -t -A -d $SOURCE -c \"SELECT extversion FROM pg_extension WHERE extname = 'timescaledb';\"")
# Update TimescaleDB extension to the retrieved version in the target database
execute_as_postgres "psql -d $TARGET -c \"ALTER EXTENSION timescaledb UPDATE TO '$TIMESCALEDB_VERSION';\""

# Load the roles and schema into the target database, and turn off all background jobs
execute_as_postgres "psql -X -d "$TARGET" \
  -v ON_ERROR_STOP=1 \
  --echo-errors \
  -f roles.sql \
  -c 'select public.timescaledb_pre_restore();' \
  -f dump.sql \
  -f - <<'EOF'
begin;
select public.timescaledb_post_restore();

-- disable all background jobs
select public.alter_job(id::integer, scheduled=>false)
from _timescaledb_config.bgw_job
where id >= 1000
;
commit;
EOF"

until_date=$(date '+%Y-%m-%d')
execute_as_postgres "timescaledb-backfill stage --source $SOURCE --target $TARGET --until '$until_date'" #dynamic set the until date fetching the last date in the source instance and setting this date 
execute_as_postgres "timescaledb-backfill copy --source $SOURCE --target $TARGET"
execute_as_postgres "timescaledb-backfill verify --source $SOURCE --target $TARGET"
execute_as_postgres "timescaledb-backfill clean --target $TARGET"
