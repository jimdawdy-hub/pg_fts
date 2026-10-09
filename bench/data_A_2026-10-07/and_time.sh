#!/bin/bash
# A2 timing: 1.10.0 vs current (bestfirst on/off), AND on docs_fts, phrase+AND on docs_fts_pos. 3 passes, median of last 5 of 8.
B=/nvme/pgs/bin; LIB=$($B/pg_config --pkglibdir); P="$B/psql -h /tmp -p 55440 -U postgres -X -q -At"
run(){ # $1 label  $2 index-to-hide  $3 query  $4 extra SET
  local line="$1 [$3]"
  for pass in 1 2 3; do
    { echo "BEGIN; UPDATE pg_index SET indisvalid=false WHERE indexrelid='$2'::regclass;"; echo "SET LOCAL enable_seqscan=off; SET LOCAL enable_bitmapscan=off; $4"; echo '\timing on'
      for i in 1 2 3 4 5 6 7 8; do echo "SELECT count(*) FROM (SELECT id FROM docs WHERE d @@@ to_ftsquery('english','$3') ORDER BY d <=> to_ftsquery('english','$3') LIMIT 10) s;"; done; echo "ROLLBACK;"; } > /tmp/at.sql
    $P -f /tmp/at.sql > /tmp/at.out 2>&1
    line="$line $(sed -n 's/^Time: \([0-9.]*\) ms.*/\1/p' /tmp/at.out | sed -n '3,10p' | tail -5 | sort -n | sed -n 3p)"
  done; echo "$line"; }
for v in fts110 cur; do
  $B/pg_ctl -D /nvme/bench_s -w stop >/dev/null 2>&1; cp /nvme/pg_fts_$v.so $LIB/pg_fts.so; $B/pg_ctl -D /nvme/bench_s -l /nvme/bench_s/server.log -w start >/dev/null
  $P -c "SELECT pg_prewarm('docs_fts'), pg_prewarm('docs_fts_pos'), pg_prewarm('docs')" >/dev/null
  sets="x"; [ $v = cur ] && sets="on off"
  for bf in $sets; do
    S=""; [ $bf != x ] && S="SET LOCAL pg_fts.bestfirst=$bf;"
    L="$v${bf/x/}"
    for Q in 'slovakia & hungary' 'united & states' 'world & war' 'year & film'; do run "$L plain" docs_fts_pos "$Q" "$S"; done
    for Q in '"united states"' '"world war"' 'united & states'; do run "$L pos" docs_fts "$Q" "$S"; done
  done
done
cp /nvme/pg_fts_cur.so $LIB/pg_fts.so; $B/pg_ctl -D /nvme/bench_s -w restart -l /nvme/bench_s/server.log >/dev/null
