import re,statistics as st,collections,sys
f=sys.argv[1]; arms=sys.argv[2].split(',')
d=collections.defaultdict(list); rows={}
for l in open(f):
    m=re.search(r'arm=(\S+) pass=\d+ band=(\S+) rows=(\S*) median_last5=([0-9.]+)',l)
    if m: d[(m.group(1),m.group(2))].append(float(m.group(4))); rows[(m.group(1),m.group(2))]=m.group(3)
bands=['rare_k10','mid_k10','common_k10','common_k100','count_common','and2_k10','or2_k10','or3_k10','prefix_k10']
x,y=arms
print(f"{'band':13} {x:>8} {y:>8}  spread {x}/{y}   speedup  rows_equal")
for b in bands:
    a=d[(x,b)]; c=d[(y,b)]
    print(f"{b:13} {st.median(a):8.2f} {st.median(c):8.2f}   {100*(max(a)/min(a)-1):4.1f}%/{100*(max(c)/min(c)-1):4.1f}%   {st.median(a)/st.median(c):5.2f}x   {rows[(x,b)]==rows[(y,b)]}  n={len(a)}/{len(c)}")
