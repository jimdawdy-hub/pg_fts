# Sanity-check the probe against pg_fts itself: the probe's top-10 docids (by its own BM25,
# heap tf + quantized doclen) must equal pg_fts's ranked top-10 for the same term.
import subprocess, sys, math
P=["/nvme/pgs/bin/psql","-h","/tmp","-p","55440","-U","postgres","-X","-q","-At","-F","\t"]
def q(sql): return subprocess.run(P+["-c",sql],capture_output=True,text=True,check=True).stdout
exec(open('/tmp/skip_probe.py').read().split("for term in sys.argv[1:]:")[0].split("st=q(")[0])
st=q("SELECT ndocs, avgdl FROM fts_index_stats('docs_fts')").strip().split("\t"); N=float(st[0]); avgdl=float(st[1])
k1,b=1.2,0.75
def score(tf,dl,idf): return idf*tf*(k1+1)/(tf+k1*(1-b+b*dl/avgdl))
for term in sys.argv[1:]:
    lex=q(f"SELECT to_ftsquery('english','{term}')::text").strip().strip("'")
    rows=q(f"""SELECT id, (regexp_match(d::text, '(?:^| )''?{lex}''?:([0-9]+)'))[1]::int, ftsdoc_length(d)
               FROM docs WHERE d @@@ to_ftsquery('english','{term}')""")
    post=[tuple(int(x) for x in l.split("\t")) for l in rows.strip().split("\n") if l]
    df=len(post); idf=math.log(1+(N-df+0.5)/(df+0.5))
    mine=[p[0] for p in sorted(post, key=lambda p:-score(p[1],q8(p[2]),idf))[:10]]
    fts=[int(x) for x in q(f"SET enable_seqscan=off; SET enable_bitmapscan=off; SELECT id FROM docs WHERE d @@@ to_ftsquery('english','{term}') ORDER BY d <=> to_ftsquery('english','{term}') LIMIT 10").split()]
    print(term, "probe top10 == pg_fts top10 as sets:", set(mine)==set(fts), len(set(mine)&set(fts)))
