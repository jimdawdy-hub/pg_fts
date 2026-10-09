#!/bin/bash
# cold-cache ranked queries: drop OS page cache + restart PG before each query; time one execution.
# 5 repetitions per query, median. Reports buffer reads from EXPLAIN (ANALYZE, BUFFERS).
B=/nvme/pgs/bin; LIB=$($B/pg_config --pkglibdir); P="$B/psql -h /tmp -p 55440 -U postgres -X -q -At"
for v in ${VERS:-prev cur}; do
  cp /nvme/pg_fts_$v.so $LIB/pg_fts.so
  for Q in 'slovakia' 'year' 'united & states' 'slovakia | hungary'; do
    ts=""
    for r in 1 2 3 4 5; do
      $B/pg_ctl -D /nvme/bench_s -w stop >/dev/null 2>&1; sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
      $B/pg_ctl -D /nvme/bench_s -l /nvme/bench_s/server.log -w start >/dev/null
      $P -c "SELECT 1 FROM pg_class LIMIT 1" -c "SELECT to_ftsquery('english','x')" >/dev/null
      t=$($P -c "SET enable_seqscan=off; SET enable_bitmapscan=off;" -c "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) SELECT id FROM docs WHERE d @@@ to_ftsquery('english','$Q') ORDER BY d <=> to_ftsquery('english','$Q') LIMIT 10" | python3 -c "import json,sys; j=json.load(sys.stdin)[0]; p=j['Plan']; print(round(j['Execution Time'],2), p.get('Shared Read Blocks',0), p.get('Shared Hit Blocks',0))")
      ts="$ts|$t"
    done
    med=$(echo "$ts" | tr '|' '\n' | grep . | sort -n | sed -n 3p)
    echo "$v [$Q] cold median(ms reads hits)=$med all=$ts"
  done
done
cp /nvme/pg_fts_cur.so $LIB/pg_fts.so; $B/pg_ctl -D /nvme/bench_s -w restart -l /nvme/bench_s/server.log >/dev/null
