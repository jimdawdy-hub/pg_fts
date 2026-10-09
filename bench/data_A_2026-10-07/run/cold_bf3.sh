#!/bin/bash
# where does arm a's extra cold time go? same block reads; compare the cold run's posting pages
# and their order: a best-first walk reads blocks in bound order (random), 1.10.0 in chain order.
B=/nvme/pg17/bin; D=/nvme/pgdata; LIB=$($B/pg_config --pkglibdir); P="$B/psql -h /tmp -U postgres -X -q -At"
for arm in 110 a; do
  $B/pg_ctl -D $D -w stop >/dev/null 2>&1; cp /nvme/pg_fts_$arm.so $LIB/pg_fts.so; sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
  $B/pg_ctl -D $D -l $D/server.log -w start >/dev/null
  PID=$($P -c "SELECT 1" >/dev/null; echo)
  sudo strace -f -e trace=pread64,preadv,fadvise64,posix_fadvise -o /tmp/st_$arm.txt -p $(pgrep -f "postgres: postgres postgres \[local\] idle" | head -1) 2>/dev/null &
  { echo "SELECT pg_backend_pid();"; echo "SELECT pg_sleep(1);"; echo "SET enable_seqscan=off; SET enable_bitmapscan=off;"; echo "SELECT count(*) FROM (SELECT id FROM docs WHERE d @@@ to_ftsquery('english','year') ORDER BY d <=> to_ftsquery('english','year') LIMIT 10) s;"; echo "SELECT pg_sleep(0.5);"; } > /tmp/cb.sql
  $P -f /tmp/cb.sql > /tmp/cb.out 2>&1 & sleep 0.4; BP=$(head -1 /tmp/cb.out)
  sudo strace -e trace=pread64,preadv,fadvise64 -o /tmp/st_$arm.txt -p $BP 2>/dev/null & SP=$!
  wait %2 2>/dev/null; sleep 1; sudo kill $SP 2>/dev/null; wait $SP 2>/dev/null
  echo "arm=$arm preads=$(grep -c 'pread' /tmp/st_$arm.txt) fadvise=$(grep -c fadvise /tmp/st_$arm.txt) bytes8192=$(grep -c ', 8192, ' /tmp/st_$arm.txt)"
  # contiguity of the pread offsets (index file only is not distinguishable here; report sequential runs)
  grep pread /tmp/st_$arm.txt | sed -n 's/.*, \([0-9]*\)) .*/\1/p' | awk 'NR>1 && $1==prev+8192 {seq++} {prev=$1} END {print "  sequential successor reads:", seq+0, "of", NR}'
done
