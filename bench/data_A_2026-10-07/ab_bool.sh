#!/bin/bash
B=/nvme/pgs/bin; P="$B/psql -h /tmp -p 55440 -U postgres -X -q -At"
for t in "slovakia & hungary" "slovakia | hungary" "year & film" "year | film" "united & states" "united | states"; do
  sql="SELECT count(*) FROM (SELECT id FROM docs WHERE d @@@ to_ftsquery('english','$t') ORDER BY d <=> to_ftsquery('english','$t') LIMIT 10) s"
  { echo "SET enable_seqscan=off; SET enable_bitmapscan=off;"; echo '\timing on'; for i in 1 2 3 4 5 6 7 8; do echo "$sql;"; done; } > /tmp/bb.sql
  $P -f /tmp/bb.sql > /tmp/bb.out 2>&1
  echo "$t rows=$(grep -v Time /tmp/bb.out | grep -v SET | sort -u | tr '\n' ,) med=$(sed -n 's/^Time: \([0-9.]*\) ms.*/\1/p' /tmp/bb.out | tail -5 | sort -n | sed -n 3p)"
done
