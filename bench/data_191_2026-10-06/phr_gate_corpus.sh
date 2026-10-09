#!/bin/bash
# lazy vs collect: identical ids+distances for several phrases and k on the 2.2M corpus; then timing
B=/nvme/pgs/bin; P="$B/psql -h /tmp -p 55440 -U postgres -X -q -At"
$P -c "DROP INDEX IF EXISTS docs_fts" >/dev/null 2>&1   # only the positions index: the scan must use it
$P -c "SELECT pg_prewarm('docs_fts_pos')" >/dev/null
for ph in '"united states"' '"new york city"' '"world war"' '"the united states of america"' '"university of california"' 'NEAR(river valley, 3)' '"rare phrase zzzq"'; do
 for k in 1 10 100 1000; do
  q="SELECT string_agg(id||':'||dist, ',') FROM (SELECT id, d <=> to_ftsquery('english','$ph') dist FROM docs WHERE d @@@ to_ftsquery('english','$ph') ORDER BY d <=> to_ftsquery('english','$ph') LIMIT $k) s"
  a=$($P -c "SET enable_seqscan=off; SET enable_bitmapscan=off; SET pg_fts.lazy_phrase=on;" -c "$q" | md5sum | cut -c1-12)
  n=$($P -c "SET enable_seqscan=off; SET enable_bitmapscan=off; SET pg_fts.lazy_phrase=on;" -c "SELECT count(*) FROM ($q) x" ) 
  c=$($P -c "SET enable_seqscan=off; SET enable_bitmapscan=off; SET pg_fts.lazy_phrase=off;" -c "$q" | md5sum | cut -c1-12)
  rows=$($P -c "SET enable_seqscan=off; SET enable_bitmapscan=off;" -c "SELECT count(*) FROM (SELECT 1 FROM docs WHERE d @@@ to_ftsquery('english','$ph') ORDER BY d <=> to_ftsquery('english','$ph') LIMIT $k) s")
  echo "$([ $a = $c ] && echo SAME || echo DIFF) k=$k rows=$rows ph=$ph"
 done
done
echo "phrase df: $($P -c "SET enable_seqscan=off; SELECT fts_count('docs_fts_pos', to_ftsquery('english','\"united states\"'))")"
