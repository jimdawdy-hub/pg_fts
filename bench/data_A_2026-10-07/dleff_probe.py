# Skippability with the format-free bound: store x = floor(T * min_i(dl_i/tf_i)) in the existing
# min_doclen field (dl_i = the length the scorer uses: quantized for sidecar segments); the
# unchanged reader computes w(T, quantize(x)) (quantize only lowers x -> still sound).
import subprocess, sys, math, json
exec(open('/tmp/skip_probe.py').read().split("for term in sys.argv[1:]:")[0])
for term in sys.argv[1:]:
    lex=q(f"SELECT to_ftsquery('english','{term}')::text").strip().strip("'")
    rows=q(f"""SELECT (ctid::text::point)[0]::bigint*291+(ctid::text::point)[1]::bigint,
                      (regexp_match(d::text, '(?:^| )''?{lex}''?:([0-9]+)'))[1]::int, ftsdoc_length(d)
               FROM docs WHERE d @@@ to_ftsquery('english','{term}') ORDER BY 1""")
    post=[tuple(int(x) for x in l.split("\t")) for l in rows.strip().split("\n") if l]
    df=len(post); idf=math.log(1+(N-df+0.5)/(df+0.5))
    sc=[score(tf,q8(dl),idf) for _,tf,dl in post]; srt=sorted(sc,reverse=True)
    out={"term":term,"blocks":(df+127)//128}; viol=0
    for k in (10,100):
        thr=srt[k-1]; s_cur=s_eff=s_ex=0
        for i in range(0,df,128):
            blk=post[i:i+128]; T=max(t for _,t,_ in blk)
            x=math.floor(T*min(q8(d)/t for _,t,d in blk))
            beff=score(T,q8(x),idf); bcur=score(T,q8(min(d for _,_,d in blk)),idf); bex=max(sc[i:i+128])
            if beff < bex*(1-1e-12): viol+=1
            s_cur+=bcur<=thr; s_eff+=beff<=thr; s_ex+=bex<=thr
        out[f"k{k}"]={"skip_cur":s_cur,"skip_dleff":s_eff,"skip_exact":s_ex}
    out["soundness_violations"]=viol
    print(json.dumps(out), flush=True)
