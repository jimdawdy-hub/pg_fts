#!/bin/bash
# cold common_k10 / and_common_k10: arm a with bestfirst on vs off, and arm 110; same reads?
B=/nvme/pg17/bin; D=/nvme/pgdata; LIB=$($B/pg_config --pkglibdir); P="$B/psql -h /tmp -U postgres -X -q -At"
$P -c "ALTER SYSTEM SET pg_prewarm.autoprewarm = off" >/dev/null; rm -f $D/autoprewarm.blocks
for Q in "year" "united & states"; do
 for cfg in "110:on" "a:on" "a:off" "110:on" "a:on" "a:off"; do arm=${cfg%%:*}; bf=${cfg##*:}
  vals=""
  for rep in 1 2 3; do
    $B/pg_ctl -D $D -w stop >/dev/null 2>&1; cp /nvme/pg_fts_$arm.so $LIB/pg_fts.so; sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
    $B/pg_ctl -D $D -l $D/server.log -w start >/dev/null; $P -c "SELECT to_ftsquery('english','x')" >/dev/null
    S="SET enable_seqscan=off; SET enable_bitmapscan=off;"; [ $arm = a ] && S="$S SET pg_fts.bestfirst=$bf;"
    v=$($P -c "$S" -c "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) SELECT id FROM docs WHERE d @@@ to_ftsquery('english','$Q') ORDER BY d <=> to_ftsquery('english','$Q') LIMIT 10" | python3 -c "import json,sys; j=json.loads(sys.stdin.read())[0]; p=j['Plan']; print('%.1f/%d/%d' % (j['Execution Time'], p.get('Shared Read Blocks',0), p.get('Shared Hit Blocks',0)))")
    vals="$vals $v"
  done
  echo "[$Q] arm=$arm bestfirst=$bf ms/reads/hits:$vals"
 done
done
$P -c "ALTER SYSTEM RESET pg_prewarm.autoprewarm" >/dev/null
