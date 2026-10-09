#!/bin/bash
# identical cluster on every host
set -euo pipefail
ENG=$1; B=/nvme/pg17/bin; D=/nvme/pgdata
$B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null
PRE=pg_prewarm; [ $ENG = pgts ] && PRE="pg_prewarm,pg_textsearch"; [ $ENG = psearch ] && PRE="pg_prewarm,pg_search"; [ $ENG = vchord ] && PRE="pg_prewarm,pg_tokenizer"
cat >> $D/postgresql.conf <<C
listen_addresses=''
unix_socket_directories='/tmp'
max_connections=200
shared_buffers=32GB
maintenance_work_mem=8GB
work_mem=256MB
jit=off
autovacuum=off
max_wal_size=64GB
max_parallel_maintenance_workers=8
max_parallel_workers=16
max_worker_processes=24
shared_preload_libraries='$PRE'
C
$B/pg_ctl -D $D -l $D/server.log -w start >/dev/null
$B/psql -h /tmp -U postgres -X -q -c "CREATE TABLE docs(id bigint PRIMARY KEY, content text)" -c "\copy docs FROM '/nvme/c.tsv' WITH (FORMAT csv, DELIMITER E'\t', QUOTE E'\b')"
echo "CLUSTER_DONE rows=$($B/psql -h /tmp -U postgres -X -At -c 'select count(*) from docs')"
