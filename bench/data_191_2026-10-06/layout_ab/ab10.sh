#!/bin/bash
# usage: ab10.sh <bindir> <datadir> <port>; reuses /nvme/pg_fts_{190,191,191n}.so; 5 alternating passes
B=$1; D=$2; PORT=$3; LIB=$($B/pg_config --pkglibdir); P="$B/psql -h /tmp -p $PORT -U postgres -X -q -At"
for v in 190 191 191n; do echo "$v so=$(md5sum /nvme/pg_fts_$v.so | cut -c1-8) dense1_sym=$(nm /nvme/pg_fts_$v.so | grep -c ' fts_search_dense1$')"; done
cp $LIB/pg_fts.so /nvme/pg_fts_installed.so
q() { echo "SELECT count(*) FROM (SELECT id FROM docs WHERE d @@@ to_ftsquery('english','$1') ORDER BY d <=> to_ftsquery('english','$1') LIMIT $2) s"; }
for pass in 1 2 3 4 5; do for v in 190 191 191n; do
  $B/pg_ctl -D $D -w stop >/dev/null 2>&1; cp /nvme/pg_fts_$v.so $LIB/pg_fts.so; $B/pg_ctl -D $D -l $D/server.log -w start >/dev/null
  $P -c "SELECT pg_prewarm('docs'), pg_prewarm('docs_fts')" >/dev/null || exit 1
  line="pass=$pass v=$v"
  for spec in "year|10" "year|100"; do t=${spec%|*}; k=${spec##*|}; sql=$(q "$t" $k)
    { echo '\timing on'; for i in $(seq 1 12); do echo "$sql;"; done; } > /tmp/ab.sql
    $P -f /tmp/ab.sql > /tmp/ab.out 2>&1
    line="$line ${t}_k$k=$(sed -n 's/^Time: \([0-9.]*\) ms.*/\1/p' /tmp/ab.out | tail -9 | sort -n | sed -n 5p)[$(grep -v Time /tmp/ab.out | sort -u)]"
  done; echo "$line"
done; done
cp /nvme/pg_fts_installed.so $LIB/pg_fts.so
