#!/bin/bash
# usage: ab_top.sh <arm> <port> : top-k id lists (k=10 and 100) per ranked band, for cross-arm identity check
ARM=$1; PORT=$2; B=/nvme/pg$ARM/bin; P="$B/psql -h /tmp -p $PORT -U postgres -X -q -At"
for t in slovakia hungary year 'slovakia & hungary' 'slovakia | hungary' 'slovakia | hungary | poland' 'hung*'; do
  for k in 10 100; do
    echo "$t|$k|$($P -c "SET enable_seqscan=off; SELECT string_agg(id::text, ',') FROM (SELECT id FROM docs WHERE d @@@ to_ftsquery('english','$t') ORDER BY d <=> to_ftsquery('english','$t') LIMIT $k) s" | tail -1)"
  done
done
