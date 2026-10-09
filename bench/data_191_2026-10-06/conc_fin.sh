#!/bin/bash
# final binary: rare + common tps at 16/32/64, 2 passes, 30 s (same as conc2/underload)
B=/nvme/pg17/bin; export PATH=$B:$PATH; LIB=$($B/pg_config --pkglibdir); P="psql -h /tmp -U postgres -X -q -At"
echo "so=$(md5sum $LIB/pg_fts.so | cut -c1-8)"
q() { echo "SELECT count(*) FROM (SELECT id FROM docs WHERE d @@@ to_ftsquery('english','$1') ORDER BY d <=> to_ftsquery('english','$1') LIMIT 10) s;"; }
q slovakia > /tmp/w_rare.sql; q year > /tmp/w_common.sql
for f in rare common; do echo "$f rows=$($P -f /tmp/w_$f.sql)"; pgbench -h /tmp -U postgres -n -f /tmp/w_$f.sql -c 8 -j 8 -T 10 postgres >/dev/null 2>&1; done
for pass in 1 2; do for f in rare common; do line="pass=$pass $f"; for c in 16 32 64; do j=$(( c < 8 ? c : 8 ))
  line="$line c$c=$(pgbench -h /tmp -U postgres -n -f /tmp/w_$f.sql -c $c -j $j -T 30 postgres 2>&1 | sed -n 's/^tps = \([0-9.]*\).*/\1/p')"; done; echo "$line"; done; done
