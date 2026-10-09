#!/bin/bash
B=/nvme/pgs/bin; P="$B/psql -h /tmp -p 55440 -U postgres -X -q -At"; LIB=$($B/pg_config --pkglibdir)
cd /nvme; [ -d fts_probe ] && mv fts_probe fts_probe.old.$$; mkdir fts_probe; tar xzf /tmp/fts_probe.tgz -C fts_probe --strip-components=1; cd fts_probe
make -s PG_CONFIG=$B/pg_config -j16 >/dev/null 2>&1; grep -c RUNPROBE pg_fts_am.c; strings pg_fts.so | grep -c RUNPROBE
cp pg_fts.so $LIB/pg_fts.so; $B/pg_ctl -D /nvme/bench_s -w restart -l /nvme/bench_s/server.log >/dev/null
$P -c "ALTER SYSTEM SET log_min_messages = info" -c "SELECT pg_reload_conf()" >/dev/null
$P -c "DROP INDEX IF EXISTS docs_fts_b" >/dev/null
L0=$(wc -l < /nvme/bench_s/server.log)
$P -c "SET pg_fts.build_collapse_max_mb = 1" -c "SET client_min_messages=warning" -c "CREATE INDEX docs_fts_b ON docs USING fts (d)" >/dev/null 2>&1
echo "flush-phase probes (per-worker segments): $(tail -n +$L0 /nvme/bench_s/server.log | grep -c RUNPROBE)"; tail -n +$L0 /nvme/bench_s/server.log | grep RUNPROBE | sed 's/.*RUNPROBE //' | sort -t= -k2 -n -r | head -3
L0=$(wc -l < /nvme/bench_s/server.log)
$P -c "SELECT fts_merge('docs_fts_b')" >/dev/null
echo "merge probes:"; tail -n +$L0 /nvme/bench_s/server.log | grep RUNPROBE | sed 's/.*RUNPROBE //' | awk '{print $2}' | sort | uniq -c | sort -rn | head -5
tail -n +$L0 /nvme/bench_s/server.log | grep RUNPROBE | sed 's/.*RUNPROBE //' | sort -t= -k2 -n -r | head -3
$P -c "ALTER SYSTEM RESET log_min_messages" -c "SELECT pg_reload_conf()" >/dev/null
cp /nvme/pg_fts_cur.so $LIB/pg_fts.so; $B/pg_ctl -D /nvme/bench_s -w restart -l /nvme/bench_s/server.log >/dev/null
