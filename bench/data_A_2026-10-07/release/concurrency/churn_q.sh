#!/bin/bash
# Which concurrency ingredient triggers it? Same churn, variants (DUR=120 each):
#  A: writers only, autovacuum OFF, no manual maintenance; check at end after one VACUUM
#  B: writers + autovacuum, no readers
#  C: writers + readers, autovacuum OFF, manual VACUUM only
B=/nvme/pg17/bin
for v in ${VARIANTS:-A B C}; do
  D=/nvme/cq_$v; [ -d $D ] && mv $D $D.old.$$
  $B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
  AV=on; [ $v = A ] && AV=off; [ $v = C ] && AV=off; [ $v = D ] && AV=off
  printf "port=55461\nunix_socket_directories='/tmp'\nlisten_addresses=''\nshared_buffers=4GB\nmax_connections=100\nautovacuum=$AV\nautovacuum_naptime=1s\nautovacuum_vacuum_threshold=50\nautovacuum_vacuum_scale_factor=0.01\nautovacuum_vacuum_insert_threshold=200\nautovacuum_vacuum_insert_scale_factor=0.0\n" >> $D/postgresql.conf
  $B/pg_ctl -D $D -l $D/log -w start >/dev/null
  P="$B/psql -h /tmp -p 55461 -U postgres -X -q -At"
  $P -c "CREATE EXTENSION pg_fts" >/dev/null
  $P -c "CREATE TABLE c (id bigserial PRIMARY KEY, d ftsdoc)" -c "INSERT INTO c (d) SELECT to_ftsdoc('simple', 'common w' || (g % 211) || CASE WHEN g % 7 = 0 THEN ' rare' ELSE '' END || ' ' || repeat('pad ', g % 17)) FROM generate_series(1, 300000) g" -c "CREATE INDEX c_fts ON c USING fts (d)" -c "VACUUM ANALYZE c" >/dev/null
  $B/pgbench -h /tmp -p 55461 -U postgres -n -f /tmp/w.sql -c 8 -j 8 -T 120 postgres > /tmp/cq_w_$v.out 2>&1 &
  WP=$!
  RP=""
  if [ $v = C ]; then $B/pgbench -h /tmp -p 55461 -U postgres -n -f /tmp/r.sql -c 4 -j 4 -T 120 postgres > /tmp/cq_r_$v.out 2>&1 & RP=$!; fi
  if [ $v = C ]; then for i in 1 2 3 4; do sleep 25; $P -c "VACUUM c" >/dev/null 2>>/tmp/cq_m_$v.err; done; fi
  # D: writers only, manual VACUUM every 25 s (no readers, no autovacuum)
  if [ $v = D ]; then for i in 1 2 3 4; do sleep 25; $P -c "VACUUM c" >/dev/null 2>>/tmp/cq_m_$v.err; done; fi
  wait $WP; [ -n "$RP" ] && wait $RP
  $P -c "VACUUM c" >/dev/null 2>>/tmp/cq_m_$v.err
  Q="to_ftsquery('simple','rare')"
  truth=$($P -c "SELECT count(*) FROM c WHERE fts_match(d, $Q)"); push=$($P -c "SELECT count(*) FROM c WHERE d @@@ $Q")
  bm=$($P -c "SET enable_seqscan=off; SET enable_indexscan=off" -c "SELECT count(*)||'/'||count(*) FILTER (WHERE NOT fts_match(d, $Q)) FROM (SELECT d FROM c WHERE d @@@ $Q OFFSET 0) s" 2>&1 | tail -1)
  echo "variant $v (autovac=$AV): truth=$truth pushdown=$push bitmap=$bm  errors=$(grep -cE 'ERROR' $D/log) $(grep -E 'ERROR' $D/log | grep -v canceling | sed 's/^.*ERROR: *//; s/[0-9]\+/N/g' | sort -u | head -2 | tr '\n' ';')"
  $B/pg_ctl -D $D -w stop >/dev/null
done
