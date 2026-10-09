#!/bin/bash
B=/nvme/pgs/bin; LIB=$($B/pg_config --pkglibdir); P="$B/psql -h /tmp -p 55440 -U postgres -X -q -At"
for v in fts110 cur; do
  $B/pg_ctl -D /nvme/bench_s -w stop >/dev/null 2>&1; cp /nvme/pg_fts_$v.so $LIB/pg_fts.so; $B/pg_ctl -D /nvme/bench_s -l /nvme/bench_s/server.log -w start >/dev/null
  echo "== $v"; $P -f /tmp/wt.sql 2>&1 | grep -v NOTICE
  $P -c "SET enable_seqscan = off; SET enable_bitmapscan = off;" -c "SELECT 'fts_search rows', count(*) FROM fts_search('wt_fts', to_ftsquery('simple', 'alpha:A & beta'), 150)"
  $P -c "SET enable_seqscan = off; SET enable_bitmapscan = off;" -c "SELECT 'single alpha:A ranked', count(*), count(*) FILTER (WHERE id % 2 = 1) FROM (SELECT id FROM wt WHERE d @@@ to_ftsquery('simple', 'alpha:A') ORDER BY d <=> to_ftsquery('simple', 'alpha:A') LIMIT 150) s"
  $P -c "SET enable_seqscan = off; SET enable_bitmapscan = off;" -c "SELECT 'or alpha:A | zzz ranked', count(*), count(*) FILTER (WHERE id % 2 = 1) FROM (SELECT id FROM wt WHERE d @@@ to_ftsquery('simple', 'alpha:A | zzz') ORDER BY d <=> to_ftsquery('simple', 'alpha:A | zzz') LIMIT 150) s"
done
cp /nvme/pg_fts_cur.so $LIB/pg_fts.so; $B/pg_ctl -D /nvme/bench_s -w restart -l /nvme/bench_s/server.log >/dev/null
