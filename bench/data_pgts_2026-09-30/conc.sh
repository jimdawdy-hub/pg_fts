#!/bin/bash
# Concurrency: pgbench 16/32/64 clients, 30 s per (band, clients), -j=min(c,8). C1X query forms.
# usage: conc.sh <fts|pgts> <outdir>
set -uo pipefail
ENG=$1; OUT=$2; mkdir -p $OUT
B=/nvme/pg17/bin; P="$B/psql -h /tmp -U postgres -X -q -At -v ON_ERROR_STOP=1"; export PATH=$B:$PATH
log() { echo "[$(date -u +%T)] $*" | tee -a $OUT/run.log; }
log "engine=$ENG pg=$($B/postgres --version) nproc=$(nproc) physcores=$(lscpu -p=core | grep -v '#' | sort -u | wc -l)"
if [ "$ENG" = fts ]; then
  log "ext $($P -c "CREATE EXTENSION IF NOT EXISTS pg_fts; SELECT extversion FROM pg_extension WHERE extname='pg_fts'")"
  $P -c "ALTER TABLE docs ADD COLUMN d ftsdoc; UPDATE docs SET d = to_ftsdoc('english', content);"; $P -c "VACUUM ANALYZE docs"
  s=$(date +%s.%N); $P -c "CREATE INDEX docs_fts ON docs USING fts (d)"; log "build_s=$(echo "$(date +%s.%N)-$s"|bc)"
  $P -c "SELECT fts_vacuum('docs_fts')" >/dev/null; log "size=$($P -c "select pg_relation_size('docs_fts')")"; IDX=docs_fts
  export BAND_rare_k10="SELECT count(*) FROM (SELECT id FROM docs WHERE d @@@ to_ftsquery('english','slovakia') ORDER BY d <=> to_ftsquery('english','slovakia') LIMIT 10) s"
  export BAND_common_k10="SELECT count(*) FROM (SELECT id FROM docs WHERE d @@@ to_ftsquery('english','year') ORDER BY d <=> to_ftsquery('english','year') LIMIT 10) s"
  export BAND_count_common="SELECT count(*) FROM docs WHERE d @@@ to_ftsquery('english','year')"
else
  log "ext $($P -c "CREATE EXTENSION IF NOT EXISTS pg_textsearch; SELECT extversion FROM pg_extension WHERE extname='pg_textsearch'")"
  $P -c "VACUUM ANALYZE docs"
  s=$(date +%s.%N); $P -c "CREATE INDEX docs_pgts ON docs USING bm25(content) WITH (text_config='english')" 2>&1 | grep -v "too long"; log "build_s=$(echo "$(date +%s.%N)-$s"|bc)"
  log "size=$($P -c "select pg_relation_size('docs_pgts')")"; IDX=docs_pgts
  export BAND_rare_k10="SELECT count(*) FROM (SELECT id FROM docs ORDER BY content <@> to_bm25query('slovakia','docs_pgts') LIMIT 10) s"
  export BAND_common_k10="SELECT count(*) FROM (SELECT id FROM docs ORDER BY content <@> to_bm25query('year','docs_pgts') LIMIT 10) s"
  # NEW since C1X: pg_textsearch 1.x has @@ boolean filtering, so count is now measurable
  export BAND_count_common="SELECT count(*) FROM docs WHERE content @@ to_tsquery('english','year')"
  export PGOPTIONS="-c default_text_search_config=english"
fi
$P -c "CREATE EXTENSION IF NOT EXISTS pg_prewarm; SELECT pg_prewarm('docs'), pg_prewarm('$IDX')" | tee -a $OUT/run.log
for b in rare_k10 common_k10 count_common; do v=BAND_$b
  echo "== $b" >> $OUT/explain.txt; $P -c "EXPLAIN ${!v}" >> $OUT/explain.txt 2>&1
  log "result $b=$($P -c "${!v}")"
  printf '%s\n' "${!v}" > /tmp/w.sql; pgbench -h /tmp -U postgres -n -f /tmp/w.sql -c 8 -j 8 -T 10 postgres >/dev/null 2>&1   # warm
done
mpstat 5 > $OUT/mpstat.txt 2>&1 & MP=$!
for pass in 1 2; do
  CLIENTS="16 32 64" LOAD_SECS=30 BANDS="rare_k10 common_k10 count_common" \
    bash /tmp/underload.sh "host=/tmp user=postgres dbname=postgres" "$ENG" $OUT/underload_pass$pass.json 2>&1 | tee -a $OUT/run.log
done
kill $MP
log CONC_DONE
