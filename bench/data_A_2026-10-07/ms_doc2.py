import subprocess, sys
P=["/nvme/pgs/bin/psql","-h","/tmp","-p","55440","-U","postgres","-X","-q","-At","-F","\t"]
def q(sql): return subprocess.run(P+["-c",sql],capture_output=True,text=True,check=True).stdout
for qq in sys.argv[1:]:
    rq=f"""SELECT id, s FROM (SELECT id, ctid, fts_bm25(d, qq, n, a, ARRAY(SELECT unnest(fts_index_df('docs_fts', qq))::float8)) s
             FROM docs, to_ftsquery('english','{qq}') qq, (SELECT ndocs n, avgdl a FROM fts_index_stats('docs_fts')) st WHERE d @@@ qq) x ORDER BY s DESC, ctid LIMIT 10"""
    ref=[l.split("\t") for l in q(rq).strip().split("\n")]
    idx=q(f"SET enable_seqscan=off; SET enable_bitmapscan=off; SELECT id FROM docs WHERE d @@@ to_ftsquery('english','{qq}') ORDER BY d <=> to_ftsquery('english','{qq}') LIMIT 10").split()
    print(qq); print("  ref", [r[0] for r in ref]); print("  ref s", [round(float(r[1]),4) for r in ref]); print("  idx", idx)
