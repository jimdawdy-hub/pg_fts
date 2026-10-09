#!/bin/bash
# arm a cold 'year' with prefetch neutralized (eic=0 disables PrefetchBuffer's posix_fadvise) vs default
B=/nvme/pg17/bin; D=/nvme/pgdata; LIB=$($B/pg_config --pkglibdir); P="$B/psql -h /tmp -U postgres -X -q -At"
q="SELECT id FROM docs WHERE d @@@ to_ftsquery('english','year') ORDER BY d <=> to_ftsquery('english','year') LIMIT 10"
for cfg in "a:0" "a:1" "110:1" "a:0" "a:1" "110:1" "a:0" "a:1" "110:1"; do arm=${cfg%%:*}; eic=${cfg##*:}
  $B/pg_ctl -D $D -w stop >/dev/null 2>&1; cp /nvme/pg_fts_$arm.so $LIB/pg_fts.so; sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
  $B/pg_ctl -D $D -l $D/server.log -w start -o "-c effective_io_concurrency=$eic" >/dev/null
  t=$($P -c "SET enable_seqscan=off; SET enable_bitmapscan=off;" -c "\timing on" -c "SELECT to_ftsquery('english','x')" -c "SELECT count(*) FROM ($q) s" 2>&1 | grep Time | tail -1)
  echo "arm=$arm eic=$eic cold year: $t"
done
$B/pg_ctl -D $D -w restart -l $D/server.log >/dev/null
