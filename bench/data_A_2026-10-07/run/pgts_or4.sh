#!/bin/bash
B=/nvme/pg17/bin; P="$B/psql -h /tmp -U postgres -X -q -At"; OUT=/nvme/out
sql="SELECT count(*) FROM (SELECT id FROM docs ORDER BY content <@> to_bm25query('film music album band','docs_idx') LIMIT 10) s"
for pass in 1 2 3; do
  { echo "SET statement_timeout = '300s'; SET default_text_search_config = 'english';"; echo '\timing on'; for i in 1 2 3 4 5 6 7 8; do echo "$sql;"; done; } > /tmp/b.sql
  $P -f /tmp/b.sql > /tmp/b.out 2>&1
  ts=$(sed -n 's/^Time: \([0-9.]*\) ms.*/\1/p' /tmp/b.out | tail -8 | tr '\n' ' ')
  echo "pass=$pass band=or4_k10 rows=$(grep -v '^Time:' /tmp/b.out | sort -u | tr '\n' ',') median_last5=$(echo "$ts" | tr ' ' '\n' | grep . | tail -5 | sort -n | sed -n 3p) raw=[$ts]" | tee -a $OUT/latency_extra.txt
done
