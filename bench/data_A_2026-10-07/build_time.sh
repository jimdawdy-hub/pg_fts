#!/bin/bash
# full CREATE INDEX (default settings, 8 workers) + fts_vacuum, prev vs cur; positions off
B=/nvme/pgs/bin; LIB=$($B/pg_config --pkglibdir); P="$B/psql -h /tmp -p 55440 -U postgres -X -q -At"
$P -c "DROP TABLE IF EXISTS docs400t, docs400 CASCADE" >/dev/null 2>&1
for v in ${VERS:-prev cur}; do
  $B/pg_ctl -D /nvme/bench_s -w stop >/dev/null 2>&1; cp /nvme/pg_fts_$v.so $LIB/pg_fts.so; $B/pg_ctl -D /nvme/bench_s -l /nvme/bench_s/server.log -w start >/dev/null
  $P -c "DROP INDEX IF EXISTS docs_fts_b" >/dev/null 2>&1
  t0=$(date +%s.%N); $P -c "SET client_min_messages = warning" -c "CREATE INDEX docs_fts_b ON docs USING fts (d)" >/dev/null; t1=$(date +%s.%N)
  s1=$($P -c "SELECT pg_relation_size('docs_fts_b')")
  $P -c "SET client_min_messages = warning" -c "SELECT fts_vacuum('docs_fts_b')" >/dev/null; t2=$(date +%s.%N)
  echo "$v build_s=$(printf %.1f $(echo "$t1-$t0"|bc)) size_after_build=$s1 fts_vacuum_s=$(printf %.1f $(echo "$t2-$t1"|bc)) size=$($P -c "SELECT pg_relation_size('docs_fts_b')") nseg=$($P -c "SELECT fts_index_nsegments('docs_fts_b')") count_year=$($P -c "SELECT count(*) FROM docs WHERE d @@@ to_ftsquery('english','year')")"
done
cp /nvme/pg_fts_cur.so $LIB/pg_fts.so; $B/pg_ctl -D /nvme/bench_s -w restart -l /nvme/bench_s/server.log >/dev/null
