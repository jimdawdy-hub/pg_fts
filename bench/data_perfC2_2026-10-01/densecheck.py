import subprocess,sys
port,arm=sys.argv[1],sys.argv[2]
def q(sql,guc):
    r=subprocess.run([f"/nvme/pg{arm}/bin/psql","-h","/tmp","-p",port,"-U","postgres","-X","-q","-At","-c",f"SET pg_fts.dense_score_min_df={guc}; SET enable_seqscan=off; SET enable_bitmapscan=off;","-c",sql],capture_output=True,text=True)
    if r.returncode: print("ERR",r.stderr[:200]); sys.exit(1)
    return r.stdout.strip().splitlines()[-1] if r.stdout.strip() else ""
terms=['year','time','also','new','first','american','state','film','world','war','city','school','album','united','music','season']
bad=tot=0
for t in terms:
    df=int(q(f"SELECT count(*) FROM docs WHERE d @@@ to_ftsquery('english','{t}')",0))
    for k in [1,10,100,1000]:
        s=f"SELECT string_agg(id::text||':'||(d <=> to_ftsquery('english','{t}'))::text, ',') FROM (SELECT id, d FROM docs WHERE d @@@ to_ftsquery('english','{t}') ORDER BY d <=> to_ftsquery('english','{t}') LIMIT {k}) s"
        w=q(s,0); dn=q(s,1)
        f1=q(f"SELECT string_agg(ctid::text||':'||score::text, ',') FROM fts_search('docs_fts', to_ftsquery('english','{t}'), {k})",0)
        f2=q(f"SELECT string_agg(ctid::text||':'||score::text, ',') FROM fts_search('docs_fts', to_ftsquery('english','{t}'), {k})",1)
        tot+=1; ok=(w==dn and f1==f2 and len(w)>0)
        if not ok: bad+=1; print(f"DIFF {t} df={df} k={k} orderby_eq={w==dn} fts_search_eq={f1==f2}")
    print(f"{t:10} df={df:7d} ok")
print(f"arm={arm} identical {tot-bad}/{tot}")
