# exhaustive reference for ranked AND (and phrase on the positions index): every match scored
# from the stored ftsdoc tf, quantized doclen, the index's N/df/avgdl; compared by score sequence
import subprocess, sys, math, re
exec(open('/tmp/mt_oracle.py').read().split("bad=n=0")[0])
idxname=sys.argv[1]; other='docs_fts_pos' if idxname=='docs_fts' else 'docs_fts'
bad=n=0
for qq in sys.argv[2:]:
    terms=[t for t in re.split(r'[\s&"]+', qq) if t]
    lexes=[q(f"SELECT to_ftsquery('english','{t}')::text").strip().strip("'") for t in terms]
    dfs=[int(x) for x in q(f"SELECT unnest(fts_index_df('{idxname}', to_ftsquery('english','{qq}')))").split()]
    idfs=[math.log(1+(N-df+0.5)/(df+0.5)) for df in dfs]
    cols=", ".join(f"(regexp_match(d::text, '(?:^| )''{lx}'':([0-9]+)'))[1]::int" for lx in lexes)
    rows=q(f"SELECT id, ftsdoc_length(d), {cols} FROM docs WHERE d @@@ to_ftsquery('english','{qq}')")
    sc=[]
    for l in rows.strip().split("\n"):
        f=l.split("\t"); dq=q8(int(f[1])); s=0.0
        for j,x in enumerate(f[2:]):
            tf=int(x); s+=idfs[j]*tf*(k1+1)/(tf+k1*(1-b+b*dq/avgdl))
        sc.append(s)
    sc.sort(reverse=True)
    for k in (1,10,100):
        out=q(f"SET extra_float_digits=3; SELECT score FROM fts_search('{idxname}', to_ftsquery('english','{qq}'), {k})")
        got=[float(x) for x in out.split()]
        n+=1
        ok=len(got)==min(k,len(sc)) and all(abs(a-r)<=1e-6*max(1,r) for a,r in zip(got,sc[:k]))
        if not ok:
            bad+=1; print(f"DIFF {idxname} [{qq}] k={k} got={[round(x,5) for x in got[:5]]} ref={[round(x,5) for x in sc[:5]]} nmatch={len(sc)}", flush=True)
print(f"TOTAL {idxname} {n} cases, {bad} differ")
