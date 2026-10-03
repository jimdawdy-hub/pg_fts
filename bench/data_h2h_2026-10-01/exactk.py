import subprocess,sys
port,binarm=sys.argv[1],sys.argv[2]
def q(sql):
    r=subprocess.run([f"/nvme/pg{binarm}/bin/psql","-h","/tmp","-p",port,"-U","postgres","-X","-q","-At","-c",sql],capture_output=True,text=True)
    return r.stdout.strip()
bad=0;tot=0
for t in ['slovakia | hungary','slovakia | hungary | poland','year | hungary','war | peace','united | kingdom','river | mountain','music | album']:
    nall=int(q(f"SELECT count(*) FROM docs WHERE d @@@ to_ftsquery('english','{t}')"))
    cap=min(nall,20000)
    full=q(f"SELECT string_agg(round(score::numeric,9)::text, ',' ORDER BY score DESC) FROM fts_search('docs_fts', to_ftsquery('english','{t}'), {cap})").split(',')
    for k in [1,3,10,100]:
        got=q(f"SELECT string_agg(round(score::numeric,9)::text, ',' ORDER BY score DESC) FROM fts_search('docs_fts', to_ftsquery('english','{t}'), {k})").split(',')
        tot+=1; ok = got==full[:k]; bad+= (0 if ok else 1)
        if not ok: print(f"MISS {t!r} k={k}: got[-1]={got[-1]} want[-1]={full[k-1]}")
print(f"arm={binarm} exact {tot-bad}/{tot}")
