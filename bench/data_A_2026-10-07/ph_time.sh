#!/bin/bash
# phrase top-10 on the positions index: which index the planner uses, timing, profile
B=/nvme/pgs/bin; P="$B/psql -h /tmp -p 55440 -U postgres -X -q -At"
$P -c "SELECT pg_prewarm('docs_fts_pos')" >/dev/null
Q='"united states"'
sql="SELECT count(*) FROM (SELECT id FROM docs WHERE d @@@ to_ftsquery('english','$Q') ORDER BY d <=> to_ftsquery('english','$Q') LIMIT 10) s"
# force the positions index: drop the plain one from consideration with a txn-local hack is not possible; use pg_fts index hint
$P -c "SET enable_seqscan=off; SET enable_bitmapscan=off; EXPLAIN (COSTS OFF) SELECT id FROM docs WHERE d @@@ to_ftsquery('english','$Q') ORDER BY d <=> to_ftsquery('english','$Q') LIMIT 10" | grep -i "index"
for set in on off; do
  { echo "BEGIN; UPDATE pg_index SET indisvalid=false WHERE indexrelid='docs_fts'::regclass;"; echo "SET enable_seqscan=off; SET enable_bitmapscan=off; SET pg_fts.lazy_phrase=$set;"; echo '\timing on'; for i in 1 2 3 4 5 6 7 8; do echo "$sql;"; done; echo "ROLLBACK;"; } > /tmp/ph.sql
  echo "lazy_phrase=$set: $($P -f /tmp/ph.sql 2>&1 | sed -n 's/^Time: \([0-9.]*\) ms.*/\1/p' | grep -v '^0\.' | tail -5 | sort -n | sed -n 3p)  rows=$($P -f /tmp/ph.sql 2>&1 | grep -v Time | sort -u | tr '\n' ' ')"
done
