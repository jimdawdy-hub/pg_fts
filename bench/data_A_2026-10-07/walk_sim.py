# Realistic skip count: walk blocks in docid order keeping a running top-k heap (as the scan
# does). A block is skipped when heap is full and bound < current threshold (strict: equal
# scores can still enter by TID tie-break). Reports postings scored (vs df) per bound.
import subprocess, sys, math, json, heapq
exec(open('/tmp/skip_probe.py').read().split("for term in sys.argv[1:]:")[0])
for term in sys.argv[1:]:
    lex=q(f"SELECT to_ftsquery('english','{term}')::text").strip().strip("'")
    rows=q(f"""SELECT (ctid::text::point)[0]::bigint*291+(ctid::text::point)[1]::bigint,
                      (regexp_match(d::text, '(?:^| )''?{lex}''?:([0-9]+)'))[1]::int, ftsdoc_length(d)
               FROM docs WHERE d @@@ to_ftsquery('english','{term}') ORDER BY 1""")
    post=[tuple(int(x) for x in l.split("\t")) for l in rows.strip().split("\n") if l]
    df=len(post); idf=math.log(1+(N-df+0.5)/(df+0.5))
    sc=[score(tf,q8(dl),idf) for _,tf,dl in post]
    blocks=[]
    for i in range(0,df,128):
        blk=post[i:i+128]; T=max(t for _,t,_ in blk)
        x=math.floor(T*min(q8(d)/t for _,t,d in blk))
        blocks.append((i, score(T,q8(min(d for _,_,d in blk)),idf), score(T,q8(x),idf)))
    out={"term":term,"df":df,"blocks":len(blocks)}
    for k in (10,100):
        for name,bi in (("cur",1),("dleff",2)):
            h=[]; scored=0; skipped=0
            for blk in blocks:
                i=blk[0]
                if len(h)==k and blk[bi] < h[0]: skipped+=1; continue
                for s in sc[i:i+128]:
                    scored+=1
                    if len(h)<k: heapq.heappush(h,s)
                    elif s>h[0]: heapq.heapreplace(h,s)
            out[f"k{k}_{name}"]={"scored":scored,"pct_scored":round(100*scored/df,2),"blocks_skipped":skipped}
    print(json.dumps(out), flush=True)
