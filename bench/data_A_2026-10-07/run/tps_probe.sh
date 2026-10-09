#!/bin/bash
B=/nvme/pg17/bin; D=/nvme/pgdata; LIB=$($B/pg_config --pkglibdir); P="$B/psql -h /tmp -U postgres -X -q -At"
echo "SELECT count(*) FROM (SELECT id FROM docs WHERE d @@@ to_ftsquery('english','slovakia') ORDER BY d <=> to_ftsquery('english','slovakia') LIMIT 10) s;" > /tmp/w.sql
for arm in 110 a; do
  $B/pg_ctl -D $D -w stop >/dev/null 2>&1; cp /nvme/pg_fts_$arm.so $LIB/pg_fts.so; $B/pg_ctl -D $D -l $D/server.log -w start >/dev/null
  $P -c "SELECT pg_prewarm('docs'), pg_prewarm('docs_idx')" >/dev/null
  $B/pgbench -h /tmp -U postgres -n -f /tmp/w.sql -c 8 -j 8 -T 10 postgres >/dev/null 2>&1
  for opt in none pgoptions none pgoptions; do
    if [ $opt = pgoptions ]; then export PGOPTIONS="-c enable_seqscan=off -c enable_bitmapscan=off"; else unset PGOPTIONS; fi
    echo "arm=$arm $opt rare c16 tps=$($B/pgbench -h /tmp -U postgres -n -f /tmp/w.sql -c 16 -j 8 -T 20 postgres 2>&1 | sed -n 's/^tps = \([0-9.]*\).*/\1/p')"
  done
  unset PGOPTIONS
done
