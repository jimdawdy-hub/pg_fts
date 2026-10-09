#!/bin/bash
# For each A2 mutant: does the 2.19M-doc oracle (and_oracle.py) catch it?  Tells us whether the
# mutant is semantically dead or only uncaught by the small regression corpus.
cd /nvme/fts_a; B=/nvme/pgs/bin; cp pg_fts_am_scan.c /tmp/scan_cur.c; LIB=$($B/pg_config --pkglibdir)
mut(){ python3 -c "
import sys
p='pg_fts_am_scan.c'; s=open(p).read(); a=sys.argv[1]; b=sys.argv[2]
assert s.count(a)==1; open(p,'w').write(s.replace(a,b))" "$2" "$3" || { echo "PATTERN $1"; return; }
  make -s PG_CONFIG=$B/pg_config -j16 >/dev/null 2>&1 && make -s PG_CONFIG=$B/pg_config install >/dev/null 2>&1
  $B/pg_ctl -D /nvme/bench_s -w restart -l /nvme/bench_s/server.log >/dev/null
  echo "mutant $1: $(python3 /tmp/and_oracle.py docs_fts 'united & states' 'slovakia & hungary' 'world & war' 2>&1 | tail -1) | $(python3 /tmp/and_oracle.py docs_fts_pos '"united states"' '"world war"' 2>&1 | tail -1)"
  cp /tmp/scan_cur.c pg_fts_am_scan.c; }
mut overlap-one-block '						for (jj = j; jj < no && oh[jj].first < hi; jj++)
							mb = Max(mb, oh[jj].bound);' '						mb = oh[j].bound;'
mut stop-nonstrict '		if (top.bound < 0.0 || (nheap == k && top.bound < threshold))' '		if (top.bound < 0.0 || (nheap == k && top.bound <= threshold + 0.5))'
mut no-rewind '		c->cur = 0;				/* already decoded: rewind within the block */
		c->docid = c->docids[0];
		return;' '		return;'
mut no-phrase-check '				if (!phrase_gate_adjacent(pg, pc))' '				if (false)'
make -s PG_CONFIG=$B/pg_config -j16 >/dev/null 2>&1 && make -s PG_CONFIG=$B/pg_config install >/dev/null 2>&1; cp $LIB/pg_fts.so /nvme/pg_fts_cur.so
$B/pg_ctl -D /nvme/bench_s -w restart -l /nvme/bench_s/server.log >/dev/null; echo "restored so=$(md5sum /nvme/pg_fts_cur.so | cut -c1-8)"
