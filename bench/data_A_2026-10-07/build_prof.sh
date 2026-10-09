#!/bin/bash
# Where does CREATE INDEX + fts_vacuum time go? Phase timestamps from DEBUG1 lines and segment
# counts, plus a perf profile of the leader during each phase. Plain index, same settings as 1.10.0.
B=/nvme/pgs/bin; P="$B/psql -h /tmp -p 55440 -U postgres -X -q -At"; LOG=/nvme/bench_s/server.log
$P -c "DROP INDEX IF EXISTS docs_fts_b" >/dev/null
$P -c "ALTER SYSTEM SET log_min_messages = debug1" -c "SELECT pg_reload_conf()" >/dev/null
L0=$(wc -l < $LOG)
( $P -c "SELECT pg_backend_pid()" -c "SELECT pg_sleep(0)" >/dev/null )
t0=$(date +%s.%N)
$P -c "SET client_min_messages=warning" -c "CREATE INDEX docs_fts_b ON docs USING fts (d)" &
CPID=$!
sleep 3; LP=$($P -c "SELECT pid FROM pg_stat_activity WHERE query LIKE 'CREATE INDEX docs_fts_b%' AND backend_type='client backend'")
echo "leader pid $LP"
# sample phases: every 20 s, record wait_event + number of parallel workers alive + index size
while kill -0 $CPID 2>/dev/null; do
  echo "t=$(printf %.0f $(echo "$(date +%s.%N)-$t0" | bc)) workers=$($P -c "SELECT count(*) FROM pg_stat_activity WHERE backend_type='parallel worker'") lw=$($P -c "SELECT coalesce(wait_event_type,'-')||':'||coalesce(wait_event,'cpu') FROM pg_stat_activity WHERE pid=$LP") size_mb=$($P -c "SELECT pg_relation_size('docs_fts_b')/1048576")"
  sleep 20
done
t1=$(date +%s.%N); echo "build_s=$(echo "$t1-$t0" | bc) size=$($P -c "SELECT pg_relation_size('docs_fts_b')") nseg=$($P -c "SELECT fts_index_nsegments('docs_fts_b')")"
tail -n +$L0 $LOG | grep -E "pg_fts build|collaps|merge|tier" | sed 's/^.*\(DEBUG\|LOG\): *//' | head -20
t0=$(date +%s.%N); $P -c "SELECT fts_vacuum('docs_fts_b')" >/dev/null; echo "fts_vacuum_s=$(echo "$(date +%s.%N)-$t0" | bc) size=$($P -c "SELECT pg_relation_size('docs_fts_b')")"
$P -c "ALTER SYSTEM RESET log_min_messages" -c "SELECT pg_reload_conf()" >/dev/null
