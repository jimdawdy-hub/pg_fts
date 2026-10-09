#!/bin/bash
B=/nvme/pgs/bin; P="$B/psql -h /tmp -p 55440 -U postgres -X -q -At"
$P -c "DROP INDEX IF EXISTS docs_fts_b" >/dev/null
$P -c "SET pg_fts.build_collapse_max_mb = 1" -c "SET client_min_messages=warning" -c "CREATE INDEX docs_fts_b ON docs USING fts (d)" >/dev/null 2>&1
W0=$($P -c "SELECT pg_current_wal_lsn()")
{ echo "SELECT pg_backend_pid();"; echo "SELECT pg_sleep(1);"; echo "\\timing on"; echo "SELECT fts_merge('docs_fts_b');"; } > /tmp/mc.sql
$P -f /tmp/mc.sql > /tmp/mc.out 2>&1 & sleep 0.5; PID=$(head -1 /tmp/mc.out)
sleep 3; sudo perf record -F 999 -g -p $PID -o /tmp/mp4.data -- sleep 25 >/dev/null 2>&1
wait; grep Time /tmp/mc.out; echo "merge WAL bytes: $($P -c "SELECT pg_current_wal_lsn() - '$W0'::pg_lsn")"
sudo perf report -i /tmp/mp4.data --no-children --sort sym --stdio -g none 2>/dev/null | grep -E "^ +[0-9]" | head -14
