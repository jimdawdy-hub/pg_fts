#!/bin/bash
# hcp: index already built by the first conc2 run; warm + EXPLAIN + 2 underload passes, no count band
set -uo pipefail
OUT=/nvme/out; B=/nvme/pg17/bin; P="$B/psql -h /tmp -U postgres -X -q -At -v ON_ERROR_STOP=1"; export PATH=$B:$PATH
log() { echo "[$(date -u +%T)] $*" | tee -a $OUT/run.log; }
sed -i '/^ALL_DONE$/d' $OUT/run.log
log "resume: count_common omitted for pgts (seqscan plan); conc2.sh's band loop died on the unset var (set -u)"
export BAND_rare_k10="SELECT count(*) FROM (SELECT id FROM docs ORDER BY content <@> to_bm25query('slovakia','docs_pgts') LIMIT 10) s"
export BAND_common_k10="SELECT count(*) FROM (SELECT id FROM docs ORDER BY content <@> to_bm25query('year','docs_pgts') LIMIT 10) s"
export PGOPTIONS="-c default_text_search_config=english"
$P -c "SELECT pg_prewarm('docs'), pg_prewarm('docs_pgts')" | tee -a $OUT/run.log
for b in rare_k10 common_k10; do v=BAND_$b; printf '%s\n' "${!v}" > /tmp/w.sql; pgbench -h /tmp -U postgres -n -f /tmp/w.sql -c 8 -j 8 -T 10 postgres >/dev/null 2>&1; done
mpstat 5 > $OUT/mpstat.txt 2>&1 & MP=$!
for pass in 1 2; do
  CLIENTS="16 32 64" LOAD_SECS=30 BANDS="rare_k10 common_k10" bash /tmp/underload.sh "host=/tmp user=postgres dbname=postgres" pgts $OUT/underload_pass$pass.json 2>&1 | tee -a $OUT/run.log
done
kill $MP; log CONC_DONE; echo ALL_DONE >> $OUT/run.log
