#!/bin/bash
# Minimal deterministic reproduction attempt for the undercount: sequential, no concurrency.
# Rounds of: insert N into pending, delete some recent + some old, VACUUM; check exactness each round.
set -uo pipefail
B=/nvme/pg17/bin; D=/nvme/uc_${1:-x}; [ -d $D ] && mv $D $D.old.$$
$B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
printf "port=55462\nunix_socket_directories='/tmp'\nlisten_addresses=''\nautovacuum=off\n" >> $D/postgresql.conf
$B/pg_ctl -D $D -l $D/log -w start >/dev/null
P="$B/psql -h /tmp -p 55462 -U postgres -X -q -At"
$P -c "CREATE EXTENSION pg_fts" >/dev/null
echo "so $(md5sum $($B/pg_config --pkglibdir)/pg_fts.so | cut -c1-8)"
$P -c "CREATE TABLE c (id bigserial PRIMARY KEY, d ftsdoc)" -c "INSERT INTO c (d) SELECT to_ftsdoc('simple', 'common w' || (g % 211) || CASE WHEN g % 7 = 0 THEN ' rare' ELSE '' END) FROM generate_series(1, 20000) g" -c "CREATE INDEX c_fts ON c USING fts (d)" -c "VACUUM ANALYZE c" >/dev/null
Q="to_ftsquery('simple','rare')"
for r in $(seq 1 ${ROUNDS:-30}); do
  $P -c "INSERT INTO c (d) SELECT to_ftsdoc('simple', 'common new w' || ((g*7) % 211) || CASE WHEN g % 3 = 0 THEN ' rare' ELSE ' other' END) FROM generate_series(1, ${NINS:-3000}) g" >/dev/null
  $P -c "DELETE FROM c WHERE id IN (SELECT id FROM c ORDER BY id DESC OFFSET 2 LIMIT ${NDELR:-800})" >/dev/null
  $P -c "DELETE FROM c WHERE id IN (SELECT id FROM c WHERE id % 97 = $r LIMIT ${NDELO:-150})" >/dev/null
  $P -c "VACUUM c" >/dev/null
  truth=$($P -c "SELECT count(*) FROM c WHERE fts_match(d, $Q)"); push=$($P -c "SELECT count(*) FROM c WHERE d @@@ $Q")
  bm=$($P -c "SET enable_seqscan=off; SET enable_indexscan=off" -c "SELECT count(*) FROM (SELECT d FROM c WHERE d @@@ $Q OFFSET 0) s")
  nseg=$($P -c "select fts_index_nsegments('c_fts')")
  st=OK; [ "$truth" = "$push" ] && [ "$truth" = "$bm" ] || st=WRONG
  echo "round $r: truth=$truth pushdown=$push bitmap=$bm nseg=$nseg $st"
  [ $st = WRONG ] && [ "${STOP:-1}" = 1 ] && break
done
$B/pg_ctl -D $D -w stop >/dev/null
