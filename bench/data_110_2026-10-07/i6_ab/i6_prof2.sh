#!/bin/bash
# per-txn cost by symbol, c64, shared on vs off (same binary); same method as the 2026-10-06 diagnosis
B=/nvme/pgs/bin; export PATH=$B:$PATH; D=/nvme/bench_s; PORT=55440
for arm in on off; do
  pg_ctl -D $D -w stop >/dev/null 2>&1; pg_ctl -D $D -l $D/server.log -o "-c pg_fts.shared_doclen=$arm" -w start >/dev/null
  psql -h /tmp -p $PORT -U postgres -X -q -c "SELECT pg_prewarm('docs'), pg_prewarm('docs_fts')" >/dev/null
  pgbench -h /tmp -p $PORT -U postgres -n -f /tmp/w_rare.sql -c 8 -j 8 -T 8 postgres >/dev/null 2>&1
  pgbench -h /tmp -p $PORT -U postgres -n -f /tmp/w_rare.sql -c 64 -j 8 -T 22 postgres > /tmp/pgb_$arm.out 2>&1 &
  PB=$!; sleep 5
  sudo perf record -a -g -F 499 -e cpu-clock -o /tmp/p6_$arm.data -- sleep 10 >/dev/null 2>&1
  wait $PB
  sudo perf report -i /tmp/p6_$arm.data --no-children --sort dso,sym --stdio -g none 2>/dev/null | grep -E "^ +[0-9]" | awk '{p=$1; sub("%","",p); $1=""; print p "\t" $0}' > /tmp/sym6_$arm.txt
done
python3 - <<'PY'
import re
def tps(a): return float(re.search(r"tps = ([0-9.]+)", open(f"/tmp/pgb_{a}.out").read()).group(1))
def load(a):
    d={}
    for l in open(f"/tmp/sym6_{a}.txt"):
        p,r=l.rstrip("\n").split("\t",1); d[r.strip()]=float(p)
    return d
on,off=load("on"),load("off"); ton,toff=tps("on"),tps("off")
print(f"c64 tps: shared on {ton:.0f}, off {toff:.0f}")
for k in sorted(set(on)|set(off), key=lambda k: -(off.get(k,0)/toff-on.get(k,0)/ton))[:8]:
    print(f"  per-txn cost x1e4: off={off.get(k,0)/toff*1e4:7.3f} on={on.get(k,0)/ton*1e4:7.3f}  {k[:80]}")
PY
pg_ctl -D $D -w stop >/dev/null 2>&1; pg_ctl -D $D -l $D/server.log -w start >/dev/null
