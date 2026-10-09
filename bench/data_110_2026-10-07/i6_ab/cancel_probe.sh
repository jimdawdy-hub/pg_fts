B=/nvme/pgs/bin; P="$B/psql -h /tmp -p 55440 -U postgres -X -q -At"
$B/pg_ctl -D /nvme/bench_s -w stop >/dev/null 2>&1; $B/pg_ctl -D /nvme/bench_s -l /nvme/bench_s/server.log -w start >/dev/null
q="SET enable_seqscan=off; SET enable_bitmapscan=off; SELECT count(*) FROM (SELECT id FROM docs WHERE d @@@ to_ftsquery('english','slovakia') ORDER BY d <=> to_ftsquery('english','slovakia') LIMIT 10) s"
hits=0
for delay in 0.005 0.010 0.015 0.020 0.025 0.030 0.040; do
  $B/pg_ctl -D /nvme/bench_s -w restart -l /nvme/bench_s/server.log >/dev/null   # empty table each time
  ( $P -c "SET statement_timeout = 0" -c "$q" > /tmp/cq.out 2>&1 ) & QP=$!
  sleep $delay
  $P -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE query LIKE '%slovakia%' AND pid <> pg_backend_pid()" >/dev/null
  wait $QP
  st=$($P -c "SELECT coalesce(string_agg(state||'/'||refcnt, ','),'none') FROM fts_shared_doclen_stats()")
  canceled=$(grep -c "canceling statement" /tmp/cq.out)
  r=$($P -c "$q" 2>&1 | tail -1)
  st2=$($P -c "SELECT coalesce(string_agg(state||'/'||refcnt, ','),'none') FROM fts_shared_doclen_stats()")
  echo "delay=$delay canceled=$canceled table_after_cancel=[$st] next_query=$r table_after=[$st2]"
done
