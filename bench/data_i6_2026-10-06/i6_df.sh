#!/bin/bash
B=/nvme/pgs/bin; export PATH=$B:$PATH; P="psql -h /tmp -p 55440 -U postgres -X -q -At"
for t in slovakia ghana olympic railway; do
  df=$($P -c "SELECT fts_count('docs_fts', to_ftsquery('english','$t'))")
  echo "SELECT count(*) FROM (SELECT id FROM docs WHERE d @@@ to_ftsquery('english','$t') ORDER BY d <=> to_ftsquery('english','$t') LIMIT 10) s;" > /tmp/w_t.sql
  out=""; for c in 16 64; do out="$out c$c=$(pgbench -h /tmp -p 55440 -U postgres -n -f /tmp/w_t.sql -c $c -j 8 -T 12 postgres 2>&1 | sed -n 's/^tps = \([0-9]*\).*/\1/p')"; done
  echo "term=$t df=$df $out"
done
