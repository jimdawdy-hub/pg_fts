# Two-pass: pass 1 visits blocks in DESCENDING bound order until k postings are scored, which
# seeds a sound threshold (the k-th best score found so far is <= the true k-th best). Pass 2
# walks in docid order with that seed. Reports total postings scored.
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
        blocks.append((i, score(T,q8(x),idf)))
    out={"term":term,"df":df}
    for k in (10,100):
        order=sorted(range(len(blocks)), key=lambda j:-blocks[j][1])
        h=[]; seen=set(); scored=0
        for j in order:                       # seed: highest-bound blocks first
            if len(h)==k and blocks[j][1] < h[0]: break
            i=blocks[j][0]; seen.add(j)
            for s in sc[i:i+128]:
                scored+=1
                if len(h)<k: heapq.heappush(h,s)
                elif s>h[0]: heapq.heapreplace(h,s)
        out[f"k{k}"]={"scored":scored,"pct_scored":round(100*scored/df,2),"blocks_visited":len(seen),"exact": sorted(h)==sorted(sorted(sc,reverse=True)[:k])}
    print(json.dumps(out), flush=True)
