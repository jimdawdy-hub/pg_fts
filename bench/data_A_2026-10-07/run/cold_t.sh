#!/bin/bash
# per-phase timing of a cold first ranked query via uprobe timestamps: bm25_topk_candidates_range,
# shdl_get / bm25_doclendir_cache (the first-use builders), the candidate walk, the heap loop.
B=/nvme/pg17/bin; D=/nvme/pgdata; LIB=$($B/pg_config --pkglibdir); P="$B/psql -h /tmp -U postgres -X -q -At"
for arm in a; do
  $B/pg_ctl -D $D -w stop >/dev/null 2>&1; cp /nvme/pg_fts_$arm.so $LIB/pg_fts.so; sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
  $B/pg_ctl -D $D -l $D/server.log -w start >/dev/null
  SO=$LIB/pg_fts.so
  sudo perf probe -d 'probe_*:*' >/dev/null 2>&1
  for f in bm25_topk_candidates_range bm25_doclendir_cache shdl_get bm25_doclen_build_slots bm25_tombstones_load; do
    sudo perf probe -x $SO -a $f >/dev/null 2>&1 && sudo perf probe -x $SO -a ${f}_r=$f%return >/dev/null 2>&1
  done
  sudo perf probe -x $SO -a 'fts_search_bestfirst1' >/dev/null 2>&1; sudo perf probe -x $SO -a 'fts_search_bestfirst1_r=fts_search_bestfirst1%return' >/dev/null 2>&1
  sudo perf probe -x $SO -a bestfirst_collect >/dev/null 2>&1; sudo perf probe -x $SO -a bestfirst_collect_r=bestfirst_collect%return >/dev/null 2>&1
  { echo "SELECT pg_backend_pid();"; echo "SELECT pg_sleep(1.5);"; echo "SET enable_seqscan=off; SET enable_bitmapscan=off;"; echo "SELECT count(*) FROM (SELECT id FROM docs WHERE d @@@ to_ftsquery('english','year') ORDER BY d <=> to_ftsquery('english','year') LIMIT 10) s;"; } > /tmp/cp.sql
  $P -f /tmp/cp.sql > /tmp/cp.out 2>&1 & sleep 0.5; BP=$(head -1 /tmp/cp.out)
  EV=$(sudo perf probe -l 2>/dev/null | awk '{print "-e "$1}' | tr '\n' ' ')
  sudo perf record $EV -p $BP -o /tmp/ct_$arm.data -- sleep 2.5 >/dev/null 2>&1; wait
  echo "== arm=$arm"
  sudo perf script -i /tmp/ct_$arm.data -F time,event 2>/dev/null | awk '{t=$1; sub(":","",t); e=$2; sub("probe_pg_fts:","",e); sub(":","",e); if (!t0) t0=t; printf "  %8.3f ms %s\n", (t-t0)*1000, e}' | head -24
  sudo perf probe -d 'probe_*:*' >/dev/null 2>&1
done
