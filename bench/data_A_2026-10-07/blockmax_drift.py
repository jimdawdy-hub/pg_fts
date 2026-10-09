# Option A1': store per block the exact BM25 max computed at WRITE time with the writer's
# avgdl (avgdl_w). At query time the true avgdl (avgdl_q) differs after inserts/deletes/merges.
# The stored max stays a sound UPPER bound iff we correct for drift. Model: the score of
# (tf,dl) under avgdl_q <= score under avgdl_w * f(avgdl_q/avgdl_w) for a closed-form f.
# Simplest sound correction: store the frontier's best-case in a form that is monotone in
# avgdl: score = idf*(k1+1)*tf / (tf + k1*(1-b) + k1*b*dl/avgdl). Larger avgdl => larger score.
# So max under avgdl_q <= max under max(avgdl_w, avgdl_q) -- i.e. a writer that stores the
# block's argmax (tf,dl) pair under a DESIGNATED avgdl is only exact at that avgdl.
# Measure: how tight is "max over block at avgdl*(1+eps)" vs exact, i.e. how much drift
# headroom costs, for eps in {0, 5%, 10%, 25%}, at k=10.
import subprocess, sys, math, json
exec(open('/tmp/skip_probe.py').read().split("for term in sys.argv[1:]:")[0])
def score_a(tf,dl,idf,adl): return idf*tf*(k1+1)/(tf+k1*(1-b+b*dl/adl))
for term in sys.argv[1:]:
    lex=q(f"SELECT to_ftsquery('english','{term}')::text").strip().strip("'")
    rows=q(f"""SELECT (ctid::text::point)[0]::bigint*291+(ctid::text::point)[1]::bigint,
                      (regexp_match(d::text, '(?:^| )''?{lex}''?:([0-9]+)'))[1]::int, ftsdoc_length(d)
               FROM docs WHERE d @@@ to_ftsquery('english','{term}') ORDER BY 1""")
    post=[tuple(int(x) for x in l.split("\t")) for l in rows.strip().split("\n") if l]
    df=len(post); idf=math.log(1+(N-df+0.5)/(df+0.5))
    sc=[score(tf,q8(dl),idf) for _,tf,dl in post]; thr10=sorted(sc,reverse=True)[9]; thr100=sorted(sc,reverse=True)[99]
    res={}
    for eps in (0.0,0.05,0.10,0.25):
        s10=s100=0
        for i in range(0,df,128):
            blk=post[i:i+128]
            bound=max(score_a(t,q8(d),idf,avgdl*(1+eps)) for _,t,d in blk)
            s10+= bound<=thr10; s100+= bound<=thr100
        res[f"eps{int(eps*100)}"]=(s10,s100)
    print(json.dumps({"term":term,"blocks":(df+127)//128,"skip_k10_k100":res}), flush=True)
