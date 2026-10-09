#!/bin/bash
# I6 A/B: same binary, pg_fts.shared_doclen on vs off (server-level, restart between arms),
# rare + mid + common k10 at 16/32/64 clients, 30 s, 2 alternating passes per arm.
B=/nvme/pgs/bin; export PATH=$B:$PATH; D=/nvme/bench_s; PORT=55440
P="psql -h /tmp -p $PORT -U postgres -X -q -At"
q() { echo "SELECT count(*) FROM (SELECT id FROM docs WHERE d @@@ to_ftsquery('english','$1') ORDER BY d <=> to_ftsquery('english','$1') LIMIT 10) s;"; }
q slovakia > /tmp/w_rare.sql; q hungary > /tmp/w_mid.sql; q year > /tmp/w_common.sql
echo "so=$(md5sum $(pg_config --pkglibdir)/pg_fts.so | cut -c1-8) nproc=$(nproc) cpu=$(lscpu | sed -n 's/^Model name: *//p')"
for pass in 1 2; do for arm in on off; do
  pg_ctl -D $D -w stop >/dev/null 2>&1
  pg_ctl -D $D -l $D/server.log -o "-c pg_fts.shared_doclen=$arm" -w start >/dev/null
  $P -c "SELECT pg_prewarm('docs'), pg_prewarm('docs_fts')" >/dev/null
  echo "shared=$($P -c 'SHOW pg_fts.shared_doclen')"
  for f in rare mid common; do pgbench -h /tmp -p $PORT -U postgres -n -f /tmp/w_$f.sql -c 8 -j 8 -T 10 postgres >/dev/null 2>&1
    line="pass=$pass arm=$arm $f"
    for c in 16 32 64; do j=$(( c < 8 ? c : 8 ))
      line="$line c$c=$(pgbench -h /tmp -p $PORT -U postgres -n -f /tmp/w_$f.sql -c $c -j $j -T 30 postgres 2>&1 | sed -n 's/^tps = \([0-9]*\).*/\1/p')"
    done; echo "$line"
  done
  echo "  copies=$($P -c "SELECT count(*)||' ready, held='||coalesce(sum(refcnt),0) FROM fts_shared_doclen_stats()") backend_rss_mb=$(ps -o rss= -C postgres | awk '{s+=$1} END{printf "%.0f", s/1024}')"
done; done
