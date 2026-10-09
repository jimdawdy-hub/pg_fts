#!/bin/bash
# count bm25_doclen_cursor_lookup calls per rare-term query via a uprobe
SO=/nvme/pgs/lib/postgresql/pg_fts.so; B=/nvme/pgs/bin
sudo perf probe -d 'probe_pg_fts:*' >/dev/null 2>&1
sudo perf probe -x $SO -a bm25_doclen_cursor_lookup 2>&1 | tail -1
sudo perf probe -x $SO -a bm25_topk_visible 2>&1 | tail -1
Q=$(cat /tmp/w_rare.sql)
{ echo "SELECT pg_backend_pid();"; echo "SELECT pg_sleep(1.5);"; for i in $(seq 1 50); do echo "$Q"; done; } > /tmp/cq.sql
$B/psql -h /tmp -p 55440 -U postgres -X -q -At -f /tmp/cq.sql > /tmp/cq.out 2>&1 &
sleep 0.5; PID=$(head -1 /tmp/cq.out)
sudo perf stat -e probe_pg_fts:bm25_doclen_cursor_lookup -e probe_pg_fts:bm25_topk_visible -p $PID -- sleep 4 2>&1 | grep probe_pg_fts
wait
$B/psql -h /tmp -p 55440 -U postgres -X -At -c "SELECT fts_count('docs_fts', to_ftsquery('english','slovakia'))" -c "SELECT ndocs FROM fts_index_stats('docs_fts')" -c "SELECT fts_index_nsegments('docs_fts')"
sudo perf probe -d 'probe_pg_fts:*' >/dev/null 2>&1
