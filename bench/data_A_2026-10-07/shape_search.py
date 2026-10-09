import math, itertools
k1,b=1.2,0.75
def q8(n):
    if n<=7: return n
    hb=n.bit_length()-1; e=hb-3; m=(n>>e)&7; ee=e+1; byte=(ee<<3)|m; mm=byte&7; ex=(byte>>3)&31
    return mm if ex==0 else (8|mm)<<(ex-1)
def build(pad0, tf_hot, tf_b2, pad_b2):
    docs={}
    for i in range(1,2561):
        t={}
        if i%10==0: t['m']=1
        if i%2==0:
            if 770<=i<=1024: t['n']=tf_hot
            elif i>1280: t['n']=tf_b2
            else: t['n']=1
        L=sum(t.values())
        if i<=256 and 'n' in t: t['z']=pad0          # n block 0: long docs -> low n bound
        elif i>1280 and 'm' in t: t['z']=pad_b2
        if not t: t['z']=1
        docs[i]={w:v for w,v in t.items() if v>0}
    return docs
def evaluate(docs):
    N=len(docs); dl={i:sum(t.values()) for i,t in docs.items()}; avg=sum(dl.values())/N
    df={w:sum(1 for t in docs.values() if w in t) for w in 'mnz'}
    idf={w:math.log(1+(N-df[w]+.5)/(df[w]+.5)) for w in df}
    def s(w,tf,l): return idf[w]*tf*(k1+1)/(tf+k1*(1-b+b*q8(l)/avg))
    def bound(w,blk):
        T=max(docs[i][w] for i in blk); x=math.floor(T*min(q8(dl[i])/docs[i][w] for i in blk)); return s(w,T,x)
    pn=[i for i in sorted(docs) if 'n' in docs[i]]; nb=[pn[j:j+128] for j in range(0,len(pn),128)]
    pm=[i for i in sorted(docs) if 'm' in docs[i]]; mb=[pm[:128],pm[128:]]
    if len(pm)!=256: return None
    nbnd=[bound('n',bk) for bk in nb]
    def ovl(lo,hi): return [j for j,bk in enumerate(nb) if bk[0] < hi and (j+1>=len(nb) or nb[j+1][0] > lo)]
    m0lo,m0hi=mb[0][0],mb[1][0]; m1lo=mb[1][0]
    o0=ovl(m0lo,m0hi); o1=ovl(m1lo,1<<60)
    true0=bound('m',mb[0])+max(nbnd[j] for j in o0); mut0=bound('m',mb[0])+nbnd[o0[0]]
    true1=bound('m',mb[1])+max(nbnd[j] for j in o1)
    sc={i:s('m',t['m'],dl[i])+s('n',t['n'],dl[i]) for i,t in docs.items() if 'm' in t and 'n' in t}
    best0=max(v for i,v in sc.items() if i<m0hi); best1=max(v for i,v in sc.items() if i>=m1lo)
    return dict(true0=true0,mut0=mut0,true1=true1,best0=best0,best1=best1)
for pad0,tf_hot,tf_b2,pad_b2 in itertools.product([10,20,40,80],[3,5,9],[1,2,3,5],[0,1,2,4]):
    r=evaluate(build(pad0,tf_hot,tf_b2,pad_b2))
    if not r: continue
    # want: visit block1 first (true1 > true0? no: mutant ordering) -> under mutant, block1 visited first iff true1 > mut0;
    # then threshold (k=1) = best1; mutant prunes block0 iff mut0 < best1; true answer in block0 iff best0 > best1
    if r['true1'] > r['mut0'] and r['mut0'] < r['best1'] < r['best0']:
        print(pad0,tf_hot,tf_b2,pad_b2,{k:round(v,4) for k,v in r.items()}); break
