#!/bin/bash
B=/nvme/pgs/bin; LIB=$($B/pg_config --pkglibdir); P="$B/psql -h /tmp -p 55440 -U postgres -X -q -At"
SB0=$($P -c "SHOW shared_buffers")
$P -c "ALTER SYSTEM SET shared_buffers = '4GB'" >/dev/null
$B/pg_ctl -D /nvme/bench_s -w restart -l /nvme/bench_s/server.log >/dev/null
$P -c "SELECT pg_prewarm('docs_fts')" >/dev/null
$P -c "DROP INDEX IF EXISTS docs_fts_b" >/dev/null 2>&1
$P -c "SET client_min_messages = warning" -c "CREATE INDEX docs_fts_b ON docs USING fts (d)" >/dev/null
$P -c "SELECT coalesce(c.relname, b.relfilenode::text) rel, count(*) pages FROM pg_buffercache b LEFT JOIN pg_class c ON c.relfilenode = b.relfilenode WHERE b.relfilenode IS NOT NULL GROUP BY 1 ORDER BY 2 DESC LIMIT 6"
$P -c "SELECT pg_relation_size('docs')/8192 heap_pages, (SELECT pg_relation_size(reltoastrelid)/8192 FROM pg_class WHERE relname='docs') toast_pages"
$P -c "ALTER SYSTEM SET shared_buffers = '$SB0'" >/dev/null; $B/pg_ctl -D /nvme/bench_s -w restart -l /nvme/bench_s/server.log >/dev/null
