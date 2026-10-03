#!/bin/bash
# Same index, same session protocol: two pg_fts query forms for the ranked bands. 3 passes, 8 runs, median of last 5.
set -uo pipefail
OUT=/nvme/out; mkdir -p $OUT; B=/nvme/pg17/bin; P="$B/psql -h /tmp -U postgres -X -q -At -v ON_ERROR_STOP=1"
log() { echo "[$(date -u +%T)] $*" | tee -a $OUT/run.log; }
log "ext $($P -c "CREATE EXTENSION IF NOT EXISTS pg_fts; SELECT extversion FROM pg_extension WHERE extname='pg_fts'")"
$P -c "ALTER TABLE docs ADD COLUMN d ftsdoc; UPDATE docs SET d = to_ftsdoc('english', content);"; $P -c "VACUUM ANALYZE docs"
s=$(date +%s.%N); $P -c "CREATE INDEX docs_fts ON docs USING fts (d)"; log "build_s=$(echo "$(date +%s.%N)-$s"|bc)"
$P -c "SELECT fts_vacuum('docs_fts')" >/dev/null; log "size=$($P -c "select pg_relation_size('docs_fts')")"
$P -c "CREATE EXTENSION IF NOT EXISTS pg_prewarm; SELECT pg_prewarm('docs'), pg_prewarm('docs_fts')" >/dev/null
k() { echo "SELECT count(*) FROM (SELECT id FROM docs WHERE d @@@ to_ftsquery('english','$1') ORDER BY d <=> to_ftsquery('english','$1') LIMIT $2) s"; }
f() { echo "SELECT count(*) FROM fts_search('docs_fts', to_ftsquery('english','$1'), $2)"; }
BANDS=( "knn_rare_k10|$(k slovakia 10)" "knn_mid_k10|$(k hungary 10)" "knn_common_k10|$(k year 10)" "knn_common_k100|$(k year 100)"
        "fs_rare_k10|$(f slovakia 10)" "fs_mid_k10|$(f hungary 10)" "fs_common_k10|$(f year 10)" "fs_common_k100|$(f year 100)"
        "count_common|SELECT count(*) FROM docs WHERE d @@@ to_ftsquery('english','year')" )
for bq in "${BANDS[@]}"; do n=${bq%%|*}; sql=${bq#*|}; { echo "== $n"; $P -c "EXPLAIN $sql"; } >> $OUT/explain.txt 2>&1; done
for pass in 1 2 3; do for bq in "${BANDS[@]}"; do n=${bq%%|*}; sql=${bq#*|}
  { echo '\timing on'; for i in 1 2 3 4 5 6 7 8; do echo "$sql;"; done; } > /tmp/b.sql
  $P -f /tmp/b.sql > /tmp/b.out 2>&1
  ts=$(sed -n 's/^Time: \([0-9.]*\) ms.*/\1/p' /tmp/b.out | tr '\n' ' ')
  med=$(echo "$ts" | tr ' ' '\n' | grep . | tail -5 | sort -n | sed -n 3p)
  echo "pass=$pass band=$n rows=$(grep -v '^Time:' /tmp/b.out | sort -u | tr '\n' ',') median_last5=$med raw=[$ts]" | tee -a $OUT/latency.txt
done; done
log FORM_DONE
