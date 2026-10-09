#!/bin/bash
cd /nvme/fts_a; B=/nvme/pg17/bin; cp pg_fts_am_scan.c /tmp/scan_cur.c
python3 -c "
p='pg_fts_am_scan.c'; s=open(p).read(); a='				if (!phrase_gate_adjacent(pg, pc))'
assert s.count(a)==1; open(p,'w').write(s.replace(a,'				if (false)'))"
make -s PG_CONFIG=$B/pg_config -j16 >/dev/null 2>&1 && make -s PG_CONFIG=$B/pg_config install >/dev/null 2>&1; $B/pg_ctl -D /nvme/rg -l /nvme/rg/log -w restart >/dev/null 2>&1
make PG_CONFIG=$B/pg_config installcheck REGRESS="pg_fts ranked_exact" ISOLATION= PROVE_TESTS=ci/noop.pl PGHOST=/tmp PGPORT=55432 PGUSER=postgres >/dev/null 2>&1
echo "mutant no-phrase-check:"; grep -A6 "AS phrase_rows" results/ranked_exact.out | tail -4
cp /tmp/scan_cur.c pg_fts_am_scan.c; make -s PG_CONFIG=$B/pg_config -j16 >/dev/null 2>&1 && make -s PG_CONFIG=$B/pg_config install >/dev/null 2>&1
