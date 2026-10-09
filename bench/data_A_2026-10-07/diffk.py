import subprocess, sys, math, re
exec(open('/tmp/mt_oracle.py').read().split("bad=n=0")[0])
qq=sys.argv[1]; k=int(sys.argv[2])
terms=re.split(r"\s*[|&]\s*", qq)
lexes=[q(f"SELECT to_ftsquery('english','{t}')::text").strip().strip("'") for t in terms]
dfs=[int(x) for x in q(f"SELECT unnest(fts_index_df('docs_fts', to_ftsquery('english','{qq}')))").split()]
idfs=[math.log(1+(N-df+0.5)/(df+0.5)) for df in dfs]
cols=", ".join(f"(regexp_match(d::text, '(?:^| )''{lx}'':([0-9]+)'))[1]::int" for lx in lexes)
rows=q(f"SELECT id, (ctid::text::point)[0]::bigint*291+(ctid::text::point)[1]::bigint, ftsdoc_length(d), {cols} FROM docs WHERE d @@@ to_ftsquery('english','{qq}')")
sc={}
for l in rows.strip().split("\n"):
    f=l.split("\t"); idv,docid,dl=int(f[0]),int(f[1]),int(f[2]); dq=q8(dl); s=0.0
    for j,x in enumerate(f[3:]):
        if x: tf=int(x); s+=idfs[j]*tf*(k1+1)/(tf+k1*(1-b+b*dq/avgdl))
    sc[idv]=(s,docid)
ref=sorted(sc, key=lambda i:(-sc[i][0], sc[i][1]))[:k]
idx=[int(x) for x in q(f"SET enable_seqscan=off; SET enable_bitmapscan=off; SELECT id FROM docs WHERE d @@@ to_ftsquery('english','{qq}') ORDER BY d <=> to_ftsquery('english','{qq}') LIMIT {k}").split()]
for pos,(a,r) in enumerate(zip(idx,ref)):
    if a!=r:
        print("first divergence at rank", pos+1, "idx", a, sc[a], "ref", r, sc[r]); break
print("missing from idx:", [(i, round(sc[i][0],6)) for i in ref if i not in idx][:5])
print("extra in idx:", [(i, round(sc[i][0],6)) for i in idx if i not in ref][:5])
print("kth ref score", round(sc[ref[-1]][0],6))
