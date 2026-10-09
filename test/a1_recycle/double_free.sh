#!/usr/bin/env bash
# Deterministic reproduction: bm25_collect_matches' generation-retry path freed
# the per-segment tombstone maps a second time (fixed in 1.11.0).
#
# A bitmap scan over an index with a tombstoned segment is stalled right after
# it snapshots the directory (test-only pause hook, -DPG_FTS_TEST_HOOKS; see
# README.md).  A VACUUM then rewrites that segment's tombstone blob, bumping the
# directory generation, so the scan's end-of-collect re-check takes the retry
# path.  Before the fix the retry pfree'd the already-freed maps.
#
# Needs a --enable-cassert PostgreSQL to be deterministic: there the second
# pfree raises "detected double pfree"; without asserts it is a latent heap
# corruption (a SIGSEGV in sm_contains_many under churn).
#
# Usage:  B=/path/to/cassert-pg/bin  bash test/a1_recycle/double_free.sh
#   (pg_fts built with COPT=-DPG_FTS_TEST_HOOKS installed into that prefix)
# Unfixed: reader = "ERROR: detected double pfree ..." -> FAIL.  Fixed: PASS.
set -uo pipefail
B="${B:?set B=<bin dir of a cassert PostgreSQL with the hooks build installed>}"; PORT=${PORT:-5444}; W=$(mktemp -d); D=$W/data
$B/initdb -D $D --no-locale -E UTF8 >/dev/null 2>&1
printf "unix_socket_directories='/tmp'\nlisten_addresses=''\nfsync=off\nshared_buffers=16MB\nmaintenance_work_mem=1MB\nautovacuum=off\nport=$PORT\n" >> $D/postgresql.conf
$B/pg_ctl -D $D -l $W/log -w start >/dev/null
export PGOPTIONS="-c client_min_messages=error"; P="$B/psql -X -qtA -h /tmp -p $PORT postgres"
$P -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
CREATE EXTENSION pg_fts;
CREATE TABLE d (id bigserial PRIMARY KEY, kind text, body ftsdoc);
INSERT INTO d(kind,body) SELECT 'anchor', to_ftsdoc('simple','anchorterm filler'||g) FROM generate_series(1,500) g;
INSERT INTO d(kind,body) SELECT 'churn', to_ftsdoc('simple','anchorterm churnterm x'||(g%20)) FROM generate_series(1,40000) g;
CREATE INDEX d_fts ON d USING fts (body);
DELETE FROM d WHERE kind='churn' AND id % 2 = 0;
VACUUM d;
SQL
$P -c "DELETE FROM d WHERE kind='churn' AND id % 3 = 0" >/dev/null
exp=$($P -c "SELECT count(*) FROM d WHERE fts_match(body,'anchorterm'::ftsquery)")
$P -c "SELECT pg_advisory_lock(42); SELECT pg_sleep(20)" >/dev/null 2>&1 & BLK=$!; sleep 1
( $P -c "SET pg_fts.test_pause_advisory_key=42; SET enable_seqscan=off; SET enable_indexscan=off;
   SELECT count(*) FROM (SELECT id FROM d WHERE body @@@ 'anchorterm'::ftsquery OFFSET 0) s" > $W/r.out 2>&1 ) & RD=$!; sleep 2
echo "stalled=$($P -c "SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND NOT granted")"
$P >/dev/null 2>&1 <<'SQL'
VACUUM d;
SQL
$P -c "SELECT pg_advisory_unlock_all()" >/dev/null 2>&1; kill $BLK 2>/dev/null; wait $RD
reader=$(tr '\n' ' ' < $W/r.out)
echo "expected=$exp reader=$reader"
$B/pg_ctl -D $D -m immediate -w stop >/dev/null 2>&1
if [ "$reader" = "$exp " ]; then echo PASS; exit 0; else echo "FAIL (double pfree / wrong count)"; exit 1; fi
