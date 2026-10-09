# Pareto-frontier size per 128-posting block over (tf up, quantized dl down), and the k=10
# skip count if only blocks with frontier <= K points get exact bounds (the rest keep the
# 1.10.0 corner bound).
import subprocess, sys, math, json, collections
exec(open('/tmp/skip_probe.py').read().split("for term in sys.argv[1:]:")[0])
def frontier(blk):
    pts=sorted({(t,q8(d)) for _,t,d in blk}, key=lambda p:(-p[0],p[1]))
    out=[]; best=None
    for t,d in pts:
        if best is None or d<best: out.append((t,d)); best=d
    return out
for term in sys.argv[1:]:
    lex=q(f"SELECT to_ftsquery('english','{term}')::text").strip().strip("'")
    rows=q(f"""SELECT (ctid::text::point)[0]::bigint*291+(ctid::text::point)[1]::bigint,
                      (regexp_match(d::text, '(?:^| )''?{lex}''?:([0-9]+)'))[1]::int, ftsdoc_length(d)
               FROM docs WHERE d @@@ to_ftsquery('english','{term}') ORDER BY 1""")
    post=[tuple(int(x) for x in l.split("\t")) for l in rows.strip().split("\n") if l]
    df=len(post); idf=math.log(1+(N-df+0.5)/(df+0.5))
    sc=[score(tf,q8(dl),idf) for _,tf,dl in post]; thr=sorted(sc,reverse=True)[9]
    hist=collections.Counter(); skip={1:0,2:0,3:0,4:0,99:0}; maxtf=0
    for i in range(0,df,128):
        blk=post[i:i+128]; fr=frontier(blk); hist[min(len(fr),9)]+=1; maxtf=max(maxtf,max(t for t,_ in fr))
        cur=score(max(t for _,t,_ in blk), q8(min(d for _,_,d in blk)), idf); ex=max(sc[i:i+128])
        for K in skip: skip[K]+= (ex if len(fr)<=K else cur) <= thr
    print(json.dumps({"term":term,"blocks":(df+127)//128,"frontier_hist":dict(sorted(hist.items())),"k10_skip_with_K":skip,"max_tf_on_frontier":maxtf}), flush=True)
