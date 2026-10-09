#!/bin/bash
# arm 110 rare c16 three times in a row, each after its own restart+prewarm+settle: is it bimodal?
B=/nvme/pg17/bin; D=/nvme/pgdata; LIB=$($B/pg_config --pkglibdir); P="$B/psql -h /tmp -U postgres -X -q -At"
echo "SELECT count(*) FROM (SELECT id FROM docs WHERE d @@@ to_ftsquery('english','slovakia') ORDER BY d <=> to_ftsquery('english','slovakia') LIMIT 10) s;" > /tmp/w.sql
for r in 1 2 3; do for arm in 110 a; do
  $B/pg_ctl -D $D -w stop >/dev/null 2>&1; cp /nvme/pg_fts_$arm.so $LIB/pg_fts.so; $B/pg_ctl -D $D -l $D/server.log -w start >/dev/null
  $P -c "CHECKPOINT" >/dev/null; sync; sleep 20; $P -c "SELECT pg_prewarm('docs'), pg_prewarm('docs_idx')" >/dev/null
  $B/pgbench -h /tmp -U postgres -n -f /tmp/w.sql -c 8 -j 8 -T 10 postgres >/dev/null 2>&1
  t=$($B/pgbench -h /tmp -U postgres -n -f /tmp/w.sql -c 16 -j 8 -T 30 postgres 2>&1 | sed -n 's/^tps = \([0-9.]*\).*/\1/p')
  echo "r=$r arm=$arm rare c16 tps=$t shdl=$($P -c "SELECT count(*) FROM fts_shared_doclen_stats()" 2>/dev/null)"
done; done
