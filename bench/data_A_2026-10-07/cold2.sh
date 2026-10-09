#!/bin/bash
# where do the cold reads go? pg_buffercache delta per relation after one cold ranked query
B=/nvme/pgs/bin; P="$B/psql -h /tmp -p 55440 -U postgres -X -q -At"
for Q in 'slovakia' 'united & states'; do
  $B/pg_ctl -D /nvme/bench_s -w stop >/dev/null 2>&1; sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
  $B/pg_ctl -D /nvme/bench_s -l /nvme/bench_s/server.log -w start >/dev/null
  $P -c "CREATE TEMP TABLE b0 AS SELECT relfilenode, count(*) n FROM pg_buffercache WHERE relfilenode IS NOT NULL GROUP BY 1" -c "SET enable_seqscan=off; SET enable_bitmapscan=off;" -c "SELECT count(*) FROM (SELECT id FROM docs WHERE d @@@ to_ftsquery('english','$Q') ORDER BY d <=> to_ftsquery('english','$Q') LIMIT 10) s" -c "SELECT '$Q', coalesce(c.relname, b.relfilenode::text), count(*) - coalesce(max(b0.n),0) FROM pg_buffercache b LEFT JOIN b0 USING (relfilenode) LEFT JOIN pg_class c ON c.relfilenode = b.relfilenode WHERE b.relfilenode IS NOT NULL GROUP BY 1,2 HAVING count(*) - coalesce(max(b0.n),0) > 5 ORDER BY 3 DESC"
done
