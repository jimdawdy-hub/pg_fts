#!/bin/bash
B=/nvme/pgs/bin; LIB=$($B/pg_config --pkglibdir); P="$B/psql -h /tmp -p 55440 -U postgres -X -q -At"
for v in fts110 cur; do
  $B/pg_ctl -D /nvme/bench_s -w stop >/dev/null 2>&1; cp /nvme/pg_fts_$v.so $LIB/pg_fts.so; $B/pg_ctl -D /nvme/bench_s -l /nvme/bench_s/server.log -w start >/dev/null
  $P -c "SELECT pg_prewarm('docs_fts_pos'), pg_prewarm('docs')" >/dev/null
  for Q in '"united states"' 'united & states' '"world war"' 'slovakia & hungary'; do
    sql="SELECT string_agg(id::text, ',') FROM (SELECT id FROM docs WHERE d @@@ to_ftsquery('english','$Q') ORDER BY d <=> to_ftsquery('english','$Q') LIMIT 10) s"
    line="$v [$Q]"
    for pass in 1 2 3; do
      { echo "BEGIN; UPDATE pg_index SET indisvalid=false WHERE indexrelid='docs_fts'::regclass;"; echo "SET enable_seqscan=off; SET enable_bitmapscan=off;"; echo '\timing on'; for i in 1 2 3 4 5 6 7 8; do echo "$sql;"; done; echo "ROLLBACK;"; } > /tmp/ph.sql
      $P -f /tmp/ph.sql > /tmp/ph.out 2>&1
      line="$line $(grep -B0 -A0 '^Time' /tmp/ph.out | sed -n 's/^Time: \([0-9.]*\) ms.*/\1/p' | sed -n '3,10p' | tail -5 | sort -n | sed -n 3p)"
    done
    echo "$line ids=$(grep -v -E '^Time|^BEGIN|^UPDATE|^ROLLBACK|^SET' /tmp/ph.out | sort -u | md5sum | cut -c1-8)"
  done
done
cp /nvme/pg_fts_cur.so $LIB/pg_fts.so; $B/pg_ctl -D /nvme/bench_s -w restart -l /nvme/bench_s/server.log >/dev/null
