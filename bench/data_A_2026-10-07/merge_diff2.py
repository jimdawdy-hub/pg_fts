# compare only LIVE pages (not BM25_FREED=256): live posting/dict/doclen/dictindex pages must match;
# freed pages carry a free-time XID in nextblk and leftover bytes from the inputs
import struct
from collections import Counter
a=open('/nvme/idx_prev.bin','rb').read(); b=open('/nvme/idx_cur.bin','rb').read()
FREED=256
d=Counter(); s=Counter(); ex=[]
for i in range(0, len(a), 8192):
    pa=a[i:i+8192]; pb=b[i:i+8192]
    fa=struct.unpack_from('<H', pa, 8192-8)[0]; fb=struct.unpack_from('<H', pb, 8192-8)[0]
    if (fa & FREED) or (fb & FREED):
        if (fa & FREED) != (fb & FREED): d[('freed-mismatch',fa,fb)]+=1
        continue
    if pa[24:]!=pb[24:]:
        d[(fa,fb)]+=1
        if len(ex)<3: ex.append(i//8192)
    else: s[fa]+=1
print("live differing:", dict(d), "live identical:", dict(s), "examples", ex)
