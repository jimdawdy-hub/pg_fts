#!/bin/bash
# usage: load_arm.sh <arm> <port>   -> cluster /nvme/bench_<arm>, docs + stored d + fts index, fts_vacuum'd
set -euo pipefail
ARM=$1; PORT=$2; B=/nvme/pg$ARM/bin; D=/nvme/bench_$ARM
$B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null
cat >> $D/postgresql.conf <<C
port=$PORT
unix_socket_directories='/tmp'
listen_addresses=''
max_connections=200
shared_buffers=${SB:-32GB}
maintenance_work_mem=8GB
work_mem=256MB
jit=off
autovacuum=off
max_wal_size=64GB
max_parallel_maintenance_workers=8
max_parallel_workers=16
max_worker_processes=24
shared_preload_libraries='pg_prewarm'
log_min_messages=info
C
$B/pg_ctl -D $D -l $D/server.log -w start >/dev/null
P="$B/psql -h /tmp -p $PORT -U postgres -X -q -At -v ON_ERROR_STOP=1"
$P -c "CREATE EXTENSION pg_fts; CREATE EXTENSION pg_prewarm"
$P -c "CREATE TABLE docs(id bigint, content text)" -c "\copy docs FROM '/nvme/c.tsv' WITH (FORMAT csv, DELIMITER E'\t', QUOTE E'\b')"
$P -c "ALTER TABLE docs ADD COLUMN d ftsdoc; UPDATE docs SET d = to_ftsdoc('english', content);"
$P -c "VACUUM (FREEZE, ANALYZE) docs"
s=$(date +%s); $P -c "CREATE INDEX docs_fts ON docs USING fts (d)"; $P -c "SELECT fts_vacuum('docs_fts')" >/dev/null
echo "arm=$ARM rows=$($P -c 'select count(*) from docs') build+vac_s=$(( $(date +%s)-s )) size=$($P -c "select pg_relation_size('docs_fts')") allvis=$($P -c "select relallvisible::float/relpages from pg_class where relname='docs'")"
