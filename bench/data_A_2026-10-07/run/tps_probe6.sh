#!/bin/bash
# count_common: a3 66.2-66.4k vs the earlier arm-a binary (c9c4079c) 72.1-73.0k. Same session, alternating.
B=/nvme/pg17/bin; D=/nvme/pgdata; LIB=$($B/pg_config --pkglibdir); P="$B/psql -h /tmp -U postgres -X -q -At"
[ -f /nvme/pg_fts_apre.so ] || cp /nvme/fts_a.old.38085/pg_fts.so /nvme/pg_fts_apre.so
echo "SELECT count(*) FROM docs WHERE d @@@ to_ftsquery('english','year');" > /tmp/wc.sql
echo "SELECT count(*) FROM (SELECT id FROM docs WHERE d @@@ to_ftsquery('english','slovakia') ORDER BY d <=> to_ftsquery('english','slovakia') LIMIT 10) s;" > /tmp/wr.sql
for r in 1 2 3; do for arm in apre a3 a4; do
  $B/pg_ctl -D $D -w stop >/dev/null 2>&1; cp /nvme/pg_fts_$arm.so $LIB/pg_fts.so; $B/pg_ctl -D $D -l $D/server.log -w start >/dev/null
  $P -c "SELECT pg_prewarm('docs'), pg_prewarm('docs_idx')" >/dev/null
  $B/pgbench -h /tmp -U postgres -n -f /tmp/wc.sql -c 8 -j 8 -T 5 postgres >/dev/null 2>&1
  c=$($B/pgbench -h /tmp -U postgres -n -f /tmp/wc.sql -c 16 -j 8 -T 20 postgres 2>&1 | sed -n 's/^tps = \([0-9.]*\).*/\1/p')
  w=$($B/pgbench -h /tmp -U postgres -n -f /tmp/wr.sql -c 16 -j 8 -T 20 postgres 2>&1 | sed -n 's/^tps = \([0-9.]*\).*/\1/p')
  echo "r=$r arm=$arm count c16=$c rare c16=$w"
done; done
