#!/bin/bash
# classify the cold index-page reads of one ranked query by page type (pg_buffercache delta + page flags)
B=/nvme/pgs/bin; P="$B/psql -h /tmp -p 55440 -U postgres -X -q -At"
$P -c "CREATE EXTENSION IF NOT EXISTS pageinspect" >/dev/null 2>&1 || { cd /nvme/postgresql-17.10/contrib/pageinspect && make -s PG_CONFIG=$B/pg_config USE_PGXS=1 install >/dev/null 2>&1; $P -c "CREATE EXTENSION IF NOT EXISTS pageinspect" >/dev/null; }
for Q in 'slovakia' 'year'; do
  $B/pg_ctl -D /nvme/bench_s -w stop >/dev/null 2>&1; sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
  $B/pg_ctl -D /nvme/bench_s -l /nvme/bench_s/server.log -w start >/dev/null
  $P -c "CREATE TEMP TABLE b0 AS SELECT relblocknumber FROM pg_buffercache WHERE relfilenode = pg_relation_filenode('docs_fts')" -c "SET enable_seqscan=off; SET enable_bitmapscan=off;" -c "SELECT count(*) FROM (SELECT id FROM docs WHERE d @@@ to_ftsquery('english','$Q') ORDER BY d <=> to_ftsquery('english','$Q') LIMIT 10) s" -c "
  SELECT '$Q', CASE get_byte(substr(p, 8185, 2), 0) + 256*get_byte(substr(p, 8185, 2), 1)
     WHEN 1 THEN 'meta' WHEN 2 THEN 'dict' WHEN 4 THEN 'posting' WHEN 128 THEN 'dictindex' WHEN 512 THEN 'doclen' ELSE 'other' END kind, count(*)
  FROM (SELECT get_raw_page('docs_fts', relblocknumber::int) p FROM pg_buffercache WHERE relfilenode = pg_relation_filenode('docs_fts') AND relblocknumber NOT IN (SELECT relblocknumber FROM b0)) x GROUP BY 1,2 ORDER BY 3 DESC" | grep -v "^10$"
done
