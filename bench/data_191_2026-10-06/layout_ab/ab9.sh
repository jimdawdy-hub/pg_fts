#!/bin/bash
# reproduce on a second host (rule 4): 1.9.0 vs 1.9.1 vs 1.9.1+noinline dense1, docs_fts already built by lat2/conc2
B=/nvme/pg17/bin; LIB=$($B/pg_config --pkglibdir); P="$B/psql -h /tmp -U postgres -X -q -At"; D=/nvme/pgdata
cd /nvme; for v in 190 191 191n; do src=$v; [ $v = 191n ] && src=191; [ -d b$v ] && mv b$v b$v.old.$$; mkdir b$v; tar xzf /tmp/fts$src.tgz -C b$v; cd b$v/fts$src; if [ $v = 191n ]; then python3 /tmp/var_191n.py || exit 1; fi; make -s PG_CONFIG=$B/pg_config -j16 >/dev/null 2>&1 && cp pg_fts.so /nvme/pg_fts_$v.so; cd /nvme; done
md5sum /nvme/pg_fts_*.so | cut -c1-8 | tr "\n" " "; echo; for v in 190 191 191n; do echo "$v dense1_symbol=$(nm /nvme/pg_fts_$v.so | grep -c " fts_search_dense1$")"; done
cp $LIB/pg_fts.so /nvme/pg_fts_installed.so
q() { echo "SELECT count(*) FROM (SELECT id FROM docs WHERE d @@@ to_ftsquery('english','$1') ORDER BY d <=> to_ftsquery('english','$1') LIMIT $2) s"; }
for pass in 1 2 3; do for v in 190 191 191n; do
  $B/pg_ctl -D $D -w stop >/dev/null 2>&1; cp /nvme/pg_fts_$v.so $LIB/pg_fts.so; $B/pg_ctl -D $D -l $D/server.log -w start >/dev/null
  $P -c "SELECT pg_prewarm('docs'), pg_prewarm('docs_fts')" >/dev/null
  line="pass=$pass v=$v"
  for spec in "year|10" "year|100" "slovakia|10"; do t=${spec%|*}; k=${spec##*|}; sql=$(q "$t" $k)
    { echo '\timing on'; for i in $(seq 1 10); do echo "$sql;"; done; } > /tmp/ab.sql
    $P -f /tmp/ab.sql > /tmp/ab.out 2>&1
    line="$line ${t}_k$k=$(sed -n 's/^Time: \([0-9.]*\) ms.*/\1/p' /tmp/ab.out | tail -7 | sort -n | sed -n 4p)[$(grep -v Time /tmp/ab.out | sort -u)]"
  done; echo "$line"
done; done
cp /nvme/pg_fts_installed.so $LIB/pg_fts.so
