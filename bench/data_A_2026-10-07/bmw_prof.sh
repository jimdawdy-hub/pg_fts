#!/bin/bash
B=/nvme/pgs/bin; P="$B/psql -h /tmp -p 55440 -U postgres -X -q -At"
sql="SELECT count(*) FROM (SELECT id FROM docs WHERE d @@@ to_ftsquery('english','united | states') ORDER BY d <=> to_ftsquery('english','united | states') LIMIT 10) s"
{ echo "SET enable_seqscan=off; SET enable_bitmapscan=off; SELECT pg_backend_pid();"; echo "SELECT pg_sleep(1.5);"; for i in $(seq 1 300); do echo "$sql;"; done; } > /tmp/pp.sql
$P -f /tmp/pp.sql > /tmp/pp.out 2>&1 &
sleep 0.7; PID=$(head -1 /tmp/pp.out)
sudo perf record -F 2999 -g -p $PID -o /tmp/pbmw.data -- sleep 3 >/dev/null 2>&1
wait
sudo perf report -i /tmp/pbmw.data --no-children --sort sym --stdio -g none 2>/dev/null | grep -E "^ +[0-9]" | head -10
# count wand_load_block calls per query via uprobe
SO=$($B/pg_config --pkglibdir)/pg_fts.so
sudo perf probe -d 'probe_pg_fts:*' >/dev/null 2>&1; sudo perf probe -x $SO -a wand_load_block >/dev/null 2>&1; sudo perf probe -x $SO -a wand_seek >/dev/null 2>&1
{ echo "SET enable_seqscan=off; SET enable_bitmapscan=off; SELECT pg_backend_pid();"; echo "SELECT pg_sleep(1);"; for i in $(seq 1 20); do echo "$sql;"; done; } > /tmp/pp2.sql
$P -f /tmp/pp2.sql > /tmp/pp2.out 2>&1 & sleep 0.5; PID=$(head -1 /tmp/pp2.out)
sudo perf stat -e probe_pg_fts:wand_load_block -e probe_pg_fts:wand_seek -p $PID -- sleep 4 2>&1 | grep probe_pg_fts
wait; sudo perf probe -d 'probe_pg_fts:*' >/dev/null 2>&1
