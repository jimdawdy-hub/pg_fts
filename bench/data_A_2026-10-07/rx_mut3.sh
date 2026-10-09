#!/bin/bash
# ranked_exact on current, and with each A2/weighted mutant
cd /nvme/fts_a; B=/nvme/pg17/bin; cp pg_fts_am_scan.c /tmp/scan_cur.c
run(){ make -s PG_CONFIG=$B/pg_config -j16 >/dev/null 2>&1 && make -s PG_CONFIG=$B/pg_config install >/dev/null 2>&1; $B/pg_ctl -D /nvme/rg -l /nvme/rg/log -w restart >/dev/null 2>&1
  make PG_CONFIG=$B/pg_config installcheck REGRESS="pg_fts ranked_exact" ISOLATION= PROVE_TESTS=ci/noop.pl PGHOST=/tmp PGPORT=55432 PGUSER=postgres >/dev/null 2>&1
  echo "[so $(md5sum $($B/pg_config --pkglibdir)/pg_fts.so | cut -c1-8)] f-rows=$(grep -cE '\| f$' results/ranked_exact.out) err=$(grep -c ERROR results/ranked_exact.out) nonmatch=$(grep -E '^ alpha' results/ranked_exact.out | awk -F'|' '{s+=$4} END {print s+0}')"; grep -E "\| f$" results/ranked_exact.out | head -3; }
mut(){ # $1 name, $2 python replacement (old, new)
  python3 -c "
import sys
p='pg_fts_am_scan.c'; s=open(p).read(); a=sys.argv[1]; b=sys.argv[2]
assert s.count(a)==1, ('pattern', s.count(a)); open(p,'w').write(s.replace(a,b))" "$2" "$3" || { echo "MUTANT $1 PATTERN MISSING"; return; }
  echo -n "mutant $1: "; run; cp /tmp/scan_cur.c pg_fts_am_scan.c; }
echo -n "current: "; run; cp results/ranked_exact.out /tmp/rx_good.out
mut overlap-one-block '						for (jj = j; jj < no && oh[jj].first < hi; jj++)
							mb = Max(mb, oh[jj].bound);' '						mb = oh[j].bound;'
mut stop-nonstrict '		if (top.bound < 0.0 || (nheap == k && top.bound < threshold))' '		if (top.bound < 0.0 || (nheap == k && top.bound <= threshold + 0.5))'
mut no-rewind '		c->cur = 0;				/* already decoded: rewind within the block */
		c->docid = c->docids[0];
		return;' '		return;'
mut no-phrase-check '				if (!phrase_gate_adjacent(pg, pc))' '				if (false)'
mut weighted-pure "			if (it->flags & (FTS_QF_PREFIX | FTS_QF_FUZZY | FTS_QF_REGEX |
							 FTS_QF_WEIGHTED))
				return false;
		}
		else					/* operator */
		{
			if (it->op != FTS_OP_AND && it->op != FTS_OP_OR &&" "			if (it->flags & (FTS_QF_PREFIX | FTS_QF_FUZZY | FTS_QF_REGEX))
				return false;
		}
		else					/* operator */
		{
			if (it->op != FTS_OP_AND && it->op != FTS_OP_OR &&"
echo -n "restored: "; run
