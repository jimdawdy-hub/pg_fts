#!/bin/bash
B=/nvme/pg17/bin; D=/nvme/pgdata; LIB=$($B/pg_config --pkglibdir); P="$B/psql -h /tmp -U postgres -X -q -At"
for Q in "year" "slovakia" "united & states"; do
 q="SELECT id FROM docs WHERE d @@@ to_ftsquery('english','$Q') ORDER BY d <=> to_ftsquery('english','$Q') LIMIT 10"
 for cfg in 110 a3 a4 110 a3 a4 110 a3 a4 110 a3 a4 110 a3 a4; do
  $B/pg_ctl -D $D -w stop >/dev/null 2>&1; cp /nvme/pg_fts_$cfg.so $LIB/pg_fts.so; sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
  $B/pg_ctl -D $D -l $D/server.log -w start >/dev/null
  t=$($P -c "SET enable_seqscan=off; SET enable_bitmapscan=off;" -c "\timing on" -c "SELECT to_ftsquery('english','x')" -c "SELECT count(*) FROM ($q) s" 2>&1 | grep Time | tail -1 | sed 's/Time: //; s/ ms.*//')
  echo "$Q $cfg $t"
 done
done | awk '{k=$1" "$2; if ($1=="united") k=$1" "$2" "$3" "$4; v=$NF; a[k]=a[k]" "v} END {for (k in a) print k":"a[k]}' | sort
$B/pg_ctl -D $D -w stop >/dev/null 2>&1; cp /nvme/pg_fts_a.so $LIB/pg_fts.so; $B/pg_ctl -D $D -l $D/server.log -w start >/dev/null
