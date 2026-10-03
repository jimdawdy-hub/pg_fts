#!/bin/bash
# re-run only the SET-prefixed bands with SET hoisted out of the timed loop (one SET, then 8 timed queries)
set -uo pipefail
OUT=/nvme/out; B=/nvme/pg17/bin; P="$B/psql -h /tmp -U postgres -X -q -At -v ON_ERROR_STOP=1"
b() { echo "SELECT count(*) FROM (SELECT id FROM docs WHERE content @@ to_tsquery('english','$1') ORDER BY content <@> to_bm25query('$2','docs_pgts') LIMIT 10) s"; }
BANDS=( "and2_k10|$(b 'slovakia & hungary' 'slovakia hungary')" "or2_k10|$(b 'slovakia | hungary' 'slovakia hungary')"
  "or3_k10|$(b 'slovakia | hungary | poland' 'slovakia hungary poland')" "prefix_k10|$(b 'hung:*' 'hung')"
  "phrase_k10|$(b 'united <-> states' 'united states')" )
mv $OUT/latency.txt $OUT/latency_SETmixed.txt
grep -v "band=\(and2\|or2\|or3\|prefix\|phrase\)_k10" $OUT/latency_SETmixed.txt > $OUT/latency.txt
for pass in 1 2 3; do
  for bq in "${BANDS[@]}"; do n=${bq%%|*}; sql=${bq#*|}
    { echo "SET default_text_search_config='english';"; echo '\timing on'; for i in 1 2 3 4 5 6 7 8; do echo "$sql;"; done; } > /tmp/b.sql
    $P -f /tmp/b.sql > /tmp/b.out 2>&1
    nt=$(grep -c '^Time:' /tmp/b.out)
    rows=$(grep -v '^Time:\|NOTICE\|DETAIL' /tmp/b.out | sort -u | tr '\n' ',')
    ts=$(sed -n 's/^Time: \([0-9.]*\) ms.*/\1/p' /tmp/b.out | tr '\n' ' ')
    med=$(echo "$ts" | tr ' ' '\n' | grep . | tail -5 | sort -n | sed -n 3p)
    echo "pass=$pass band=$n rows=$rows ntimes=$nt median_last5=$med raw=[$ts]" | tee -a $OUT/latency.txt
  done
done
echo "[$(date -u +%T)] boolean bands re-run with SET outside the timed loop (first attempt mixed SET timings in)" >> $OUT/run.log
