#!/bin/bash
# final 1.9.1 binary: install, then the release latency bands that the change can touch (+ rare as a control), 3 passes
B=/nvme/pg17/bin; LIB=$($B/pg_config --pkglibdir); D=/nvme/pgdata; P="$B/psql -h /tmp -U postgres -X -q -At -v ON_ERROR_STOP=1"
cd /nvme; [ -d fts191f ] && mv fts191f fts191f.old.$$; tar xzf /tmp/fts191f.tgz; cd fts191f
make -s PG_CONFIG=$B/pg_config -j16 >/dev/null 2>&1 && make -s PG_CONFIG=$B/pg_config install >/dev/null 2>&1 || exit 1
echo "so=$(md5sum $LIB/pg_fts.so | cut -c1-8) dense1_sym=$(nm $LIB/pg_fts.so | grep -c ' fts_search_dense1$')"
$B/pg_ctl -D $D -w stop >/dev/null 2>&1; $B/pg_ctl -D $D -l $D/server.log -w start >/dev/null
IDX=$($P -c "select string_agg(indexrelid::regclass::text, ',') from pg_index where indrelid='docs'::regclass"); echo "indexes=$IDX"
echo "$IDX" | grep -qw docs_fts || { $P -c "CREATE INDEX docs_fts ON docs USING fts (d)"; $P -c "SELECT fts_vacuum('docs_fts')" >/dev/null; }
$P -c "DROP INDEX IF EXISTS docs_fts_pos"; $P -c "SELECT pg_prewarm('docs'), pg_prewarm('docs_fts')" >/dev/null
q() { echo "SELECT count(*) FROM (SELECT id FROM docs WHERE d @@@ to_ftsquery('english','$1') ORDER BY d <=> to_ftsquery('english','$1') LIMIT $2) s"; }
for pass in 1 2 3; do for spec in "common_k10|year|10" "common_k100|year|100" "rare_k10|slovakia|10"; do
  IFS='|' read n t k <<< "$spec"; sql=$(q "$t" $k)
  { echo '\timing on'; for i in 1 2 3 4 5 6 7 8; do echo "$sql;"; done; } > /tmp/b.sql
  $P -f /tmp/b.sql > /tmp/b.out 2>&1
  ts=$(sed -n 's/^Time: \([0-9.]*\) ms.*/\1/p' /tmp/b.out | tail -8 | tr '\n' ' ')
  echo "pass=$pass band=$n rows=$(grep -v '^Time:' /tmp/b.out | sort -u | tr '\n' ',') median_last5=$(echo "$ts" | tr ' ' '\n' | grep . | tail -5 | sort -n | sed -n 3p) raw=[$ts]"
done; done
