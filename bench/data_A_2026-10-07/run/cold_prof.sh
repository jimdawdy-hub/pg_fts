#!/bin/bash
B=/nvme/pg17/bin; D=/nvme/pgdata; LIB=$($B/pg_config --pkglibdir); P="$B/psql -h /tmp -U postgres -X -q -At"
for arm in 110 a; do
  $B/pg_ctl -D $D -w stop >/dev/null 2>&1; cp /nvme/pg_fts_$arm.so $LIB/pg_fts.so; sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
  $B/pg_ctl -D $D -l $D/server.log -w start >/dev/null
  { echo "SELECT pg_backend_pid();"; echo "SELECT pg_sleep(1.5);"; echo "SET enable_seqscan=off; SET enable_bitmapscan=off;"; echo "SELECT count(*) FROM (SELECT id FROM docs WHERE d @@@ to_ftsquery('english','year') ORDER BY d <=> to_ftsquery('english','year') LIMIT 10) s;"; } > /tmp/cp.sql
  $P -f /tmp/cp.sql > /tmp/cp.out 2>&1 & sleep 0.5; BP=$(head -1 /tmp/cp.out)
  sudo perf record -F 20000 -g -p $BP -o /tmp/cp_$arm.data -- sleep 2.5 >/dev/null 2>&1; wait
  echo "== arm=$arm"
  sudo perf report -i /tmp/cp_$arm.data --no-children --sort sym --stdio -g none 2>/dev/null | grep -E "^ +[0-9]" | grep -v "pg_sleep\|WaitLatch\|epoll" | head -12
  sudo perf report -i /tmp/cp_$arm.data --children --sort sym --stdio -g none 2>/dev/null | grep -E "^ +[0-9]" | grep -E "bm25|fts_|shdl|doclen" | head -10
done
