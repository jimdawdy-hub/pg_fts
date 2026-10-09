#!/bin/bash
# Count after: rows inserted (pending) then some deleted, VACUUM, fts_merge, fts_vacuum.
# True count from a function-call filter (fts_match(d,q): no operator, so no count pushdown).
# usage: cnt_probe.sh <pg110|pg111>
set -uo pipefail
W=/tmp/upq111; B=$W/$1/bin
D=$W/cp_$1; [ -d $D ] && mv $D $D.old.$$
$B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
printf "port=55452\nunix_socket_directories='/tmp'\nlisten_addresses=''\n" >> $D/postgresql.conf
$B/pg_ctl -D $D -l $D/log -w start >/dev/null
P="$B/psql -h /tmp -p 55452 -U postgres -X -q -At"
$P -c "CREATE EXTENSION pg_fts" >/dev/null
echo "ext $($P -c "SELECT extversion FROM pg_extension WHERE extname='pg_fts'") so $(md5sum $W/$1/lib/postgresql/pg_fts.so | cut -c1-8)"
$P -c "CREATE TABLE u (id bigint, d ftsdoc)" -c "INSERT INTO u SELECT g, to_ftsdoc('simple', 'common w' || (g % 97)) FROM generate_series(1, 20000) g" >/dev/null
$P -c "CREATE INDEX u_fts ON u USING fts (d)" -c "VACUUM ANALYZE u" >/dev/null
Q="to_ftsquery('simple','common')"
show() {
  idx=$($P -c "SELECT count(*) FROM u WHERE d @@@ $Q")
  fn=$($P -c "SELECT count(*) FROM u WHERE fts_match(d, $Q)")
  plan=$($P -c "EXPLAIN (COSTS OFF) SELECT count(*) FROM u WHERE d @@@ $Q" | tr '\n' ' ' | cut -c1-90)
  echo "  $1: @@@ count=$idx  fts_match count=$fn  $([ "$idx" = "$fn" ] && echo OK || echo WRONG)  nseg=$($P -c "select fts_index_nsegments('u_fts')") plan=[$plan]"
}
show "after build"
$P -c "INSERT INTO u SELECT g, to_ftsdoc('simple', 'common new ' || g) FROM generate_series(20001, 21000) g" >/dev/null
show "after insert (pending)"
$P -c "DELETE FROM u WHERE id % 7 = 0" >/dev/null
show "after delete"
$P -c "VACUUM u" >/dev/null
show "after VACUUM"
$P -c "SELECT fts_merge('u_fts')" >/dev/null
show "after fts_merge"
$P -c "SELECT fts_vacuum('u_fts')" >/dev/null
show "after fts_vacuum"
$P -c "REINDEX INDEX u_fts" >/dev/null
show "after REINDEX"
$B/pg_ctl -D $D -w stop >/dev/null
