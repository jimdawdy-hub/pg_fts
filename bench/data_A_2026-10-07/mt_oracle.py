# Exhaustive multi-term reference with the index's arithmetic: tf from the stored ftsdoc, the
# QUANTIZED doclen the index scores with, idf from the index's N/df, k1=1.2 b=0.75, ties by TID.
# Compares the index's ranked ids (current binary) to the oracle for OR and AND queries.
import subprocess, sys, math, re
P=["/nvme/pgs/bin/psql","-h","/tmp","-p","55440","-U","postgres","-X","-q","-At","-F","\t"]
def q(sql): return subprocess.run(P+["-c",sql],capture_output=True,text=True,check=True).stdout
exec(open('/tmp/skip_probe.py').read().split("st=q(")[0].split("def q(sql)")[1].split("\n",1)[1])
st=q("SELECT ndocs, avgdl FROM fts_index_stats('docs_fts')").strip().split("\t"); N=float(st[0]); avgdl=float(st[1])
k1,b=1.2,0.75
bad=n=0
for qq in sys.argv[1:]:
    terms=re.split(r"\s*[|&]\s*", qq); isand="&" in qq
    lexes=[q(f"SELECT to_ftsquery('english','{t}')::text").strip().strip("'") for t in terms]
    dfs=[int(x) for x in q(f"SELECT unnest(fts_index_df('docs_fts', to_ftsquery('english','{qq}')))").split()]
    idfs=[math.log(1+(N-df+0.5)/(df+0.5)) for df in dfs]
    cols=", ".join(f"(regexp_match(d::text, '(?:^| )''{lx}'':([0-9]+)'))[1]::int" for lx in lexes)
    rows=q(f"SELECT id, (ctid::text::point)[0]::bigint*291+(ctid::text::point)[1]::bigint, ftsdoc_length(d), {cols} FROM docs WHERE d @@@ to_ftsquery('english','{qq}')")
    sc=[]
    for l in rows.strip().split("\n"):
        f=l.split("\t"); idv,docid,dl=int(f[0]),int(f[1]),int(f[2]); dq=q8(dl); s=0.0
        for j,x in enumerate(f[3:]):
            if x: tf=int(x); s+=idfs[j]*tf*(k1+1)/(tf+k1*(1-b+b*dq/avgdl))
        sc.append((-s,docid,idv))
    sc.sort()
    for k in (1,10,100):
        ref=[x[2] for x in sc[:k]]
        idx=[int(x) for x in q(f"SET enable_seqscan=off; SET enable_bitmapscan=off; SELECT id FROM docs WHERE d @@@ to_ftsquery('english','{qq}') ORDER BY d <=> to_ftsquery('english','{qq}') LIMIT {k}").split()]
        n+=1
        if idx!=ref:
            # float sums depend on addition order (the index adds per-term
            # contributions in cursor order): treat |dscore| <= 1e-9 as a tie.
            # Then the two lists must have equal score sequences and the same
            # set above the tie at the cut.
            byid={x[2]:-x[0] for x in sc}
            si=[byid[i] for i in idx]; sr=[-x[0] for x in sc[:k]]
            same=len(si)==len(sr) and all(abs(a-b)<=1e-9 for a,b in zip(si,sr))
            if same:
                ties_only=globals().get('ties_only',0)+1; globals()['ties_only']=ties_only
            else:
                bad+=1; print(f"DIFF {qq} k={k}\n  idx={idx[:8]}\n  ref={ref[:8]}", flush=True)
print(f"TOTAL {n} cases, {bad} differ, {globals().get('ties_only',0)} float-tie order only")
