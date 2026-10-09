#!/bin/bash
# count PrefetchBuffer calls and the readahead-window path during one cold rare-term query
B=/nvme/pgs/bin; P="$B/psql -h /tmp -p 55440 -U postgres -X -q -At"; SO=$($B/pg_config --pkglibdir)/pg_fts.so
$P -c "ALTER SYSTEM SET effective_io_concurrency = 16" >/dev/null
$B/pg_ctl -D /nvme/bench_s -w stop >/dev/null 2>&1; sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
$B/pg_ctl -D /nvme/bench_s -l /nvme/bench_s/server.log -w start >/dev/null
sudo perf probe -d 'probe_*:*' >/dev/null 2>&1
sudo perf probe -x $B/postgres -a PrefetchBuffer >/dev/null 2>&1
sudo perf probe -x $B/postgres -a get_tablespace_io_concurrency >/dev/null 2>&1
sudo perf probe -x $B/postgres -a 'WaitReadBuffers' >/dev/null 2>&1 || sudo perf probe -x $B/postgres -a ReadBuffer_common >/dev/null 2>&1
sudo perf probe -x $B/postgres -a mdprefetch >/dev/null 2>&1
{ echo "SELECT pg_backend_pid();"; echo "SELECT pg_sleep(1);"; echo "SET enable_seqscan=off; SET enable_bitmapscan=off;"; echo "SELECT count(*) FROM (SELECT id FROM docs WHERE d @@@ to_ftsquery('english','slovakia') ORDER BY d <=> to_ftsquery('english','slovakia') LIMIT 10) s;"; } > /tmp/pf.sql
$P -f /tmp/pf.sql > /tmp/pf.out 2>&1 & sleep 0.5; PID=$(head -1 /tmp/pf.out)
sudo perf stat $(sudo perf probe -l 2>/dev/null | awk '{print "-e "$1}' | tr '\n' ' ') -p $PID -- sleep 3 2>&1 | grep probe
wait; sudo perf probe -d 'probe_*:*' >/dev/null 2>&1
$P -c "SHOW effective_io_concurrency"; $P -c "ALTER SYSTEM RESET effective_io_concurrency" >/dev/null
