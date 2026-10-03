#!/bin/bash
# pg_textsearch: resume after index build -- same bands/protocol as lat.sh minus count_common (seqscan plan, 251 s/run).
set -uo pipefail
OUT=/nvme/out; B=/nvme/pg17/bin; P="$B/psql -h /tmp -U postgres -X -q -At -v ON_ERROR_STOP=1"
log() { echo "[$(date -u +%T)] $*" | tee -a $OUT/run.log; }
q() { echo "SELECT count(*) FROM (SELECT id FROM docs ORDER BY content <@> to_bm25query('$1','docs_pgts') LIMIT $2) s"; }
b() { echo "SET default_text_search_config='english'; SELECT count(*) FROM (SELECT id FROM docs WHERE content @@ to_tsquery('english','$1') ORDER BY content <@> to_bm25query('$2','docs_pgts') LIMIT 10) s"; }
BANDS=(
  "rare_k10|$(q slovakia 10)" "mid_k10|$(q hungary 10)" "common_k10|$(q year 10)" "common_k100|$(q year 100)"
  "and2_k10|$(b 'slovakia & hungary' 'slovakia hungary')" "or2_k10|$(b 'slovakia | hungary' 'slovakia hungary')"
  "or3_k10|$(b 'slovakia | hungary | poland' 'slovakia hungary poland')" "prefix_k10|$(b 'hung:*' 'hung')"
  "phrase_k10|$(b 'united <-> states' 'united states')"
)
for t in slovakia hungary year; do
  $P -c "SELECT string_agg(id::text, ',' ORDER BY r) FROM (SELECT id, row_number() over () r FROM (SELECT id FROM docs ORDER BY content <@> to_bm25query('$t','docs_pgts') LIMIT 10) a) b" | sed "s/^/top10 $t /" >> $OUT/top10.txt
done
for pass in 1 2 3; do
  for bq in "${BANDS[@]}"; do n=${bq%%|*}; sql=${bq#*|}
    { echo '\timing on'; for i in 1 2 3 4 5 6 7 8; do echo "$sql;"; done; } > /tmp/b.sql
    $P -f /tmp/b.sql > /tmp/b.out 2>&1
    rows=$(grep -v '^Time:\|^SET$\|NOTICE\|DETAIL' /tmp/b.out | sort -u | tr '\n' ',')
    ts=$(sed -n 's/^Time: \([0-9.]*\) ms.*/\1/p' /tmp/b.out | tail -8 | tr '\n' ' ')
    med=$(echo "$ts" | tr ' ' '\n' | grep . | tail -5 | sort -n | sed -n 3p)
    echo "pass=$pass band=$n rows=$rows median_last5=$med raw=[$ts]" | tee -a $OUT/latency.txt
  done
done
log LAT_DONE
