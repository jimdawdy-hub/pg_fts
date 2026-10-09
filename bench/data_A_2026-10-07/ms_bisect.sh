#!/bin/bash
# build a variant that sends >=4 terms to BMW instead of MaxScore; compare top-10 for the 4-term query
B=/nvme/pgs/bin; LIB=$($B/pg_config --pkglibdir)
cd /nvme; [ -d fts_bis ] && mv fts_bis fts_bis.old.$$; cp -a fts_a fts_bis; cd fts_bis
python3 - <<'PY'
p='pg_fts_am_scan.c'; s=open(p).read()
a="	if (nterms >= 4)\n		return fts_search_maxscore(cursors, nterms, k, filter, gate, out);"
assert s.count(a)==1
s=s.replace(a,"	if (nterms >= 400)\n		return fts_search_maxscore(cursors, nterms, k, filter, gate, out);")
open(p,'w').write(s)
PY
make -s PG_CONFIG=$B/pg_config -j16 >/dev/null 2>&1 && cp pg_fts.so /nvme/pg_fts_bis.so
$B/pg_ctl -D /nvme/bench_s -w stop >/dev/null 2>&1; cp /nvme/pg_fts_bis.so $LIB/pg_fts.so; $B/pg_ctl -D /nvme/bench_s -l /nvme/bench_s/server.log -w start >/dev/null
echo "4 terms via BMW:"; python3 /tmp/ms_doc2.py "film | music | album | band" | sed -n 4p
cp /nvme/pg_fts_cur.so $LIB/pg_fts.so; $B/pg_ctl -D /nvme/bench_s -w restart -l /nvme/bench_s/server.log >/dev/null
