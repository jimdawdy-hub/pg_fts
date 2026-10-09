#!/bin/bash
B=/nvme/pg17/bin; P="$B/psql -h /tmp -U postgres -X -q -At"
echo "SELECT count(*) FROM (SELECT id FROM docs WHERE d @@@ to_ftsquery('english','slovakia') ORDER BY d <=> to_ftsquery('english','slovakia') LIMIT 10) s;" > /tmp/w.sql
$P -c "SELECT pg_prewarm('docs'), pg_prewarm('docs_idx')" >/dev/null
for r in 1 2; do
  for opt in "" "-c default_text_search_config=english" "-c enable_seqscan=off -c enable_bitmapscan=off"; do
    export PGOPTIONS="$opt"
    echo "arm=a PGOPTIONS=[$opt] rare c16 tps=$($B/pgbench -h /tmp -U postgres -n -f /tmp/w.sql -c 16 -j 8 -T 20 postgres 2>&1 | sed -n 's/^tps = \([0-9.]*\).*/\1/p')"
  done
done
unset PGOPTIONS
$P -c "SHOW default_text_search_config"
PGOPTIONS="-c default_text_search_config=english" $P -c "EXPLAIN (ANALYZE, BUFFERS, SUMMARY) SELECT count(*) FROM (SELECT id FROM docs WHERE d @@@ to_ftsquery('english','slovakia') ORDER BY d <=> to_ftsquery('english','slovakia') LIMIT 10) s" | grep -E "Planning|Execution"
$P -c "EXPLAIN (ANALYZE, BUFFERS, SUMMARY) SELECT count(*) FROM (SELECT id FROM docs WHERE d @@@ to_ftsquery('english','slovakia') ORDER BY d <=> to_ftsquery('english','slovakia') LIMIT 10) s" | grep -E "Planning|Execution"
