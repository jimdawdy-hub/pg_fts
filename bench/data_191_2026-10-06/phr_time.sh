#!/bin/bash
B=/nvme/pgs/bin; P="$B/psql -h /tmp -p 55440 -U postgres -X -q -At"
for ph in '"united states"' '"new york city"' '"world war"' '"university of california"'; do
 for arm in on off on off on off; do
  SQL="SELECT count(*) FROM (SELECT id FROM docs WHERE d @@@ to_ftsquery('english','$ph') ORDER BY d <=> to_ftsquery('english','$ph') LIMIT 10) s"
  { echo "SET enable_seqscan=off; SET enable_bitmapscan=off; SET pg_fts.lazy_phrase=$arm;"; echo '\timing on'; for i in 1 2 3 4 5 6 7 8; do echo "$SQL;"; done; } > /tmp/pt.sql
  $P -f /tmp/pt.sql > /tmp/pt.out 2>&1
  ts=$(sed -n 's/^Time: \([0-9.]*\) ms.*/\1/p' /tmp/pt.out | tail -8 | tr '\n' ' ')
  med=$(echo "$ts" | tr ' ' '\n' | grep . | tail -5 | sort -n | sed -n 3p)
  echo "lazy=$arm ph=$ph rows=$(grep -v '^Time:' /tmp/pt.out | sort -u | tr '\n' ',') median=$med raw=[$ts]"
 done
done
