#!/bin/bash
# Same data, same settings: index size + per-band counts/top-20 after CREATE INDEX (which now
# compacts), after deletes + VACUUM, and after fts_merge, for 39b6a42 (the benchmarked binary)
# and the release HEAD.
W=/tmp/upq111
for v in pgA pg111; do
  D=$W/sz_$v; [ -d $D ] && mv $D $D.old.$$
  $W/$v/bin/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
  printf "port=55470\nunix_socket_directories='/tmp'\nlisten_addresses=''\nshared_buffers=1GB\nmaintenance_work_mem=256MB\nautovacuum=off\n" >> $D/postgresql.conf
  $W/$v/bin/pg_ctl -D $D -l $D/log -w start >/dev/null
  P="$W/$v/bin/psql -h /tmp -p 55470 -U postgres -X -q -At"
  $P -c "CREATE EXTENSION pg_fts" -c "CREATE TABLE u (id bigint, t text)" >/dev/null
  $P -c "INSERT INTO u SELECT g, 'w' || (g % 97) || ' x' || (g % 13) || ' ' || repeat('pad ', (g % 31)::int) || CASE WHEN g % 5 = 0 THEN 'rare' ELSE 'common' END || CASE WHEN g % 11 = 0 THEN ' hot dog' ELSE '' END FROM generate_series(1, 600000) g" >/dev/null
  $P -c "CREATE INDEX u_fts ON u USING fts (to_ftsdoc('simple', t))" >/dev/null
  s1=$($P -c "select pg_relation_size('u_fts')")
  $P -c "DELETE FROM u WHERE id % 4 = 0" -c "VACUUM u" >/dev/null; s2=$($P -c "select pg_relation_size('u_fts')")
  $P -c "SELECT fts_merge('u_fts')" >/dev/null; s3=$($P -c "select pg_relation_size('u_fts')")
  r=""; for q in rare common "rare & w5" "w1 | w2 | w3 | rare" '"hot dog"'; do
    c=$($P -c "select count(*) from u where to_ftsdoc('simple',t) @@@ '$q'::ftsquery")
    k=$($P -c "select md5(string_agg(id::text, ',' order by s desc, id)) from (select id, to_ftsdoc('simple',t) <=> '$q'::ftsquery s from u where to_ftsdoc('simple',t) @@@ '$q'::ftsquery order by to_ftsdoc('simple',t) <=> '$q'::ftsquery limit 20) z" | cut -c1-8)
    r="$r [$q] $c/$k"; done
  echo "$v so=$(md5sum $W/$v/lib/postgresql/pg_fts.so | cut -c1-8) build=$s1 vacuum=$s2 merge=$s3 |$r"
  $W/$v/bin/pg_ctl -D $D -w stop >/dev/null
done
