import subprocess,sys
def q(port,sql):
    return subprocess.run(["/nvme/pga/bin/psql","-h","/tmp","-p",str(port),"-U","postgres","-X","-q","-At","-c",sql],capture_output=True,text=True).stdout.strip()
def lst(port,t,k):
    s=q(port,f"SET enable_seqscan=off; SELECT string_agg(id::text||':'||round((1/(d <=> to_ftsquery('english','{t}'))-1)::numeric,9), ',') FROM (SELECT id,d FROM docs WHERE d @@@ to_ftsquery('english','{t}') ORDER BY d <=> to_ftsquery('english','{t}') LIMIT {k}) s").splitlines()[-1]
    return [(int(x.split(':')[0]),float(x.split(':')[1])) for x in s.split(',')]
bad=0
for t in ['slovakia','hungary','year','slovakia & hungary','slovakia | hungary','slovakia | hungary | poland','hung*']:
    for k in [10,100]:
        a=lst(55440,t,k); b=lst(55441,t,k)
        sa=[s for _,s in a]; sb=[s for _,s in b]
        same_ids=[i for i,_ in a]==[i for i,_ in b]
        scores_equal = sa==sb
        # set difference must only be among docs tied at the k-th score
        da=set(i for i,_ in a)-set(i for i,_ in b); db=set(i for i,_ in b)-set(i for i,_ in a)
        kth=sa[-1] if sa else None
        tie_only = all(s==kth for i,s in a if i in da) and all(s==kth for i,s in b if i in db)
        ok = scores_equal and tie_only
        bad += 0 if ok else 1
        print(f"{t!r:32} k={k:3} n={len(a):3}/{len(b):3} ids_identical={same_ids} score_seq_identical={scores_equal} set_diff={len(da)} diffs_only_at_kth_tie={tie_only} {'OK' if ok else 'BAD'}")
print("BAD", bad)
