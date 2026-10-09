#!/bin/bash
# At-scale churn for the 1.11.0 bulkdelete change (pending flush inside bulkdelete).
# 300k docs, autovacuum ON with aggressive settings; 8 writer sessions insert + delete
# (rows land in pending and many are deleted before the next vacuum), 4 reader sessions run
# ranked + count + bitmap queries, manual VACUUM / fts_merge interleaved; then the index must
# agree with the heap exactly: count, bitmap row set, and no row without the term returned.
set -uo pipefail
B=/nvme/pg17/bin; D=/nvme/churn_${TAGN:-x}; [ -d $D ] && mv $D $D.old.$$
SRC=${SRC:-/nvme/fts_gate}
if [ "$SRC" = rel110 ]; then cd /nvme; [ -d pg_fts-1.10.0 ] || unzip -qo /tmp/pg_fts-1.10.0.zip; SRC=/nvme/pg_fts-1.10.0; fi
cd $SRC && make -s PG_CONFIG=$B/pg_config -j16 >/dev/null 2>&1 && make -s PG_CONFIG=$B/pg_config install >/dev/null 2>&1
$B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
cat >> $D/postgresql.conf <<C
port=55460
unix_socket_directories='/tmp'
listen_addresses=''
shared_buffers=4GB
max_connections=100
autovacuum=on
autovacuum_naptime=1s
autovacuum_vacuum_threshold=50
autovacuum_vacuum_scale_factor=0.01
autovacuum_vacuum_insert_threshold=200
autovacuum_vacuum_insert_scale_factor=0.0
log_min_messages=warning
C
$B/pg_ctl -D $D -l $D/log -w start >/dev/null
P="$B/psql -h /tmp -p 55460 -U postgres -X -q -At"
$P -c "CREATE EXTENSION pg_fts" -c "CREATE EXTENSION fuzzystrmatch" >/dev/null 2>&1
echo "so $(md5sum $($B/pg_config --pkglibdir)/pg_fts.so | cut -c1-8)"
$P -c "CREATE TABLE c (id bigserial PRIMARY KEY, d ftsdoc)" >/dev/null
$P -c "INSERT INTO c (d) SELECT to_ftsdoc('simple', 'common w' || (g % 211) || CASE WHEN g % 7 = 0 THEN ' rare' ELSE '' END || ' ' || repeat('pad ', g % 17)) FROM generate_series(1, 300000) g" >/dev/null
$P -c "CREATE INDEX c_fts ON c USING fts (d)" -c "VACUUM ANALYZE c" >/dev/null
echo "built: $($P -c "select count(*) from c") rows nseg=$($P -c "select fts_index_nsegments('c_fts')")"
cat > /tmp/w.sql <<'W'
\set k random(1, 1000000000)
INSERT INTO c (d) SELECT to_ftsdoc('simple', 'common new w' || ((:k + g) % 211) || CASE WHEN g % 3 = 0 THEN ' rare' ELSE ' other' END) FROM generate_series(1, 5) g;
DELETE FROM c WHERE id IN (SELECT id FROM c ORDER BY id DESC OFFSET 2 LIMIT 2);
DELETE FROM c WHERE id = (SELECT (random() * 300000)::bigint + 1);
W
cat > /tmp/r.sql <<'R'
SELECT count(*) FROM (SELECT id FROM c WHERE d @@@ to_ftsquery('simple','rare') ORDER BY d <=> to_ftsquery('simple','rare') LIMIT 10) s;
SELECT count(*) FROM c WHERE d @@@ to_ftsquery('simple','rare & w5');
SELECT count(*) FROM (SELECT id FROM c WHERE d @@@ to_ftsquery('simple','common & rare') ORDER BY d <=> to_ftsquery('simple','common & rare') LIMIT 20) s;
R
$B/pgbench -h /tmp -p 55460 -U postgres -n -f /tmp/w.sql -c 8 -j 8 -T ${DUR:-300} postgres > /tmp/w_${TAGN:-x}.out 2>&1 &
WP=$!
$B/pgbench -h /tmp -p 55460 -U postgres -n -f /tmp/r.sql -c 4 -j 4 -T ${DUR:-300} postgres > /tmp/r_${TAGN:-x}.out 2>&1 &
RP=$!
for i in $(seq 1 $(( ${DUR:-300} / 30 ))); do sleep 25; $P -c "VACUUM c" >/dev/null 2>>/tmp/maint_${TAGN:-x}.err; [ $((i % 3)) = 0 ] && $P -c "SELECT fts_merge('c_fts')" >/dev/null 2>>/tmp/maint_${TAGN:-x}.err; done
wait $WP; wait $RP
echo "writers: $(grep -E 'number of transactions actually processed|failed|tps =' /tmp/w_${TAGN:-x}.out | tr '\n' ' ')"
echo "readers: $(grep -E 'number of transactions actually processed|failed|tps =' /tmp/r_${TAGN:-x}.out | tr '\n' ' ')"
echo "maintenance errors: $(wc -l < /tmp/maint_${TAGN:-x}.err)"; head -3 /tmp/maint_${TAGN:-x}.err
echo "server log ERROR/PANIC lines: $(grep -cE 'ERROR|PANIC|FATAL' $D/log)"; grep -E 'ERROR|PANIC' $D/log | sort | uniq -c | sort -rn | head -5
# settle: one more insert batch into pending, delete some of it, VACUUM, then compare exactly
$P -c "INSERT INTO c (d) SELECT to_ftsdoc('simple', 'common late ' || g || CASE WHEN g % 2 = 0 THEN ' rare' ELSE '' END) FROM generate_series(1, 2000) g" >/dev/null
$P -c "DELETE FROM c WHERE id IN (SELECT id FROM c ORDER BY id DESC LIMIT 700)" >/dev/null
$P -c "VACUUM c" >/dev/null
for t in common rare 'rare & w5' 'common & rare'; do
  Q="to_ftsquery('simple','$t')"
  truth=$($P -c "SELECT count(*) FROM c WHERE fts_match(d, $Q)")
  push=$($P -c "SELECT count(*) FROM c WHERE d @@@ $Q")
  bm=$($P -c "SET enable_seqscan=off; SET enable_indexscan=off" -c "SELECT count(*)||'/'||count(*) FILTER (WHERE NOT fts_match(d, $Q)) FROM (SELECT d FROM c WHERE d @@@ $Q OFFSET 0) s")
  rk=$($P -c "SET enable_seqscan=off; SET enable_bitmapscan=off" -c "SELECT count(*)||'/'||count(*) FILTER (WHERE NOT fts_match(d, $Q)) FROM (SELECT d FROM c WHERE d @@@ $Q ORDER BY d <=> $Q LIMIT 1000) s")
  echo "[$t] truth=$truth pushdown=$push $([ "$truth" = "$push" ] && echo OK || echo WRONG) bitmap(rows/nonmatching)=$bm $([ "$bm" = "$truth/0" ] && echo OK || echo WRONG) ranked1000(rows/nonmatching)=$rk"
done
echo "index size $($P -c "select pg_size_pretty(pg_relation_size('c_fts'))") nseg=$($P -c "select fts_index_nsegments('c_fts')")"
$B/pg_ctl -D $D -w stop >/dev/null
echo CHURN_DONE
