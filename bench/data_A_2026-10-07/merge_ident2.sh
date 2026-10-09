#!/bin/bash
# (1) doclen_sidecar=off (v3 inline doclen: the per-posting collect path) and (2) a v4 index with
# tombstones merged by fts_vacuum: live pages must be byte-identical between prev and cur.
B=/nvme/pgs/bin; LIB=$($B/pg_config --pkglibdir); P="$B/psql -h /tmp -p 55440 -U postgres -X -q -At"
cat > /tmp/live_cmp.py <<'PY'
import struct, sys
from collections import Counter
a=open(sys.argv[1],'rb').read(); b=open(sys.argv[2],'rb').read()
d=Counter(); s=Counter()
for i in range(0, min(len(a),len(b)), 8192):
    pa=a[i:i+8192]; pb=b[i:i+8192]
    fa=struct.unpack_from('<H', pa, 8192-8)[0]; fb=struct.unpack_from('<H', pb, 8192-8)[0]
    if (fa & 256) or (fb & 256):
        if (fa & 256) != (fb & 256): d['freed-mismatch']+=1
        continue
    if pa[24:]!=pb[24:]: d[(fa,fb)]+=1
    else: s[fa]+=1
print(sys.argv[3], "sizes", len(a), len(b), "live differing:", dict(d), "live identical:", dict(s))
PY
for v in prev cur; do
  $B/pg_ctl -D /nvme/bench_s -w stop >/dev/null 2>&1; cp /nvme/pg_fts_$v.so $LIB/pg_fts.so; $B/pg_ctl -D /nvme/bench_s -l /nvme/bench_s/server.log -w start >/dev/null
  $P -c "DROP INDEX IF EXISTS d400_v3" -c "DROP TABLE IF EXISTS docs400t" >/dev/null 2>&1
  $P -c "SET max_parallel_maintenance_workers = 0; SET maintenance_work_mem = '64MB'; SET client_min_messages = warning" -c "CREATE INDEX d400_v3 ON docs400 USING fts (d) WITH (doclen_sidecar = off)" >/dev/null
  # tombstone case: copy, build, delete 10%, vacuum (tombstones), then fts_vacuum (merge drops them)
  $P -c "CREATE TABLE docs400t AS SELECT * FROM docs400" -c "VACUUM (FREEZE, ANALYZE) docs400t" >/dev/null
  $P -c "SET max_parallel_maintenance_workers = 0; SET maintenance_work_mem = '64MB'; SET client_min_messages = warning" -c "CREATE INDEX d400_t ON docs400t USING fts (d)" >/dev/null
  $P -c "DELETE FROM docs400t WHERE id % 10 = 3" -c "SET client_min_messages = warning" -c "VACUUM docs400t" >/dev/null
  $P -c "SET client_min_messages = warning" -c "SELECT fts_vacuum('d400_t')" >/dev/null
  $P -c "CHECKPOINT" >/dev/null
  for ix in d400_v3 d400_t; do f=$($P -c "SELECT pg_relation_filepath('$ix')"); cat /nvme/bench_s/$f /nvme/bench_s/$f.[0-9] 2>/dev/null > /nvme/idx_${ix}_$v.bin; done
  echo "$v t: stats=$($P -c "SELECT fts_index_stats('d400_t')") nseg=$($P -c "SELECT fts_index_nsegments('d400_t')") count_year=$($P -c "SELECT count(*) FROM docs400t WHERE d @@@ to_ftsquery('english','year')")"
done
python3 /tmp/live_cmp.py /nvme/idx_d400_v3_prev.bin /nvme/idx_d400_v3_cur.bin v3
python3 /tmp/live_cmp.py /nvme/idx_d400_t_prev.bin /nvme/idx_d400_t_cur.bin tomb
cp /nvme/pg_fts_cur.so $LIB/pg_fts.so; $B/pg_ctl -D /nvme/bench_s -w restart -l /nvme/bench_s/server.log >/dev/null
