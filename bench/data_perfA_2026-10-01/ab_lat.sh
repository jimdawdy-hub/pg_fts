#!/bin/bash
# usage: ab_lat.sh <arm> <port> <outfile> [passes]
# Same bands/forms as the 2026-09-30 head-to-head (lat.sh, pg_fts side), 8 runs/session, median of last 5.
set -uo pipefail
ARM=$1; PORT=$2; OUT=$3; NP=${4:-3}; B=/nvme/pg$ARM/bin
P="$B/psql -h /tmp -p $PORT -U postgres -X -q -At -v ON_ERROR_STOP=1"
q() { echo "SELECT count(*) FROM (SELECT id FROM docs WHERE d @@@ to_ftsquery('english','$1') ORDER BY d <=> to_ftsquery('english','$1') LIMIT $2) s"; }
BANDS=(
  "rare_k10|$(q slovakia 10)" "mid_k10|$(q hungary 10)" "common_k10|$(q year 10)" "common_k100|$(q year 100)"
  "count_common|SELECT count(*) FROM docs WHERE d @@@ to_ftsquery('english','year')"
  "and2_k10|$(q 'slovakia & hungary' 10)" "or2_k10|$(q 'slovakia | hungary' 10)"
  "or3_k10|$(q 'slovakia | hungary | poland' 10)" "prefix_k10|$(q 'hung*' 10)"
)
$P -c "SELECT pg_prewarm('docs'), pg_prewarm('docs_fts')" >/dev/null
for pass in $(seq 1 $NP); do
  for bq in "${BANDS[@]}"; do n=${bq%%|*}; sql=${bq#*|}
    { echo "SET enable_seqscan=off;"; echo '\timing on'; for i in 1 2 3 4 5 6 7 8; do echo "$sql;"; done; } > /tmp/ab_$ARM.sql
    $P -f /tmp/ab_$ARM.sql > /tmp/ab_$ARM.out 2>&1
    rows=$(grep -v '^Time:' /tmp/ab_$ARM.out | sort -u | tr '\n' ',')
    ts=$(sed -n 's/^Time: \([0-9.]*\) ms.*/\1/p' /tmp/ab_$ARM.out | tr '\n' ' ')
    med=$(echo "$ts" | tr ' ' '\n' | grep . | tail -5 | sort -n | sed -n 3p)
    echo "arm=$ARM pass=$pass band=$n rows=$rows median_last5=$med raw=[$ts]" >> $OUT
  done
done
