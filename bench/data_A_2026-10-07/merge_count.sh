#!/bin/bash
# count calls during an fts_merge of a 7-segment index (the build's collapse step, isolated):
# build with collapse disabled, then fts_merge under uprobes
B=/nvme/pgs/bin; P="$B/psql -h /tmp -p 55440 -U postgres -X -q -At"; SO=$($B/pg_config --pkglibdir)/pg_fts.so
$P -c "DROP INDEX IF EXISTS docs_fts_b" >/dev/null
t0=$(date +%s); $P -c "SET pg_fts.build_collapse_max_mb = 1" -c "CREATE INDEX docs_fts_b ON docs USING fts (d)" >/dev/null 2>&1; echo "build(no collapse) $(( $(date +%s)-t0 )) s nseg=$($P -c "SELECT fts_index_nsegments('docs_fts_b')") size=$($P -c "SELECT pg_relation_size('docs_fts_b')")"
sudo perf probe -d 'probe_*:*' >/dev/null 2>&1
sudo perf probe -x $SO -a add_posting >/dev/null 2>&1
sudo perf probe -x $SO -a doclen_collector_add >/dev/null 2>&1 || echo "doclen_collector_add inlined"
sudo perf probe -x $(dirname $B)/bin/postgres -a hash_search_with_hash_value >/dev/null 2>&1
sudo perf probe -x $SO -a bm25_write_postings >/dev/null 2>&1
sudo perf probe -l 2>/dev/null | head
{ echo "SELECT pg_backend_pid();"; echo "SELECT pg_sleep(1);"; echo "\\timing on"; echo "SELECT fts_merge('docs_fts_b');"; } > /tmp/mc.sql
$P -f /tmp/mc.sql > /tmp/mc.out 2>&1 & sleep 0.5; PID=$(head -1 /tmp/mc.out)
sudo perf stat $(sudo perf probe -l 2>/dev/null | awk '{print "-e "$1}' | tr '\n' ' ') -p $PID 2>&1 > /dev/null | grep -E "probe" &
SP=$!; wait %1 2>/dev/null; sleep 1; sudo kill -INT $(pgrep -f "perf stat") 2>/dev/null; wait $SP 2>/dev/null
grep Time /tmp/mc.out; echo "nseg after=$($P -c "SELECT fts_index_nsegments('docs_fts_b')")"
sudo perf probe -d 'probe_*:*' >/dev/null 2>&1
