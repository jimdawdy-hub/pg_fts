#!/bin/bash
B=/nvme/pgs/bin; P="$B/psql -h /tmp -p 55440 -U postgres -X -q -At"
$P -c "ALTER EXTENSION pg_fts UPDATE" 2>/dev/null; echo "ext=$($P -c "select extversion from pg_extension where extname='pg_fts'") so=$(md5sum $($B/pg_config --pkglibdir)/pg_fts.so | cut -c1-8)"
$P -c "SELECT pg_prewarm('docs'), pg_prewarm('docs_fts')" >/dev/null
n=0; bad=0
for q in slovakia hungary year 'slovakia & hungary' 'slovakia | hungary' 'film' 'hung*'; do for k in 10 100 1000; do
  sql="SELECT md5(string_agg(id||':'||dist, ',')), count(*) FROM (SELECT id, d <=> to_ftsquery('english','$q') dist FROM docs WHERE d @@@ to_ftsquery('english','$q') ORDER BY d <=> to_ftsquery('english','$q') LIMIT $k) s"
  on=$($P -c "SET enable_seqscan=off; SET enable_bitmapscan=off; SET pg_fts.shared_doclen=on;" -c "$sql")
  off=$($P -c "SET enable_seqscan=off; SET enable_bitmapscan=off; SET pg_fts.shared_doclen=off;" -c "$sql")
  cur=$($P -c "SET enable_seqscan=off; SET enable_bitmapscan=off; SET pg_fts.shared_doclen=off; SET pg_fts.doclen_cache_mb=0;" -c "$sql")
  n=$((n+1)); if [ "$on" = "$off" ] && [ "$on" = "$cur" ]; then r=SAME; else r=DIFF; bad=$((bad+1)); fi
  echo "$r k=$k rows=${on##*|} q=$q"
done; done
echo "TOTAL $n cases, $bad differ"
$P -c "SELECT state, refcnt, retired, pg_size_pretty(bytes) FROM fts_shared_doclen_stats()"
