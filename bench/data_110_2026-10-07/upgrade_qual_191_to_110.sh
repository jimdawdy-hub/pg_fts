#!/bin/bash
# In-place upgrade qualification for pg_fts 1.10.0: an index BUILT by released
# 1.9.1 (with tombstones) is opened by the 1.10.0 binary on the same data dir,
# with no REINDEX; then ALTER EXTENSION UPDATE; then write activity on 1.10.0.
# At each step: index count == seqscan count, and fts_search top-20 scores ==
# the heap-side fts_bm25 reference (exactness, including the idf clamp).
set -uo pipefail
cd /nvme
for d in pg191 pg110; do [ -d $d ] || cp -a /nvme/pg17 /nvme/$d; done
[ -d /nvme/pg_fts-1.10.0 ] && mv /nvme/pg_fts-1.10.0 /nvme/pg_fts-1.10.0.old.$$
unzip -qo /tmp/pg_fts-1.10.0.zip
(cd pg_fts-1.10.0 && make -s PG_CONFIG=/nvme/pg110/bin/pg_config -j16 >/dev/null 2>&1 && make -s PG_CONFIG=/nvme/pg110/bin/pg_config install >/dev/null 2>&1) || { echo BUILD110_FAIL; exit 1; }
[ -d /nvme/pg_fts-1.9.1 ] && mv /nvme/pg_fts-1.9.1 /nvme/pg_fts-1.9.1.old.$$
unzip -qo /tmp/pg_fts-1.9.1.zip
(cd pg_fts-1.9.1 && make -s PG_CONFIG=/nvme/pg191/bin/pg_config -j16 >/dev/null 2>&1 && make -s PG_CONFIG=/nvme/pg191/bin/pg_config install >/dev/null 2>&1) || { echo BUILD191_FAIL; exit 1; }
echo "1.9.1 so: $(md5sum /nvme/pg191/lib/postgresql/pg_fts.so | cut -c1-8)  1.10.0 so: $(md5sum /nvme/pg110/lib/postgresql/pg_fts.so | cut -c1-8)"
D=/nvme/upg110; [ -d $D ] && mv $D $D.old.$$
/nvme/pg191/bin/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
printf "port=55439\nunix_socket_directories='/tmp'\nlisten_addresses=''\nshared_buffers=4GB\nmaintenance_work_mem=2GB\n" >> $D/postgresql.conf
/nvme/pg191/bin/pg_ctl -D $D -l $D/log -w start >/dev/null
P="/nvme/pg191/bin/psql -h /tmp -p 55439 -U postgres -X -q -At"
echo "built with ext $($P -c "CREATE EXTENSION pg_fts" -c "SELECT extversion FROM pg_extension WHERE extname='pg_fts'")"
$P -c "CREATE TABLE u (id bigint, d ftsdoc)" -c "INSERT INTO u (id) SELECT g FROM generate_series(1, 300000) g" >/dev/null
$P -c "UPDATE u SET d = to_ftsdoc('simple', 'w' || (id % 97) || ' x' || (id % 13) || ' ' || repeat('pad ', (id % 31)::int) || CASE WHEN id % 5 = 0 THEN 'rare' ELSE 'common' END)" >/dev/null
$P -c "VACUUM FULL u" -c "CREATE INDEX u_fts ON u USING fts (d)" -c "VACUUM ANALYZE u" >/dev/null
$P -c "DELETE FROM u WHERE id % 3 = 0" -c "VACUUM u" >/dev/null
echo "1.9.1 built + deleted: nseg=$($P -c "select fts_index_nsegments('u_fts')") live=$($P -c "select count(*) from u")"
/nvme/pg191/bin/pg_ctl -D $D -w stop >/dev/null

/nvme/pg110/bin/pg_ctl -D $D -l $D/log -w start >/dev/null
P="/nvme/pg110/bin/psql -h /tmp -p 55439 -U postgres -X -q -At"
echo "1.10.0 binary started; ext SQL still $($P -c "select extversion from pg_extension where extname='pg_fts'")"
chk() {
  for t in common rare 'common | rare' w5; do
    Q="to_ftsquery('simple','$t')"
    read N A < <($P -F" " -c "SELECT ndocs, avgdl FROM fts_index_stats('u_fts')")
    fs=$($P -c "SELECT string_agg(round(score::numeric,8)::text, ',' ORDER BY score DESC) FROM fts_search('u_fts', $Q, 20)" | tail -1)
    ref=$($P -c "SET enable_indexscan=off; SET enable_bitmapscan=off; SELECT string_agg(round(s::numeric,8)::text, ',') FROM (SELECT fts_bm25(d, $Q, $N, $A, fts_index_df('u_fts', $Q)) s FROM u WHERE d @@@ $Q ORDER BY 1 DESC LIMIT 20) z" | tail -1)
    cnt=$($P -c "SET enable_seqscan=off; SELECT count(*) FROM u WHERE d @@@ $Q"); truth=$($P -c "SET enable_indexscan=off; SET enable_bitmapscan=off; SELECT count(*) FROM u WHERE d @@@ $Q")
    ob=$($P -c "SET enable_seqscan=off; SET enable_bitmapscan=off; SELECT count(*) FROM (SELECT 1 FROM u WHERE d @@@ $Q ORDER BY d <=> $Q LIMIT 20) s")
    echo "  $1 [$t]: count $cnt/$truth $([ "$cnt" = "$truth" ] && echo OK || echo BAD) | top20 == heap ref $([ -n "$fs" ] && [ "$fs" = "$ref" ] && echo OK || echo DIFF) | orderby rows=$ob"
  done
}
chk "1.10.0 .so, 1.9.1 SQL"
$P -c "ALTER EXTENSION pg_fts UPDATE TO '1.10.0'" >/dev/null; echo "after ALTER: ext $($P -c "select extversion from pg_extension where extname='pg_fts'")"
chk "after ALTER EXTENSION"
$P -c "INSERT INTO u SELECT g, to_ftsdoc('simple','common new' || g) FROM generate_series(300001, 310000) g" >/dev/null
$P -c "DELETE FROM u WHERE id % 7 = 0" -c "VACUUM u" >/dev/null
$P -c "SELECT fts_merge('u_fts')" >/dev/null; $P -c "SELECT fts_vacuum('u_fts')" >/dev/null
echo "after insert+delete+vacuum+merge on 1.10.0: nseg=$($P -c "select fts_index_nsegments('u_fts')")"
chk "after 1.10.0 writes"
/nvme/pg110/bin/pg_ctl -D $D -w stop >/dev/null
echo UPG_DONE
