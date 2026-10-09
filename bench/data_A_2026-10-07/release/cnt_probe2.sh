#!/bin/bash
# Isolate the overcount: which deleted docs are still counted after VACUUM?
# Pending-list docs deleted before VACUUM flushes them, vs segment docs deleted.
set -uo pipefail
W=/tmp/upq111; B=$W/${1:-pg111}/bin
D=$W/cp2_$1; [ -d $D ] && mv $D $D.old.$$
$B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
printf "port=55453\nunix_socket_directories='/tmp'\nlisten_addresses=''\n" >> $D/postgresql.conf
$B/pg_ctl -D $D -l $D/log -w start >/dev/null
P="$B/psql -h /tmp -p 55453 -U postgres -X -q -At"
$P -c "CREATE EXTENSION pg_fts" >/dev/null
Q="to_ftsquery('simple','common')"
cnt() { echo "@@@=$($P -c "SELECT count(*) FROM u WHERE d @@@ $Q") fts_match=$($P -c "SELECT count(*) FROM u WHERE fts_match(d, $Q)") idx_nocount=$($P -c "SET enable_seqscan=off" -c "SELECT count(*) FROM (SELECT id FROM u WHERE d @@@ $Q OFFSET 0) s") fts_count=$($P -c "SELECT fts_count('u_fts', $Q)" 2>&1 | tail -1)"; }
for scen in pending_only segment_only; do
  $P -c "DROP TABLE IF EXISTS u" -c "CREATE TABLE u (id bigint, d ftsdoc)" -c "INSERT INTO u SELECT g, to_ftsdoc('simple', 'common w' || (g % 97)) FROM generate_series(1, 20000) g" -c "CREATE INDEX u_fts ON u USING fts (d)" -c "VACUUM ANALYZE u" >/dev/null
  $P -c "INSERT INTO u SELECT g, to_ftsdoc('simple', 'common new ' || g) FROM generate_series(20001, 21000) g" >/dev/null
  if [ $scen = pending_only ]; then $P -c "DELETE FROM u WHERE id > 20000 AND id % 7 = 0" >/dev/null; else $P -c "DELETE FROM u WHERE id <= 20000 AND id % 7 = 0" >/dev/null; fi
  echo "$scen deleted=$($P -c "SELECT 21000 - count(*) FROM u")"
  echo "  before VACUUM: $(cnt)"
  $P -c "VACUUM u" >/dev/null
  echo "  after VACUUM:  $(cnt)  nseg=$($P -c "select fts_index_nsegments('u_fts')")"
  $P -c "VACUUM u" >/dev/null
  echo "  after VACUUM2: $(cnt)"
done
$B/pg_ctl -D $D -w stop >/dev/null
