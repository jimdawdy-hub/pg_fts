#!/bin/bash
# phase timing, cold, slovakia and year, arms 110 and a2
B=/nvme/pg17/bin; D=/nvme/pgdata; LIB=$($B/pg_config --pkglibdir); P="$B/psql -h /tmp -U postgres -X -q -At"
for Q in slovakia year; do for arm in 110 a2; do
  $B/pg_ctl -D $D -w stop >/dev/null 2>&1; cp /nvme/pg_fts_$arm.so $LIB/pg_fts.so; sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
  $B/pg_ctl -D $D -l $D/server.log -w start >/dev/null
  SO=$LIB/pg_fts.so; sudo perf probe -d 'probe_*:*' >/dev/null 2>&1
  for f in bm25_topk_candidates_range bm25_doclen_build_slots bestfirst_collect fts_search_bestfirst1 fts_search_dense1 fts_search_bmw bm25_dict_seek; do
    sudo perf probe -x $SO -a $f >/dev/null 2>&1 && sudo perf probe -x $SO -a ${f}_r=$f%return >/dev/null 2>&1; done
  { echo "SELECT pg_backend_pid();"; echo "SELECT pg_sleep(1.5);"; echo "SET enable_seqscan=off; SET enable_bitmapscan=off;"; echo "SELECT count(*) FROM (SELECT id FROM docs WHERE d @@@ to_ftsquery('english','$Q') ORDER BY d <=> to_ftsquery('english','$Q') LIMIT 10) s;"; } > /tmp/cp.sql
  $P -f /tmp/cp.sql > /tmp/cp.out 2>&1 & sleep 0.5; BP=$(head -1 /tmp/cp.out)
  EV=$(sudo perf probe -l 2>/dev/null | awk '{print "-e "$1}' | tr '\n' ' ')
  sudo perf record $EV -p $BP -o /tmp/ct.data -- sleep 2.5 >/dev/null 2>&1; wait
  echo "== $Q arm=$arm"
  sudo perf script -i /tmp/ct.data -F time,event 2>/dev/null | awk '{t=$1; sub(":","",t); e=$2; sub("probe_pg_fts:","",e); sub(":","",e); if (!t0) t0=t; printf "  %8.3f %s\n", (t-t0)*1000, e}' | grep -v dict_seek | head -14
  echo "  dict_seek calls: $(sudo perf script -i /tmp/ct.data -F event 2>/dev/null | grep -c 'bm25_dict_seek:')"
  sudo perf probe -d 'probe_*:*' >/dev/null 2>&1
done; done
