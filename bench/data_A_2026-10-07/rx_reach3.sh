#!/bin/bash
cd /nvme/fts_a; B=/nvme/pg17/bin; cp pg_fts_am_scan.c /tmp/scan_cur.c
python3 - <<'PY'
p='pg_fts_am_scan.c'; s=open(p).read()
a="""		if (top.bound < 0.0 || (nheap == k && top.bound < threshold))
			break;"""
assert s.count(a)==1
s=s.replace(a,"""		elog(LOG, "A2REACH nv=%d k=%d", nv, k);
		if (top.bound < 0.0 || (nheap == k && top.bound < threshold))
			break;""")
open(p,'w').write(s)
PY
make -s PG_CONFIG=$B/pg_config -j16 >/dev/null 2>&1 && make -s PG_CONFIG=$B/pg_config install >/dev/null 2>&1; $B/pg_ctl -D /nvme/rg -l /nvme/rg/log -w restart >/dev/null 2>&1
$B/psql -h /tmp -p 55432 -U postgres -X -q -d postgres -c "ALTER SYSTEM SET log_min_messages = info" -c "SELECT pg_reload_conf()" >/dev/null
L0=$(wc -l < /nvme/rg/log)
make PG_CONFIG=$B/pg_config installcheck REGRESS="pg_fts ranked_exact" ISOLATION= PROVE_TESTS=ci/noop.pl PGHOST=/tmp PGPORT=55432 PGUSER=postgres >/dev/null 2>&1
echo "A2REACH in server log during ranked_exact: $(tail -n +$L0 /nvme/rg/log | grep -c A2REACH)"
$B/psql -h /tmp -p 55432 -U postgres -X -q -d postgres -c "ALTER SYSTEM RESET log_min_messages" -c "SELECT pg_reload_conf()" >/dev/null
cp /tmp/scan_cur.c pg_fts_am_scan.c; make -s PG_CONFIG=$B/pg_config -j16 >/dev/null 2>&1 && make -s PG_CONFIG=$B/pg_config install >/dev/null 2>&1
