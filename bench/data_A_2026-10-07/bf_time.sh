#!/bin/bash
B=/nvme/pgs/bin; P="$B/psql -h /tmp -p 55440 -U postgres -X -q -At"
$P -c "SELECT pg_prewarm('docs'), pg_prewarm('docs_fts')" >/dev/null
for t in year also film united slovakia hungary; do for k in 10 100; do
  sql="SELECT count(*) FROM (SELECT id FROM docs WHERE d @@@ to_ftsquery('english','$t') ORDER BY d <=> to_ftsquery('english','$t') LIMIT $k) s"
  line="$t k=$k"
  for arm in "bestfirst=on" "bestfirst=off"; do for pass in 1 2 3; do
    { echo "SET enable_seqscan=off; SET enable_bitmapscan=off; SET pg_fts.$arm;"; echo '\timing on'; for i in 1 2 3 4 5 6 7 8; do echo "$sql;"; done; } > /tmp/bt.sql
    $P -f /tmp/bt.sql > /tmp/bt.out 2>&1
    m=$(sed -n 's/^Time: \([0-9.]*\) ms.*/\1/p' /tmp/bt.out | tail -5 | sort -n | sed -n 3p); line="$line ${arm#bestfirst=}=$m"
  done; done; echo "$line"
done; done
