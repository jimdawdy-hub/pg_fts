#!/bin/bash
# the protocol's additional ranked bands for the competitor engines (each engine's native form)
# usage: extra_bands.sh <pgts|psearch|vchord> <outdir>   run after lat3.sh (index docs_idx exists)
set -uo pipefail
ENG=$1; OUT=$2; B=/nvme/pg17/bin; P="$B/psql -h /tmp -U postgres -X -q -At"
case $ENG in
pgts)
  b() { echo "SELECT count(*) FROM (SELECT id FROM docs WHERE content @@ to_tsquery('english','$1') ORDER BY content <@> to_bm25query('$2','docs_idx') LIMIT 10) s"; }
  r() { echo "SELECT count(*) FROM (SELECT id FROM docs ORDER BY content <@> to_bm25query('$1','docs_idx') LIMIT 10) s"; }
  BANDS=("and_common_k10|$(b 'united & states' 'united states')" "and_ww_k10|$(b 'world & war' 'world war')"
         "phrase_ww_k10|$(b 'world <-> war' 'world war')" "or4_k10|$(r 'film music album band')") ;;
psearch)
  BANDS=("and_common_k10|SELECT count(*) FROM (SELECT id FROM docs WHERE content &&& 'united states' ORDER BY pdb.score(id) DESC LIMIT 10) s"
         "and_ww_k10|SELECT count(*) FROM (SELECT id FROM docs WHERE content &&& 'world war' ORDER BY pdb.score(id) DESC LIMIT 10) s"
         "phrase_ww_k10|SELECT count(*) FROM (SELECT id FROM docs WHERE content ### 'world war' ORDER BY pdb.score(id) DESC LIMIT 10) s"
         "or4_k10|SELECT count(*) FROM (SELECT id FROM docs WHERE content ||| 'film music album band' ORDER BY pdb.score(id) DESC LIMIT 10) s") ;;
vchord)
  BANDS=("or4_k10|SELECT count(*) FROM (SELECT id FROM docs ORDER BY emb <&> to_bm25query('docs_idx', tokenize('film music album band', 'en')) LIMIT 10) s") ;;
esac
$P -c "SELECT pg_prewarm('docs'), pg_prewarm('docs_idx')" >/dev/null
for pass in 1 2 3; do
  for bq in "${BANDS[@]}"; do n=${bq%%|*}; sql=${bq#*|}
    { echo "SET statement_timeout = '300s'; SET default_text_search_config = 'english';"; echo '\timing on'; for i in 1 2 3 4 5 6 7 8; do echo "$sql;"; done; } > /tmp/b.sql
    $P -f /tmp/b.sql > /tmp/b.out 2>&1
    rows=$(grep -v '^Time:' /tmp/b.out | sort -u | tr '\n' ',')
    grep -q "statement timeout" /tmp/b.out && rows="TIMEOUT(300s)"
    ts=$(sed -n 's/^Time: \([0-9.]*\) ms.*/\1/p' /tmp/b.out | tail -8 | tr '\n' ' ')
    med=$(echo "$ts" | tr ' ' '\n' | grep . | tail -5 | sort -n | sed -n 3p)
    echo "pass=$pass band=$n rows=$rows median_last5=$med raw=[$ts]" | tee -a $OUT/latency_extra.txt
  done
done
echo EXTRA_DONE
