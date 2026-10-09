#!/bin/bash
# perf the CREATE INDEX leader during the serial merge phase (after the 7 flushes), 40 s sample
B=/nvme/pgs/bin; P="$B/psql -h /tmp -p 55440 -U postgres -X -q -At"
$P -c "DROP INDEX IF EXISTS docs_fts_b" >/dev/null
$P -c "SET client_min_messages=warning" -c "CREATE INDEX docs_fts_b ON docs USING fts (d)" >/dev/null &
CPID=$!; sleep 2
LP=$($P -c "SELECT pid FROM pg_stat_activity WHERE query LIKE 'CREATE INDEX docs_fts_b%' AND backend_type='client backend'")
# wait until workers gone (merge phase)
while [ "$($P -c "SELECT count(*) FROM pg_stat_activity WHERE backend_type='parallel worker'")" != 0 ]; do sleep 2; done
sleep 30
sudo perf record -F 999 -g -p $LP -o /tmp/mp.data -- sleep 40 >/dev/null 2>&1
sudo perf report -i /tmp/mp.data --no-children --sort sym --stdio -g none 2>/dev/null | grep -E "^ +[0-9]" | head -22
echo ---- callers
sudo perf report -i /tmp/mp.data --children --sort sym --stdio -g none 2>/dev/null | grep -E "^ +[0-9]" | grep -E "bm25|fts_|merge|Write|Read|smgr|mdwrite|pwrite|XLog|log_newpage" | head -25
wait $CPID
