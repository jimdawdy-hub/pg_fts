#!/bin/bash
# rxc shape + u&v under the stop/overlap mutants, printed directly
cd /nvme/fts_a; B=/nvme/pg17/bin; cp pg_fts_am_scan.c /tmp/scan_cur.c
sed -n '/^CREATE TABLE rxc/,/^DROP TABLE rxc;/p' sql/ranked_exact.sql > /tmp/rxc_only.sql
sed -n '1,/^VACUUM ANALYZE rx;/p' sql/ranked_exact.sql > /tmp/rx_build.sql
sed -n '/^-- single-term scores of every matching row/,/^SELECT array_to_string(terms/p' sql/ranked_exact.sql | sed '$d' > /tmp/rx_funcs.sql
sed -n '/^CREATE FUNCTION rx_and_same/,/^END \$\$;/p' sql/ranked_exact.sql >> /tmp/rx_funcs.sql
mut(){ python3 -c "
import sys
p='pg_fts_am_scan.c'; s=open(p).read(); a=sys.argv[1]; b=sys.argv[2]
assert s.count(a)==1; open(p,'w').write(s.replace(a,b))" "$2" "$3"
  make -s PG_CONFIG=$B/pg_config -j16 >/dev/null 2>&1 && make -s PG_CONFIG=$B/pg_config install >/dev/null 2>&1; $B/pg_ctl -D /nvme/rg -l /nvme/rg/log -w restart >/dev/null 2>&1
  echo "== $1"
  $B/psql -h /tmp -p 55432 -U postgres -X -q -At -d postgres -c "SET enable_seqscan=off; SET enable_bitmapscan=off;" -f /tmp/rxc_only.sql 2>&1 | tr '\n' ' '; echo
  $B/psql -h /tmp -p 55432 -U postgres -X -q -At -d postgres -c "SET enable_seqscan=off; SET enable_bitmapscan=off;" -c "SELECT 'u&v', rx_and_same('u & v', ARRAY['u','v']), 'u&v&w', rx_and_same('u & v & w', ARRAY['u','v','w']), 'a&b', rx_and_same('a & b', ARRAY['a','b'])" 2>&1 | tail -1
  cp /tmp/scan_cur.c pg_fts_am_scan.c; }
$B/psql -h /tmp -p 55432 -U postgres -X -q -d postgres -c "DROP TABLE IF EXISTS rx CASCADE; DROP TABLE IF EXISTS rxc" -c "SET client_min_messages=warning" -f /tmp/rx_build.sql -f /tmp/rx_funcs.sql >/dev/null 2>&1
mut none 'static int
fts_search_wand(' 'static int
fts_search_wand('
mut no-rewind '		c->cur = 0;				/* already decoded: rewind within the block */
		c->docid = c->docids[0];
		return;' '		return;'
mut overlap-one-block '						for (jj = j; jj < no && oh[jj].first < hi; jj++)
							mb = Max(mb, oh[jj].bound);' '						mb = oh[j].bound;'
mut stop-nonstrict '		if (top.bound < 0.0 || (nheap == k && top.bound < threshold))' '		if (top.bound < 0.0 || (nheap == k && top.bound <= threshold + 0.5))'
make -s PG_CONFIG=$B/pg_config -j16 >/dev/null 2>&1 && make -s PG_CONFIG=$B/pg_config install >/dev/null 2>&1
