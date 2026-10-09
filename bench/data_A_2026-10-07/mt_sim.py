# Simulate BMW for a two-term OR with (i) term-wide max_contrib as today (dl=0), vs (ii) term-wide
# max = max block bound (effective length). Count postings scored for k=10. Also AND.
import subprocess, sys, math, json, heapq
exec(open('/tmp/skip_probe.py').read().split("for term in sys.argv[1:]:")[0])
b_=0.75
def sc_(t,l,i): return i*t*(k1+1)/(t+k1*(1-b_+b_*l/avgdl))
def load(term):
    lex=q(f"SELECT to_ftsquery('english','{term}')::text").strip().strip("'")
    rows=q(f"""SELECT (ctid::text::point)[0]::bigint*291+(ctid::text::point)[1]::bigint,
               (regexp_match(d::text, '(?:^| )''?{lex}''?:([0-9]+)'))[1]::int, ftsdoc_length(d)
               FROM docs WHERE d @@@ to_ftsquery('english','{term}') ORDER BY 1""")
    post=[tuple(int(x) for x in l.split("\t")) for l in rows.strip().split("\n") if l]
    idf=math.log(1+(N-len(post)+0.5)/(len(post)+0.5))
    blocks=[]
    for i in range(0,len(post),128):
        blk=post[i:i+128]; T=max(t for _,t,_ in blk); x=math.floor(T*min(q8(d)/t for _,t,d in blk))
        blocks.append((blk[0][0], blk[-1][0], sc_(T,q8(x),idf)))
    return post, idf, blocks
for pair in sys.argv[1:]:
    a,c=pair.split("+"); A=load(a); C=load(c)
    res={"pair":pair}
    for mode in ("termmax_dl0","termmax_blocks"):
        tm=[]
        for P_,idf,bl in (A,C):
            mt=max(t for _,t,_ in P_)
            tm.append(idf*mt*(k1+1)/(mt+k1*(1-b_)) if mode=="termmax_dl0" else max(x for _,_,x in bl))
        # docid-ordered union walk with WAND pivot + BMW block check (simplified, exact)
        ia=ic=0; h=[]; scored=0
        pa,pc=A[0],C[0]; sa={d:sc_(t,q8(l),A[1]) for d,t,l in pa}; scc={d:sc_(t,q8(l),C[1]) for d,t,l in pc}
        # block lookup for a docid position
        def blk_of(bl, idx): return bl[idx//128][2]
        while ia<len(pa) or ic<len(pc):
            da=pa[ia][0] if ia<len(pa) else 1<<62; dc=pc[ic][0] if ic<len(pc) else 1<<62
            thr=h[0] if len(h)==10 else 0
            # sort cursors by docid, pivot
            cur=sorted([(da,0),(dc,1)])
            ms=0; piv=None
            for d,w in cur:
                if d>=1<<62: break
                ms+=tm[w]
                if ms>thr or len(h)<10: piv=d; break
            if piv is None: break
            # BMW: block bounds of cursors <= pivot
            bs=0
            if da<=piv: bs+=blk_of(A[2],ia)
            if dc<=piv: bs+=blk_of(C[2],ic)
            if len(h)==10 and bs<=thr:
                # skip: advance cursors <= pivot past pivot
                if da<=piv: ia+=1
                if dc<=piv: ic+=1
                continue
            if cur[0][0]==piv:
                s=0
                if da==piv: s+=sa[da]; ia+=1; scored+=1
                if dc==piv: s+=scc[dc]; ic+=1; scored+=1
                if len(h)<10: heapq.heappush(h,s)
                elif s>h[0]: heapq.heapreplace(h,s)
            else:
                if da<piv: ia+=1
                if dc<piv: ic+=1
        res[mode]={"postings_scored":scored,"of":len(pa)+len(pc)}
    print(json.dumps(res), flush=True)
