#!/bin/bash
# live-page identity prev vs cur for v4 positions=off and positions=on (400k serial, 64MB mwm)
B=/nvme/pgs/bin; LIB=$($B/pg_config --pkglibdir); P="$B/psql -h /tmp -p 55440 -U postgres -X -q -At"
for v in prev cur; do
  $B/pg_ctl -D /nvme/bench_s -w stop >/dev/null 2>&1; cp /nvme/pg_fts_$v.so $LIB/pg_fts.so; $B/pg_ctl -D /nvme/bench_s -l /nvme/bench_s/server.log -w start >/dev/null
  for pos in off on; do
    $P -c "DROP INDEX IF EXISTS d400_$pos" >/dev/null 2>&1
    $P -c "SET max_parallel_maintenance_workers = 0; SET maintenance_work_mem = '64MB'; SET client_min_messages = warning" -c "CREATE INDEX d400_$pos ON docs400 USING fts (d) WITH (positions = $pos)" >/dev/null
    $P -c "CHECKPOINT" >/dev/null; f=$($P -c "SELECT pg_relation_filepath('d400_$pos')"); cat /nvme/bench_s/$f /nvme/bench_s/$f.[0-9] 2>/dev/null > /nvme/idx_p${pos}_$v.bin
  done
done
for pos in off on; do python3 /tmp/live_cmp.py /nvme/idx_p${pos}_prev.bin /nvme/idx_p${pos}_cur.bin positions_$pos; done
cp /nvme/pg_fts_cur.so $LIB/pg_fts.so; $B/pg_ctl -D /nvme/bench_s -w restart -l /nvme/bench_s/server.log >/dev/null
