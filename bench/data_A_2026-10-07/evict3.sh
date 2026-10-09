#!/bin/bash
# isolate the index's own I/O from TOAST: warm docs_fts, then fts_merge a 7-segment copy (no heap/TOAST
# reads at all) -- prev evicts via the merge's own reads/writes; cur should not.
B=/nvme/pgs/bin; LIB=$($B/pg_config --pkglibdir); P="$B/psql -h /tmp -p 55440 -U postgres -X -q -At"
SB0=$($P -c "SHOW shared_buffers")
$P -c "ALTER SYSTEM SET shared_buffers = '4GB'" >/dev/null
for v in prev cur; do
  $B/pg_ctl -D /nvme/bench_s -w stop >/dev/null 2>&1; cp /nvme/pg_fts_$v.so $LIB/pg_fts.so; $B/pg_ctl -D /nvme/bench_s -l /nvme/bench_s/server.log -w start >/dev/null
  $P -c "DROP INDEX IF EXISTS docs_fts_b" >/dev/null 2>&1
  $P -c "SET pg_fts.build_collapse_max_mb = 1" -c "SET client_min_messages = warning" -c "CREATE INDEX docs_fts_b ON docs USING fts (d)" >/dev/null
  $B/pg_ctl -D /nvme/bench_s -w restart -l /nvme/bench_s/server.log >/dev/null
  $P -c "SELECT pg_prewarm('docs_fts')" >/dev/null
  r0=$($P -c "SELECT count(*) FROM pg_buffercache WHERE relfilenode = pg_relation_filenode('docs_fts')")
  t0=$(date +%s.%N); $P -c "SET client_min_messages = warning" -c "SELECT fts_merge('docs_fts_b')" >/dev/null; t1=$(date +%s.%N)
  r1=$($P -c "SELECT count(*) FROM pg_buffercache WHERE relfilenode = pg_relation_filenode('docs_fts')")
  echo "$v fts_merge(7 segs) docs_fts resident before=$r0 after=$r1 ($(echo "scale=1; 100*$r1/$r0" | bc)%) merge_s=$(printf %.1f $(echo "$t1-$t0"|bc)) merged_index_resident=$($P -c "SELECT count(*) FROM pg_buffercache WHERE relfilenode = pg_relation_filenode('docs_fts_b')") nseg=$($P -c "SELECT fts_index_nsegments('docs_fts_b')")"
done
$P -c "ALTER SYSTEM SET shared_buffers = '$SB0'" >/dev/null
cp /nvme/pg_fts_cur.so $LIB/pg_fts.so; $B/pg_ctl -D /nvme/bench_s -w restart -l /nvme/bench_s/server.log >/dev/null; echo "sb=$($P -c "SHOW shared_buffers")"
