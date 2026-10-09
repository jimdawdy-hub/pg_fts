#!/bin/bash
for c in 16 64; do
  sudo perf report -i /tmp/i6_$c.data --no-children --sort dso,sym --stdio -g none 2>/dev/null | grep -E "^ +[0-9]" | awk '{p=$1; sub("%","",p); $1=""; print p "\t" $0}' > /tmp/sym_$c.txt
  sudo perf script -i /tmp/i6_$c.data -F comm 2>/dev/null | sort | uniq -c | sort -rn | head -4 > /tmp/comm_$c.txt
done
T16=$(sed -n 's/^tps = \([0-9.]*\).*/\1/p' /tmp/pgb_16.out); T64=$(sed -n 's/^tps = \([0-9.]*\).*/\1/p' /tmp/pgb_64.out)
echo "comm c16:"; cat /tmp/comm_16.txt; echo "comm c64:"; cat /tmp/comm_64.txt
python3 - "$T16" "$T64" <<'PY'
import sys
t16,t64=float(sys.argv[1]),float(sys.argv[2])
def load(c):
    d={}
    for l in open(f"/tmp/sym_{c}.txt"):
        p,rest=l.rstrip("\n").split("\t",1); d[rest.strip()]=float(p)
    return d
a,b=load(16),load(64)
# cost per txn ~ share / tps (both runs are 100% CPU over the same wall time)
rows=[]
for k in set(a)|set(b):
    ca=a.get(k,0)/t16; cb=b.get(k,0)/t64
    rows.append((cb-ca,ca,cb,k))
rows.sort(reverse=True)
tot_a=sum(a.values())/t16; tot_b=sum(b.values())/t64
print(f"per-txn cost units: c16={tot_a*1e4:.2f} c64={tot_b*1e4:.2f}  (ratio {tot_b/tot_a:.3f})")
print("largest per-txn growth (c64-c16, units 1e-4 %CPU-per-tps):")
for d,ca,cb,k in rows[:22]:
    print(f"  {d*1e4:+7.3f}  c16={ca*1e4:6.3f} c64={cb*1e4:6.3f}  {k[:90]}")
PY
