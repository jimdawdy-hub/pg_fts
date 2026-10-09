#!/bin/bash
# cold run then 2nd run in the SAME backend; and a first query of a DIFFERENT term after warm
B=/nvme/pg17/bin; D=/nvme/pgdata; LIB=$($B/pg_config --pkglibdir); P="$B/psql -h /tmp -U postgres -X -q -At"
for arm in 110 a 110 a; do
  $B/pg_ctl -D $D -w stop >/dev/null 2>&1; cp /nvme/pg_fts_$arm.so $LIB/pg_fts.so; sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
  $B/pg_ctl -D $D -l $D/server.log -w start >/dev/null
  q="SELECT id FROM docs WHERE d @@@ to_ftsquery('english','year') ORDER BY d <=> to_ftsquery('english','year') LIMIT 10"
  out=$($P -c "SET enable_seqscan=off; SET enable_bitmapscan=off;" -c "\timing on" -c "SELECT to_ftsquery('english','x')" -c "SELECT count(*) FROM ($q) s" -c "SELECT count(*) FROM ($q) s" -c "SELECT count(*) FROM (SELECT id FROM docs WHERE d @@@ to_ftsquery('english','slovakia') ORDER BY d <=> to_ftsquery('english','slovakia') LIMIT 10) s" 2>&1 | grep Time | sed -n '2,4p' | sed 's/Time: //; s/ ms//' | tr '\n' ' ')
  echo "arm=$arm cold1(year) / warm2(year) / slovakia-after: $out"
done
# perf of the cold first query, arm a
$B/pg_ctl -D $D -w stop >/dev/null 2>&1; cp /nvme/pg_fts_a.so $LIB/pg_fts.so; sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
$B/pg_ctl -D $D -l $D/server.log -w start >/dev/null
