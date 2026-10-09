#!/bin/bash
B=/nvme/pg17/bin; D=/nvme/pgdata; LIB=$($B/pg_config --pkglibdir); P="$B/psql -h /tmp -U postgres -X -q -At"
echo "SELECT count(*) FROM (SELECT id FROM docs WHERE d @@@ to_ftsquery('english','slovakia') ORDER BY d <=> to_ftsquery('english','slovakia') LIMIT 10) s;" > /tmp/w.sql
for arm in 110 a; do
  $B/pg_ctl -D $D -w stop >/dev/null 2>&1; cp /nvme/pg_fts_$arm.so $LIB/pg_fts.so; $B/pg_ctl -D $D -l $D/server.log -w start >/dev/null
  $P -c "SELECT pg_prewarm('docs'), pg_prewarm('docs_idx')" >/dev/null
  echo "arm=$arm shared_doclen=$($P -c "SHOW pg_fts.shared_doclen") doclen_cache_mb=$($P -c "SHOW pg_fts.doclen_cache_mb")"
  $B/pgbench -h /tmp -U postgres -n -f /tmp/w.sql -c 16 -j 8 -T 10 postgres >/dev/null 2>&1
  echo "  stats: $($P -c "SELECT * FROM fts_shared_doclen_stats()" 2>&1 | head -3 | tr '\n' ' ')"
  echo "  1 client: $($B/pgbench -h /tmp -U postgres -n -f /tmp/w.sql -c 1 -j 1 -T 15 postgres 2>&1 | sed -n 's/^\(latency average = [0-9.]* ms\).*/\1/p; s/^tps = \([0-9.]*\).*/tps=\1/p' | tr '\n' ' ')"
  echo "  16 clients: $($B/pgbench -h /tmp -U postgres -n -f /tmp/w.sql -c 16 -j 8 -T 15 postgres 2>&1 | sed -n 's/^\(latency average = [0-9.]* ms\).*/\1/p; s/^tps = \([0-9.]*\).*/tps=\1/p' | tr '\n' ' ')"
done
uptime; nproc
