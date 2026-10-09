import struct, sys
from collections import Counter
a=open(sys.argv[1],'rb').read(); b=open(sys.argv[2],'rb').read()
d=Counter(); s=Counter()
for i in range(0, min(len(a),len(b)), 8192):
    pa=a[i:i+8192]; pb=b[i:i+8192]
    fa=struct.unpack_from('<H', pa, 8192-8)[0]; fb=struct.unpack_from('<H', pb, 8192-8)[0]
    if (fa & 256) or (fb & 256):
        if (fa & 256) != (fb & 256): d['freed-mismatch']+=1
        continue
    if pa[24:]!=pb[24:]: d[(fa,fb)]+=1
    else: s[fa]+=1
print(sys.argv[3], "sizes", len(a), len(b), "live differing:", dict(d), "live identical:", dict(s))
