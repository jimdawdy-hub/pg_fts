#!/bin/bash
# Is bm25_flush_pending racing concurrent inserts? Insert-only writers, a loop of fts_merge()
# (which flushes the pending list), NO deletes, NO vacuum.  Then: index count vs heap.
set -uo pipefail
B=/nvme/pg17/bin; D=/nvme/race_${1:-x}; [ -d $D ] && mv $D $D.old.$$
$B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
printf "port=55463\nunix_socket_directories='/tmp'\nlisten_addresses=''\nautovacuum=off\nmax_connections=50\n" >> $D/postgresql.conf
$B/pg_ctl -D $D -l $D/log -w start >/dev/null
P="$B/psql -h /tmp -p 55463 -U postgres -X -q -At"
$P -c "CREATE EXTENSION pg_fts" >/dev/null
echo "so $(md5sum $($B/pg_config --pkglibdir)/pg_fts.so | cut -c1-8)"
$P -c "CREATE TABLE c (id bigserial PRIMARY KEY, d ftsdoc)" -c "INSERT INTO c (d) SELECT to_ftsdoc('simple', 'common w' || (g % 211)) FROM generate_series(1, 20000) g" -c "CREATE INDEX c_fts ON c USING fts (d)" -c "VACUUM ANALYZE c" >/dev/null
echo "INSERT INTO c (d) SELECT to_ftsdoc('simple', 'common new ' || g) FROM generate_series(1, 5) g;" > /tmp/ri.sql
$B/pgbench -h /tmp -p 55463 -U postgres -n -f /tmp/ri.sql -c 8 -j 8 -T ${DUR:-60} postgres > /tmp/ri_$1.out 2>&1 &
WP=$!
n=0; while kill -0 $WP 2>/dev/null; do $P -c "SELECT fts_merge('c_fts')" >/dev/null 2>&1; n=$((n+1)); sleep 0.2; done
wait $WP
Q="to_ftsquery('simple','common')"
truth=$($P -c "SELECT count(*) FROM c WHERE fts_match(d, $Q)"); heap=$($P -c "SELECT count(*) FROM c")
push=$($P -c "SELECT count(*) FROM c WHERE d @@@ $Q")
bm=$($P -c "SET enable_seqscan=off; SET enable_indexscan=off" -c "SELECT count(*) FROM (SELECT d FROM c WHERE d @@@ $Q OFFSET 0) s")
echo "fts_merge calls=$n heap=$heap truth=$truth pushdown=$push bitmap=$bm missing=$((truth - bm)) $([ "$truth" = "$bm" ] && [ "$truth" = "$push" ] && echo OK || echo WRONG)"
$B/pg_ctl -D $D -w stop >/dev/null
