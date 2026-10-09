#!/bin/bash
# unpack /tmp/fts_a.tgz into /nvme/fts_a, build + install into both PG trees, restart both clusters
cd /nvme; [ -d fts_a ] && mv fts_a fts_a.old.$$; tar xzf /tmp/fts_a.tgz; cd fts_a; tar xzf /tmp/fts_ci.tgz
for PGB in /nvme/pgs/bin /nvme/pg17/bin; do
  make -s PG_CONFIG=$PGB/pg_config clean >/dev/null 2>&1
  make -s PG_CONFIG=$PGB/pg_config -j16 2>&1 | grep -E "warning:|error:" | head -5
  make -s PG_CONFIG=$PGB/pg_config install >/dev/null 2>&1
done
cp $(/nvme/pgs/bin/pg_config --pkglibdir)/pg_fts.so /nvme/pg_fts_cur.so
echo "so=$(md5sum /nvme/pg_fts_cur.so | cut -c1-8) and_bf=$(strings /nvme/pg_fts_cur.so | grep -c fts_search_and_bestfirst; nm /nvme/pg_fts_cur.so | grep -c fts_search_and_bestfirst)"
/nvme/pgs/bin/pg_ctl -D /nvme/bench_s -w restart -l /nvme/bench_s/server.log >/dev/null
/nvme/pg17/bin/pg_ctl -D /nvme/rg -w restart -l /nvme/rg/log >/dev/null 2>&1
