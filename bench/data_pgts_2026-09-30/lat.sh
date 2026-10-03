#!/bin/bash
# Single-client latency, 8 runs per query inside ONE psql session, median of runs 4-8.
# usage: lat.sh <fts|pgts> <outdir>     (expects docs(id,content) loaded, server up)
set -uo pipefail
ENG=$1; OUT=$2; mkdir -p $OUT
B=/nvme/pg17/bin; P="$B/psql -h /tmp -U postgres -X -q -At -v ON_ERROR_STOP=1"
log() { echo "[$(date -u +%T)] $*" | tee -a $OUT/run.log; }
log "engine=$ENG host=$(hostname) pg=$($B/postgres --version)"

if [ "$ENG" = fts ]; then
  log "ext $($P -c "CREATE EXTENSION IF NOT EXISTS pg_fts; SELECT extversion FROM pg_extension WHERE extname='pg_fts'")"
  md5sum /nvme/pg17/lib/postgresql/pg_fts.so | tee -a $OUT/run.log
  s=$(date +%s.%N); $P -c "ALTER TABLE docs ADD COLUMN d ftsdoc; UPDATE docs SET d = to_ftsdoc('english', content);"; log "materialize_d_s=$(echo "$(date +%s.%N)-$s"|bc)"
  $P -c "VACUUM ANALYZE docs"
  s=$(date +%s.%N); $P -c "CREATE INDEX docs_fts ON docs USING fts (d)"; log "build_s=$(echo "$(date +%s.%N)-$s"|bc)"
  log "size_after_build=$($P -c "select pg_relation_size('docs_fts')")"
  s=$(date +%s.%N); $P -c "SELECT fts_vacuum('docs_fts')" >/dev/null; log "fts_vacuum_s=$(echo "$(date +%s.%N)-$s"|bc)"
  log "size=$($P -c "select pg_relation_size('docs_fts')") nseg=$($P -c "select nsegments from fts_index_stats('docs_fts')")"
  IDX=docs_fts
  q() { echo "SELECT count(*) FROM (SELECT id FROM docs WHERE d @@@ to_ftsquery('english','$1') ORDER BY d <=> to_ftsquery('english','$1') LIMIT $2) s"; }
  BANDS=(
    "rare_k10|$(q slovakia 10)"
    "mid_k10|$(q hungary 10)"
    "common_k10|$(q year 10)"
    "common_k100|$(q year 100)"
    "count_common|SELECT count(*) FROM docs WHERE d @@@ to_ftsquery('english','year')"
    "and2_k10|$(q 'slovakia & hungary' 10)"
    "or2_k10|$(q 'slovakia | hungary' 10)"
    "or3_k10|$(q 'slovakia | hungary | poland' 10)"
    "prefix_k10|$(q 'hung*' 10)"
  )
  DFQ() { $P -c "SELECT count(*) FROM docs WHERE d @@@ to_ftsquery('english','$1')"; }
else
  log "ext $($P -c "CREATE EXTENSION IF NOT EXISTS pg_textsearch; SELECT extversion FROM pg_extension WHERE extname='pg_textsearch'")"
  (cd /nvme/pg_textsearch && git log -1 --format='commit %H %ad' --date=short) | tee -a $OUT/run.log
  $P -c "VACUUM ANALYZE docs"
  s=$(date +%s.%N); $P -c "CREATE INDEX docs_pgts ON docs USING bm25(content) WITH (text_config='english')" 2>&1 | grep -v "too long" | tee -a $OUT/run.log; log "build_s=$(echo "$(date +%s.%N)-$s"|bc)"
  log "size=$($P -c "select pg_relation_size('docs_pgts')")"
  IDX=docs_pgts
  q() { echo "SELECT count(*) FROM (SELECT id FROM docs ORDER BY content <@> to_bm25query('$1','docs_pgts') LIMIT $2) s"; }
  # boolean forms: NEW in pg_textsearch 1.x -- @@ filter + standalone score + sort (its README: "not yet optimized")
  b() { echo "SET default_text_search_config='english'; SELECT count(*) FROM (SELECT id FROM docs WHERE content @@ to_tsquery('english','$1') ORDER BY content <@> to_bm25query('$2','docs_pgts') LIMIT 10) s"; }
  BANDS=(
    "rare_k10|$(q slovakia 10)"
    "mid_k10|$(q hungary 10)"
    "common_k10|$(q year 10)"
    "common_k100|$(q year 100)"
    "count_common|SET default_text_search_config='english'; SELECT count(*) FROM docs WHERE content @@ to_tsquery('english','year')"
    "and2_k10|$(b 'slovakia & hungary' 'slovakia hungary')"
    "or2_k10|$(b 'slovakia | hungary' 'slovakia hungary')"
    "or3_k10|$(b 'slovakia | hungary | poland' 'slovakia hungary poland')"
    "prefix_k10|$(b 'hung:*' 'hung')"
    "phrase_k10|$(b 'united <-> states' 'united states')"
  )
  DFQ() { $P -c "SET default_text_search_config='english'; SELECT count(*) FROM docs WHERE content @@ to_tsquery('english','$1')" | tail -1; }
fi
$P -c "CREATE EXTENSION IF NOT EXISTS pg_prewarm; SELECT pg_prewarm('docs'), pg_prewarm('$IDX')" | tee -a $OUT/run.log

# match counts + regex ground truth (the fairness check)
for t in slovakia hungary year; do log "df $t=$(DFQ $t)"; done
for t in slovakia hungary; do log "regex $t=$($P -c "SELECT count(*) FROM docs WHERE content ~* '\\m$t\\M'")"; done
log "regex years?=$($P -c "SELECT count(*) FROM docs WHERE content ~* '\\myears?\\M'")"

# top-10 ids per ranked band, for cross-engine comparison
for t in slovakia hungary year; do
  if [ "$ENG" = fts ]; then $P -c "SELECT string_agg(id::text, ',' ORDER BY r) FROM (SELECT id, row_number() over () r FROM (SELECT id FROM docs WHERE d @@@ to_ftsquery('english','$t') ORDER BY d <=> to_ftsquery('english','$t') LIMIT 10) a) b"
  else $P -c "SELECT string_agg(id::text, ',' ORDER BY r) FROM (SELECT id, row_number() over () r FROM (SELECT id FROM docs ORDER BY content <@> to_bm25query('$t','docs_pgts') LIMIT 10) a) b"; fi | sed "s/^/top10 $t /" >> $OUT/top10.txt
done

# EXPLAIN every band once (index use must be confirmed, not assumed)
for bq in "${BANDS[@]}"; do n=${bq%%|*}; sql=${bq#*|}
  { echo "== $n"; $P -c "$(echo "$sql" | sed 's/SELECT count(\*) FROM (SELECT/EXPLAIN SELECT count(*) FROM (SELECT/; s/^SELECT count(\*) FROM docs/EXPLAIN SELECT count(*) FROM docs/; s/; SELECT count(\*) FROM docs/; EXPLAIN SELECT count(*) FROM docs/; s/; SELECT count(\*) FROM (SELECT/; EXPLAIN SELECT count(*) FROM (SELECT/')"; } >> $OUT/explain.txt 2>&1
done

# 3 independent passes (rule 3: an arm must reproduce itself), each a fresh session
for pass in 1 2 3; do
  for bq in "${BANDS[@]}"; do n=${bq%%|*}; sql=${bq#*|}
    { echo '\timing on'; for i in 1 2 3 4 5 6 7 8; do echo "$sql;"; done; } > /tmp/b.sql
    $P -f /tmp/b.sql > /tmp/b.out 2>&1
    rows=$(grep -v '^Time:\|^SET$' /tmp/b.out | sort -u | tr '\n' ',')
    ts=$(sed -n 's/^Time: \([0-9.]*\) ms.*/\1/p' /tmp/b.out | grep -v '^$')
    # drop SET timings: keep the last 8 numbers
    ts=$(echo "$ts" | tail -8 | tr '\n' ' ')
    med=$(echo "$ts" | tr ' ' '\n' | grep . | tail -5 | sort -n | sed -n 3p)
    echo "pass=$pass band=$n rows=$rows median_last5=$med raw=[$ts]" | tee -a $OUT/latency.txt
  done
done
log LAT_DONE
