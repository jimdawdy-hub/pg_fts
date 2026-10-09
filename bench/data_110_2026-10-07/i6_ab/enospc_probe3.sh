B=/nvme/pgs/bin; P="$B/psql -h /tmp -p 55440 -U postgres -X -q -At"
q="SET enable_seqscan=off; SET enable_bitmapscan=off; SELECT count(*) FROM (SELECT id FROM docs WHERE d @@@ to_ftsquery('english','slovakia') ORDER BY d <=> to_ftsquery('english','slovakia') LIMIT 10) s"
$B/pg_ctl -D /nvme/bench_s -w restart -l /nvme/bench_s/server.log >/dev/null
$P -c "SELECT count(*) FROM fts_shared_doclen_stats()" >/dev/null
for i in 1 2 3; do avail=$(df --output=avail -B1 /dev/shm | tail -1); [ $avail -gt 131072 ] && sudo fallocate -l $(( avail - 65536 )) /dev/shm/fill$i.$$; done
df -B1 --output=avail /dev/shm | tail -1 | awk '{printf "avail=%d KB\n", $1/1024}'
r=$($P -c "$q" 2>&1 | tr '\n' ' ')
echo "full: result=[$r] table=[$($P -c "SELECT coalesce(string_agg(state, ','),'none') FROM fts_shared_doclen_stats()" 2>&1 | tr '\n' ' ')]"
grep -iE "No space|could not resize|could not create|unpin" /nvme/bench_s/server.log | tail -3
for f in /dev/shm/fill*.$$; do sudo unlink $f; done
echo "freed: result=$($P -c "$q" | tail -1) table=[$($P -c "SELECT coalesce(string_agg(state, ','),'none') FROM fts_shared_doclen_stats()")]"
