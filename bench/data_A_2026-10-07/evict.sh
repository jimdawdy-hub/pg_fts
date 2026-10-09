#!/bin/bash
# How much of a hot working set does a build evict? Warm docs_fts (1.49 GB) into shared_buffers,
# build docs_fts_b, then count docs_fts pages still resident.  shared_buffers is 32 GB here, larger
# than everything, so also run with a 4 GB shared_buffers to make eviction possible.
B=/nvme/pgs/bin; LIB=$($B/pg_config --pkglibdir); P="$B/psql -h /tmp -p 55440 -U postgres -X -q -At"
$P -c "CREATE EXTENSION IF NOT EXISTS pg_buffercache" >/dev/null 2>&1 || { cd /nvme/postgresql-17.10/contrib/pg_buffercache && make -s PG_CONFIG=$B/pg_config USE_PGXS=1 install >/dev/null 2>&1; $P -c "CREATE EXTENSION IF NOT EXISTS pg_buffercache" >/dev/null; }
SB0=$($P -c "SHOW shared_buffers")
$P -c "ALTER SYSTEM SET shared_buffers = '4GB'" >/dev/null
for v in ${VERS:-cur}; do
  $B/pg_ctl -D /nvme/bench_s -w stop >/dev/null 2>&1; cp /nvme/pg_fts_$v.so $LIB/pg_fts.so; $B/pg_ctl -D /nvme/bench_s -l /nvme/bench_s/server.log -w start >/dev/null
  $P -c "SELECT pg_prewarm('docs_fts')" >/dev/null
  r0=$($P -c "SELECT count(*) FROM pg_buffercache WHERE relfilenode = pg_relation_filenode('docs_fts')")
  $P -c "DROP INDEX IF EXISTS docs_fts_b" >/dev/null 2>&1
  t0=$(date +%s.%N); $P -c "SET client_min_messages = warning" -c "CREATE INDEX docs_fts_b ON docs USING fts (d)" >/dev/null; t1=$(date +%s.%N)
  r1=$($P -c "SELECT count(*) FROM pg_buffercache WHERE relfilenode = pg_relation_filenode('docs_fts')")
  echo "$v sb=4GB docs_fts resident pages before=$r0 after_build=$r1 ($(echo "scale=1; 100*$r1/$r0" | bc)%) build_s=$(printf %.1f $(echo "$t1-$t0"|bc)) new_index_resident=$($P -c "SELECT count(*) FROM pg_buffercache WHERE relfilenode = pg_relation_filenode('docs_fts_b')")"
done
$P -c "ALTER SYSTEM SET shared_buffers = '$SB0'" >/dev/null; $B/pg_ctl -D /nvme/bench_s -w restart -l /nvme/bench_s/server.log >/dev/null
cp /nvme/pg_fts_cur.so $LIB/pg_fts.so; $B/pg_ctl -D /nvme/bench_s -w restart -l /nvme/bench_s/server.log >/dev/null
echo "shared_buffers restored: $($P -c "SHOW shared_buffers")"
