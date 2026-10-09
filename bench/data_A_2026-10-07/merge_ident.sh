#!/bin/bash
# Same deterministic multi-segment build merged by the old binary and the new one: the index files
# must be byte-identical. Serial build (no workers), small maintenance_work_mem -> several flushes
# in docid order, then the build's collapse merge. 400k-row subset.
B=/nvme/pgs/bin; LIB=$($B/pg_config --pkglibdir); P="$B/psql -h /tmp -p 55440 -U postgres -X -q -At"
$P -c "CREATE TABLE IF NOT EXISTS docs400 AS SELECT id, d FROM docs WHERE id IN (SELECT id FROM docs ORDER BY id LIMIT 400000)" >/dev/null 2>&1
$P -c "VACUUM (FREEZE, ANALYZE) docs400" >/dev/null
for v in prev cur; do
  $B/pg_ctl -D /nvme/bench_s -w stop >/dev/null 2>&1; cp /nvme/pg_fts_$v.so $LIB/pg_fts.so; $B/pg_ctl -D /nvme/bench_s -l /nvme/bench_s/server.log -w start >/dev/null
  for pos in off on; do
    $P -c "DROP INDEX IF EXISTS d400_$pos" >/dev/null
    t0=$(date +%s.%N)
    $P -c "SET max_parallel_maintenance_workers = 0; SET maintenance_work_mem = '64MB'; SET client_min_messages = warning" -c "CREATE INDEX d400_$pos ON docs400 USING fts (d) WITH (positions = $pos)" >/dev/null
    t1=$(date +%s.%N)
    $P -c "CHECKPOINT" >/dev/null
    f=$($B/pg_ctl -D /nvme/bench_s status >/dev/null; $P -c "SELECT pg_relation_filepath('d400_$pos')")
    echo "$v positions=$pos build_s=$(printf %.1f $(echo "$t1-$t0" | bc)) nseg=$($P -c "SELECT fts_index_nsegments('d400_$pos')") size=$($P -c "SELECT pg_relation_size('d400_$pos')") md5=$(cat /nvme/bench_s/$f* | md5sum | cut -c1-12)"
  done
done
