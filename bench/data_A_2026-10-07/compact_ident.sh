#!/bin/bash
# in-build pack (cur) vs build + fts_vacuum (prev): live pages of the final index must match
B=/nvme/pgs/bin; LIB=$($B/pg_config --pkglibdir); P="$B/psql -h /tmp -p 55440 -U postgres -X -q -At"
$P -c "CREATE TABLE IF NOT EXISTS docs400 AS SELECT id, d FROM docs WHERE id IN (SELECT id FROM docs ORDER BY id LIMIT 400000)" >/dev/null 2>&1; $P -c "VACUUM (FREEZE, ANALYZE) docs400" >/dev/null; echo "docs400 rows=$($P -c "SELECT count(*) FROM docs400")"
for v in prev cur; do
  $B/pg_ctl -D /nvme/bench_s -w stop >/dev/null 2>&1; cp /nvme/pg_fts_$v.so $LIB/pg_fts.so; $B/pg_ctl -D /nvme/bench_s -l /nvme/bench_s/server.log -w start >/dev/null
  $P -c "DROP INDEX IF EXISTS d400_off" >/dev/null 2>&1
  $P -c "SET max_parallel_maintenance_workers = 0; SET maintenance_work_mem = '64MB'; SET client_min_messages = warning" -c "CREATE INDEX d400_off ON docs400 USING fts (d)" >/dev/null
  echo "$v after build: size=$($P -c "SELECT pg_relation_size('d400_off')") nseg=$($P -c "SELECT fts_index_nsegments('d400_off')")"
  [ $v = prev ] && $P -c "SET client_min_messages = warning" -c "SELECT fts_vacuum('d400_off')" >/dev/null
  $P -c "CHECKPOINT" >/dev/null; f=$($P -c "SELECT pg_relation_filepath('d400_off')"); cat /nvme/bench_s/$f /nvme/bench_s/$f.[0-9] 2>/dev/null > /nvme/idx_c_$v.bin
done
python3 /tmp/live_cmp.py /nvme/idx_c_prev.bin /nvme/idx_c_cur.bin inbuild_pack_vs_fts_vacuum
cp /nvme/pg_fts_cur.so $LIB/pg_fts.so; $B/pg_ctl -D /nvme/bench_s -w restart -l /nvme/bench_s/server.log >/dev/null
