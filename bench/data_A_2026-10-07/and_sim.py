# Offline A2 measurement: for a 2-term AND (and phrase, which ranks the same AND set by
# bag-of-words BM25), how much work does a block-level conjunctive walk need?
#  - docs in the intersection, and their top-k threshold
#  - "aligned block pairs": for each block of the RARER term, the blocks of the other term
#    overlapping its docid range; skippable when bound_A(blk) + max bound_B(overlapping) <= thr
#  - best-first over rarer-term blocks by (bound_A + max overlapping bound_B)
import subprocess, sys, math, json, heapq, bisect
exec(open('/tmp/skip_probe.py').read().split("for term in sys.argv[1:]:")[0])
def postings(term):
    lex=q(f"SELECT to_ftsquery('english','{term}')::text").strip().strip("'")
    rows=q(f"""SELECT (ctid::text::point)[0]::bigint*291+(ctid::text::point)[1]::bigint,
                      (regexp_match(d::text, '(?:^| )''{lex}'':([0-9]+)'))[1]::int, ftsdoc_length(d)
               FROM docs WHERE d @@@ to_ftsquery('english','{term}') ORDER BY 1""")
    return [tuple(int(x) for x in l.split("\t")) for l in rows.strip().split("\n") if l]
def blocks(post, idf):
    out=[]
    for i in range(0,len(post),128):
        blk=post[i:i+128]; T=max(t for _,t,_ in blk)
        x=math.floor(T*min(q8(d)/t for _,t,d in blk))
        out.append((blk[0][0], blk[-1][0], score(T,q8(x),idf)))
    return out
a,bterm=sys.argv[1],sys.argv[2]
pa,pb=postings(a),postings(bterm)
if len(pa)>len(pb): a,bterm,pa,pb=bterm,a,pb,pa
ia=math.log(1+(N-len(pa)+0.5)/(len(pa)+0.5)); ib=math.log(1+(N-len(pb)+0.5)/(len(pb)+0.5))
ba,bb=blocks(pa,ia),blocks(pb,ib)
db={d:(t,dl) for d,t,dl in pb}
inter=[(score(t,q8(dl),ia)+score(db[d][0],q8(db[d][1]),ib), d) for d,t,dl in pa if d in db]
inter.sort(reverse=True)
bfirst=[x[0] for x in bb]
res={"rare":a,"df_rare":len(pa),"common":bterm,"df_common":len(pb),"intersection":len(inter),"blocks_rare":len(ba),"blocks_common":len(bb)}
for k in (10,100):
    thr=inter[k-1][0]
    # pair bound per rare block
    pb_bound=[]
    for (lo,hi,bd) in ba:
        j0=max(0,bisect.bisect_right(bfirst,lo)-1); j1=bisect.bisect_right(bfirst,hi)
        mb=max((bb[j][2] for j in range(j0,j1) if bb[j][1]>=lo), default=0.0)
        pb_bound.append((bd+mb, j1-j0))
    skip=sum(1 for s,_ in pb_bound if s<=thr)
    # best-first over rare blocks by pair bound: visit until next bound < k-th score found
    order=sorted(range(len(ba)), key=lambda i:-pb_bound[i][0]); h=[]; visited=0; cb=0
    byblk={}
    for i,(d,t,dl) in enumerate(pa): byblk.setdefault(i//128,[]).append((d,t,dl))
    for i in order:
        if len(h)==k and pb_bound[i][0] < h[0]: break
        visited+=1; cb+=pb_bound[i][1]
        for d,t,dl in byblk[i]:
            if d in db:
                s=score(t,q8(dl),ia)+score(db[d][0],q8(db[d][1]),ib)
                if len(h)<k: heapq.heappush(h,s)
                elif s>h[0]: heapq.heapreplace(h,s)
    res[f"k{k}"]={"thr":round(thr,4),"rare_blocks_skippable_docid_order":skip,"bestfirst_rare_blocks":visited,"bestfirst_common_blocks_touched":cb,"exact":sorted(h,reverse=True)==[x[0] for x in inter[:k]]}
print(json.dumps(res))
