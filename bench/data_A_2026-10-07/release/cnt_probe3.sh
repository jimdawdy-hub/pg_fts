#!/bin/bash
# Severity: after the pending-delete VACUUM, insert rows WITHOUT the term so they reuse the freed
# heap slots; does any index path return them as matches for 'common'?
set -uo pipefail
W=/tmp/upq111; B=$W/${1:-pg111}/bin
D=$W/cp3_$1; [ -d $D ] && mv $D $D.old.$$
$B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
printf "port=55454\nunix_socket_directories='/tmp'\nlisten_addresses=''\n" >> $D/postgresql.conf
$B/pg_ctl -D $D -l $D/log -w start >/dev/null
P="$B/psql -h /tmp -p 55454 -U postgres -X -q -At"
$P -c "CREATE EXTENSION pg_fts" >/dev/null
echo "so $(md5sum $W/$1/lib/postgresql/pg_fts.so | cut -c1-8)"
Q="to_ftsquery('simple','common')"
$P -c "CREATE TABLE u (id bigint, d ftsdoc) WITH (fillfactor = 100)" -c "INSERT INTO u SELECT g, to_ftsdoc('simple', 'common w' || (g % 97)) FROM generate_series(1, 20000) g" -c "CREATE INDEX u_fts ON u USING fts (d)" -c "VACUUM ANALYZE u" >/dev/null
$P -c "INSERT INTO u SELECT g, to_ftsdoc('simple', 'common new ' || g) FROM generate_series(20001, 21000) g" >/dev/null
$P -c "DELETE FROM u WHERE id > 20000" >/dev/null
$P -c "VACUUM u" >/dev/null
# reuse the freed slots with rows that do NOT contain 'common'
$P -c "INSERT INTO u SELECT g, to_ftsdoc('simple', 'other ' || g) FROM generate_series(30001, 31000) g" >/dev/null
echo "rows with 'other' (no 'common'): $($P -c "SELECT count(*) FROM u WHERE id > 30000")"
echo "truth (fts_match): $($P -c "SELECT count(*) FROM u WHERE fts_match(d, $Q)")"
echo "bitmap scan:  $($P -c "SET enable_seqscan=off; SET enable_indexscan=off" -c "SELECT count(*), count(*) FILTER (WHERE id > 30000) FROM (SELECT id FROM u WHERE d @@@ $Q OFFSET 0) s")"
echo "index scan:   $($P -c "SET enable_seqscan=off; SET enable_bitmapscan=off" -c "SELECT count(*), count(*) FILTER (WHERE id > 30000) FROM (SELECT id FROM u WHERE d @@@ $Q OFFSET 0) s")"
echo "ranked k=21000: $($P -c "SET enable_seqscan=off; SET enable_bitmapscan=off" -c "SELECT count(*), count(*) FILTER (WHERE id > 30000) FROM (SELECT id FROM u WHERE d @@@ $Q ORDER BY d <=> $Q LIMIT 21000) s")"
echo "fts_count: $($P -c "SELECT fts_count('u_fts', $Q)")   count(*) pushdown: $($P -c "SELECT count(*) FROM u WHERE d @@@ $Q")"
$P -c "VACUUM u" >/dev/null
echo "after a 2nd VACUUM: truth $($P -c "SELECT count(*) FROM u WHERE fts_match(d, $Q)") bitmap $($P -c "SET enable_seqscan=off; SET enable_indexscan=off" -c "SELECT count(*), count(*) FILTER (WHERE id > 30000) FROM (SELECT id FROM u WHERE d @@@ $Q OFFSET 0) s") pushdown $($P -c "SELECT count(*) FROM u WHERE d @@@ $Q")"
$B/pg_ctl -D $D -w stop >/dev/null
