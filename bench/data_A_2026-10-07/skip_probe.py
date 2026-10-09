# Offline block-skippability (measurement only; no pg_fts code change).
# Rebuilds term T's posting list in docid order (heap TID order: block*291+offset, the
# same order pg_fts writes), cuts it into 128-posting blocks, and counts blocks whose
# score bound is <= the final top-k threshold (skippable without changing the answer):
#   cur   = score(block max tf, quantized(block min doclen))   -- the 1.10.0 header bound
#   exact = max over the block of score(tf, quantized(dl))     -- the Pareto-set bound
# tf and |D| come from the heap: tf = count of the stemmed term among ftsdoc lexemes,
# |D| = ftsdoc_length(d). Scores use pg_fts's own BM25 (k1=1.2, b=0.75), idf from N/df,
# and the length quantization pg_fts uses on disk.
import subprocess, sys, math, json
P=["/nvme/pgs/bin/psql","-h","/tmp","-p","55440","-U","postgres","-X","-q","-At","-F","\t"]
def q(sql): return subprocess.run(P+["-c",sql],capture_output=True,text=True,check=True).stdout
def q8(b):
    if b==0: return 0
    if b<=7: return b
    hb=b.bit_length()-1; e=hb-3; mant=(b>>e)&7; ee=e+1
    if ee>31: ee,mant=31,7
    byte=(ee<<3)|mant
    m=byte&7; ex=(byte>>3)&31
    return m if ex==0 else (8|m)<<(ex-1)
st=q("SELECT ndocs, avgdl FROM fts_index_stats('docs_fts')").strip().split("\t"); N=float(st[0]); avgdl=float(st[1])
k1,b=1.2,0.75
def score(tf,dl,idf): return idf*tf*(k1+1)/(tf+k1*(1-b+b*dl/avgdl))
for term in sys.argv[1:]:
    lex=q(f"SELECT to_ftsquery('english','{term}')::text").strip().strip("'")
    rows=q(f"""SELECT (ctid::text::point)[0]::bigint*291+(ctid::text::point)[1]::bigint,
                      (regexp_match(d::text, '(?:^| )''?{lex}''?:([0-9]+)'))[1]::int,
                      ftsdoc_length(d)
               FROM docs WHERE d @@@ to_ftsquery('english','{term}') ORDER BY 1""")
    post=[tuple(int(x) if x else 0 for x in l.split("\t")) for l in rows.strip().split("\n") if l]
    bad=sum(1 for p in post if p[1]==0)
    df=len(post); idf=math.log(1+(N-df+0.5)/(df+0.5))
    sc=[score(tf,q8(dl),idf) for _,tf,dl in post]
    srt=sorted(sc, reverse=True)
    out={"term":term,"lex":lex,"df":df,"tf_parse_fail":bad,"blocks":(df+127)//128}
    for k in (10,100):
        thr=srt[k-1]; cur_skip=ex_skip=0; ex_slack=[]
        for i in range(0,df,128):
            blk=post[i:i+128]; bs=sc[i:i+128]
            cur=score(max(t for _,t,_ in blk), q8(min(d for _,_,d in blk)), idf)
            ex=max(bs)
            cur_skip+= cur<=thr; ex_skip+= ex<=thr
        out[f"k{k}"]={"thr":round(thr,3),"skip_cur":cur_skip,"skip_exact":ex_skip,"max_block_cur":round(max(score(max(t for _,t,_ in post[i:i+128]), q8(min(d for _,_,d in post[i:i+128])), idf) for i in range(0,df,128)),3)}
    print(json.dumps(out), flush=True)
