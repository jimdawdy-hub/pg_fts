# For a pure-OR query a|b, seed BMW's threshold with the k-th best SINGLE-term score among
# the terms' best-first top-k (sound: each doc's OR score >= its single-term score). Measure:
# fraction of blocks of each term whose block bound alone (+ max_contrib of the other) is below
# the seeded threshold, vs an unseeded threshold of 0. Also the AND case seed: for a & b the
# seed must come from AND candidates (unknown up front) -> not seeded here.
import subprocess, sys, math, json
exec(open('/tmp/skip_probe.py').read().split("for term in sys.argv[1:]:")[0])
def load(term):
    lex=q(f"SELECT to_ftsquery('english','{term}')::text").strip().strip("'")
    rows=q(f"""SELECT (ctid::text::point)[0]::bigint*291+(ctid::text::point)[1]::bigint,
               (regexp_match(d::text, '(?:^| )''?{lex}''?:([0-9]+)'))[1]::int, ftsdoc_length(d)
               FROM docs WHERE d @@@ to_ftsquery('english','{term}') ORDER BY 1""")
    post=[tuple(int(x) for x in l.split("\t")) for l in rows.strip().split("\n") if l]
    df=len(post); idf=math.log(1+(N-df+0.5)/(df+0.5))
    return post, idf
for pair in sys.argv[1:]:
    a,bb_=pair.split("+"); b_=0.75
    (pa,ia),(pb,ib)=load(a),load(bb_)
    sc_=lambda t,l,i: i*t*(k1+1)/(t+k1*(1-b_+b_*l/avgdl))
    da={d:sc_(t,q8(l),ia) for d,t,l in pa}; db={d:sc_(t,q8(l),ib) for d,t,l in pb}
    orsc=sorted(((da.get(d,0)+db.get(d,0)) for d in set(da)|set(db)), reverse=True)
    true_thr=orsc[9]
    seed=sorted(list(da.values())+list(db.values()), reverse=True)[9]
    def blocks(post,idf):
        out=[]
        for i in range(0,len(post),128):
            blk=post[i:i+128]; T=max(t for _,t,_ in blk); x=math.floor(T*min(q8(d)/t for _,t,d in blk))
            out.append(sc_(T,q8(x),idf))
        return out
    ba,bb=blocks(pa,ia),blocks(pb,ib)
    ma,mb=max(ba),max(bb)
    res={"pair":pair,"df":(len(pa),len(pb)),"true_k10_thr":round(true_thr,3),"seed":round(seed,3)}
    for nm,thr in (("seed",seed),("true",true_thr)):
        # a block of term a can be skipped if its bound + other's term-wide max < thr (conservative, BMW-style)
        res[f"skip_a_{nm}"]=sum(1 for x in ba if x+mb<thr); res[f"skip_b_{nm}"]=sum(1 for x in bb if x+ma<thr)
    res["blocks"]=(len(ba),len(bb))
    print(json.dumps(res), flush=True)
