#!/bin/bash
# I6: rare-term tps at 16/32/64 clients, same query as the h2h; 2 passes each, -j = min(c,8)
B=/nvme/pgs/bin; export PATH=$B:$PATH; P="psql -h /tmp -p 55440 -U postgres -X -q -At"
$P -c "SELECT 1 FROM pg_class WHERE relname='docs_fts'" | grep -q 1 || { s=$(date +%s); $P -c "CREATE INDEX docs_fts ON docs USING fts (d)"; $P -c "SELECT fts_vacuum('docs_fts')" >/dev/null; echo "rebuilt docs_fts $(( $(date +%s)-s ))s"; }
$P -c "DROP INDEX IF EXISTS docs_fts_pos" 
$P -c "SELECT pg_prewarm('docs'), pg_prewarm('docs_fts')" >/dev/null
Q="SELECT count(*) FROM (SELECT id FROM docs WHERE d @@@ to_ftsquery('english','slovakia') ORDER BY d <=> to_ftsquery('english','slovakia') LIMIT 10) s"
echo "$Q;" > /tmp/w_rare.sql
echo "rows=$($P -c "$Q")"
pgbench -h /tmp -p 55440 -U postgres -n -f /tmp/w_rare.sql -c 8 -j 8 -T 10 postgres >/dev/null 2>&1
for pass in 1 2; do for c in 16 32 64; do j=$(( c < 8 ? c : 8 ))
  tps=$(pgbench -h /tmp -p 55440 -U postgres -n -f /tmp/w_rare.sql -c $c -j $j -T 20 postgres 2>&1 | sed -n 's/^tps = \([0-9.]*\).*/\1/p')
  echo "pass=$pass c=$c tps=$tps"; done; done
