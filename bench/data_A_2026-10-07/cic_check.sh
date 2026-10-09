#!/bin/bash
# CREATE INDEX CONCURRENTLY must keep working (no in-build pack: no AccessExclusiveLock) and match
B=/nvme/pgs/bin; P="$B/psql -h /tmp -p 55440 -U postgres -X -q -At"
$P -c "DROP INDEX IF EXISTS d400_cic" >/dev/null 2>&1
$P -c "SET max_parallel_maintenance_workers = 0; SET maintenance_work_mem = '64MB'; SET client_min_messages = warning" -c "CREATE INDEX CONCURRENTLY d400_cic ON docs400 USING fts (d)"
echo "CIC: valid=$($P -c "SELECT indisvalid FROM pg_index WHERE indexrelid='d400_cic'::regclass") size=$($P -c "SELECT pg_relation_size('d400_cic')") nseg=$($P -c "SELECT fts_index_nsegments('d400_cic')")"
$P -c "SET client_min_messages = warning" -c "SELECT fts_vacuum('d400_cic')" >/dev/null
echo "CIC after fts_vacuum: size=$($P -c "SELECT pg_relation_size('d400_cic')")"
$P -c "CHECKPOINT" >/dev/null; f=$($P -c "SELECT pg_relation_filepath('d400_cic')"); cat /nvme/bench_s/$f /nvme/bench_s/$f.[0-9] 2>/dev/null > /nvme/idx_cic.bin
python3 /tmp/live_cmp.py /nvme/idx_c_cur.bin /nvme/idx_cic.bin plain_inbuild_vs_cic_plus_fts_vacuum
echo "count: $($P -c "SET enable_seqscan=off" -c "SELECT count(*) FROM docs400 WHERE d @@@ to_ftsquery('english','year')")"
$P -c "DROP INDEX d400_cic" >/dev/null
