#!/bin/bash
# isolate: index built by arm 110 (+fts_vacuum) vs by arm a; each binary on each index; rare c16
B=/nvme/pg17/bin; D=/nvme/pgdata; LIB=$($B/pg_config --pkglibdir); P="$B/psql -h /tmp -U postgres -X -q -At"
use() { $B/pg_ctl -D $D -w stop >/dev/null 2>&1; cp /nvme/pg_fts_$1.so $LIB/pg_fts.so; $B/pg_ctl -D $D -l $D/server.log -w start >/dev/null; }
use 110
$P -c "DROP INDEX IF EXISTS docs_idx110" >/dev/null 2>&1
$P -c "SET client_min_messages=warning" -c "CREATE INDEX docs_idx110 ON docs USING fts (d)" -c "SELECT fts_vacuum('docs_idx110')" >/dev/null
echo "docs_idx110 size=$($P -c "select pg_relation_size('docs_idx110')") docs_idx size=$($P -c "select pg_relation_size('docs_idx')")"
for ix in docs_idx docs_idx110; do other=$([ $ix = docs_idx ] && echo docs_idx110 || echo docs_idx)
  $P -c "UPDATE pg_index SET indisvalid = false WHERE indexrelid = '$other'::regclass" -c "UPDATE pg_index SET indisvalid = true WHERE indexrelid = '$ix'::regclass" >/dev/null
  for arm in 110 a 110 a; do use $arm
    $P -c "SELECT pg_prewarm('docs'), pg_prewarm('$ix')" >/dev/null
    echo "SELECT count(*) FROM (SELECT id FROM docs WHERE d @@@ to_ftsquery('english','slovakia') ORDER BY d <=> to_ftsquery('english','slovakia') LIMIT 10) s;" > /tmp/w.sql
    $B/pgbench -h /tmp -U postgres -n -f /tmp/w.sql -c 8 -j 8 -T 10 postgres >/dev/null 2>&1
    echo "index=$ix arm=$arm rare c16 tps=$($B/pgbench -h /tmp -U postgres -n -f /tmp/w.sql -c 16 -j 8 -T 20 postgres 2>&1 | sed -n 's/^tps = \([0-9.]*\).*/\1/p') plan=$($P -c "EXPLAIN (COSTS OFF) SELECT id FROM docs WHERE d @@@ to_ftsquery('english','slovakia') ORDER BY d <=> to_ftsquery('english','slovakia') LIMIT 10" | grep -o "using [a-z_0-9]*")"
  done
done
$P -c "UPDATE pg_index SET indisvalid = true WHERE indexrelid = 'docs_idx'::regclass" -c "DROP INDEX docs_idx110" >/dev/null
