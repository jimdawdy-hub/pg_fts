#!/bin/bash
# usage: ec2scale.sh <185|186> <port> <run> <nrows>
set -u
V=$1; PORT=$2; RUN=$3; N=$4; B=/nvme/pg$V/bin; D=/nvme/data_${V}_$RUN; L=/nvme/res_${V}_$RUN.log
$B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null
cat >> $D/postgresql.conf <<C
port=$PORT
unix_socket_directories='/tmp'
listen_addresses=''
shared_buffers=8GB
maintenance_work_mem=4GB
max_wal_size=32GB
max_parallel_maintenance_workers=0
autovacuum=off
log_min_messages=info
C
$B/pg_ctl -D $D -l $D/server.log -w start >/dev/null
P="$B/psql -h /tmp -p $PORT -U postgres -X -q -At -v ON_ERROR_STOP=1"
t() { local s=$(date +%s.%N); "$@" >/dev/null; echo "$(echo "$(date +%s.%N) - $s" | bc)"; }
# peak RSS (kB) of any backend of THIS cluster, sampled every 1s, reset per phase
pm=$(head -1 $D/postmaster.pid)
peak() { rm -f /nvme/peak_${V}_$RUN; ( m=0; while [ -f /nvme/peakon_${V}_$RUN ]; do
   for c in $(pgrep -P $pm); do r=$(awk '/VmRSS/{print $2}' /proc/$c/status 2>/dev/null); [ -n "$r" ] && [ "$r" -gt "$m" ] && m=$r; done
   echo $m > /nvme/peak_${V}_$RUN; sleep 1; done ) & }
pon() { touch /nvme/peakon_${V}_$RUN; peak; }
poff() { rm -f /nvme/peakon_${V}_$RUN; sleep 2; echo "$(( $(cat /nvme/peak_${V}_$RUN) / 1024 ))MB"; }
q() { for w in w1 w137 w9999 w123456; do
   i=$($P -c "set enable_seqscan=off; select count(*) from docs where to_ftsdoc('simple',body) @@@ to_ftsquery('simple','$w')")
   s=$($P -c "set enable_indexscan=off; set enable_bitmapscan=off; select count(*) from docs where body ~ '(^| )$w( |\$)'")
   [ "$i" = "$s" ] && [ "$i" -gt 0 ] && r=OK || r=MISMATCH; echo -n "$w $i/$s $r | "; done; echo; }
fz() { $P -c "set enable_seqscan=off; select count(*) from docs where to_ftsdoc('simple',body) @@@ to_ftsquery('simple','w12345~1')"; }
{
echo "== arm $V run $RUN rows $N  $(date -u +%FT%TZ)"
$P -c "CREATE EXTENSION pg_fts; select 'extversion='||extversion from pg_extension where extname='pg_fts'"
$P -c "select setseed(0.42);
 CREATE TABLE docs(id bigint primary key, body text);
 INSERT INTO docs SELECT g, (SELECT string_agg('w'||(floor(power(random(),3)*5000000))::int, ' ') FROM generate_series(1,30) WHERE g>0) FROM generate_series(1,$N) g;
 CHECKPOINT;"
echo "load done $(date +%T) rows=$($P -c 'select count(*) from docs')"
pon; bt=$(t $P -c "CREATE INDEX docs_fts ON docs USING fts (to_ftsdoc('simple', body))"); echo "build_s=$bt peak=$(poff)"
echo "stats $($P -c "select nterms, nsegments from fts_index_stats('docs_fts')" 2>/dev/null)"
echo "fuzzy_count=$(fz)"; q
for m in 7 4 3; do
  n=$($P -c "WITH d AS (DELETE FROM docs WHERE id % $m = 0 RETURNING 1) SELECT count(*) FROM d")
  pon; vt=$(t $P -c 'VACUUM docs'); echo "del%$m=$n vacuum_s=$vt peak=$(poff) live=$($P -c 'select count(*) from docs')"
  q
done
pon; echo "fts_merge_s=$(t $P -c "select fts_merge('docs_fts')") peak=$(poff)"
pon; echo "fts_vacuum_s=$(t $P -c "select fts_vacuum('docs_fts')") peak=$(poff)"
echo "fuzzy_count=$(fz)"; q
echo "size=$($P -c "select pg_relation_size('docs_fts')")"
echo DONE
} > $L 2>&1
$B/pg_ctl -D $D -w stop -m fast >/dev/null
