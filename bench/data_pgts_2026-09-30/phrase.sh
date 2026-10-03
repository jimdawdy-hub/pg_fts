#!/bin/bash
# pg_fts only: rebuild WITH (positions=on) and measure phrase, same 8-run protocol, 3 passes.
set -uo pipefail
OUT=$1; B=/nvme/pg17/bin; P="$B/psql -h /tmp -U postgres -X -q -At -v ON_ERROR_STOP=1"
log() { echo "[$(date -u +%T)] $*" | tee -a $OUT/run.log; }
$P -c "DROP INDEX docs_fts"
s=$(date +%s.%N); $P -c "CREATE INDEX docs_fts_pos ON docs USING fts (d) WITH (positions = on)"; log "pos_build_s=$(echo "$(date +%s.%N)-$s"|bc)"
$P -c "SELECT fts_vacuum('docs_fts_pos')" >/dev/null; log "pos_size=$($P -c "select pg_relation_size('docs_fts_pos')")"
$P -c "SELECT pg_prewarm('docs_fts_pos')" >/dev/null
SQL="SELECT count(*) FROM (SELECT id FROM docs WHERE d @@@ to_ftsquery('english','\"united states\"') ORDER BY d <=> to_ftsquery('english','\"united states\"') LIMIT 10) s"
log "phrase df=$($P -c "SELECT count(*) FROM docs WHERE d @@@ to_ftsquery('english','\"united states\"')") regex=$($P -c "SELECT count(*) FROM docs WHERE content ~* '\\munited\\s+states\\M'")"
$P -c "EXPLAIN $SQL" >> $OUT/explain.txt
for pass in 1 2 3; do
  { echo '\timing on'; for i in 1 2 3 4 5 6 7 8; do echo "$SQL;"; done; } > /tmp/b.sql
  $P -f /tmp/b.sql > /tmp/b.out 2>&1
  ts=$(sed -n 's/^Time: \([0-9.]*\) ms.*/\1/p' /tmp/b.out | tail -8 | tr '\n' ' ')
  med=$(echo "$ts" | tr ' ' '\n' | grep . | tail -5 | sort -n | sed -n 3p)
  echo "pass=$pass band=phrase_k10_poson rows=$(grep -v '^Time:' /tmp/b.out | sort -u | tr '\n' ',') median_last5=$med raw=[$ts]" | tee -a $OUT/latency.txt
done
log PHRASE_DONE
