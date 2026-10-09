#!/bin/bash
# Which pages differ between the prev and cur merged index? Keep both copies and compare per 8 KB page,
# classified by the page's flag bits (opaque at page end).
B=/nvme/pgs/bin; LIB=$($B/pg_config --pkglibdir); P="$B/psql -h /tmp -p 55440 -U postgres -X -q -At"
for v in prev cur; do
  $B/pg_ctl -D /nvme/bench_s -w stop >/dev/null 2>&1; cp /nvme/pg_fts_$v.so $LIB/pg_fts.so; $B/pg_ctl -D /nvme/bench_s -l /nvme/bench_s/server.log -w start >/dev/null
  $P -c "DROP INDEX IF EXISTS d400_off" >/dev/null 2>&1
  $P -c "SET max_parallel_maintenance_workers = 0; SET maintenance_work_mem = '64MB'; SET client_min_messages = warning" -c "CREATE INDEX d400_off ON docs400 USING fts (d) WITH (positions = off)" >/dev/null
  $P -c "CHECKPOINT" >/dev/null; f=$($P -c "SELECT pg_relation_filepath('d400_off')"); cat /nvme/bench_s/$f /nvme/bench_s/$f.[0-9] 2>/dev/null > /nvme/idx_$v.bin
  $P -c "SELECT fts_index_stats('d400_off')"
done
python3 - <<'PY'
import struct
a=open('/nvme/idx_prev.bin','rb').read(); b=open('/nvme/idx_cur.bin','rb').read()
print("sizes", len(a), len(b))
from collections import Counter
diff=Counter(); same=Counter(); first=None
for i in range(0, min(len(a),len(b)), 8192):
    pa=a[i:i+8192]; pb=b[i:i+8192]
    # pg_fts opaque: last bytes of page; flags is a uint16 after nextblk (uint32) -- read both layouts loosely
    fa=struct.unpack_from('<H', pa, 8192-8)[0]; fb=struct.unpack_from('<H', pb, 8192-8)[0]
    # ignore pd_lsn/pd_checksum (first 10 bytes)
    if pa[10:]!=pb[10:]:
        diff[(fa,fb)]+=1
        if first is None: first=i//8192
    else: same[fa]+=1
print("differing pages by (flags_prev, flags_cur):", dict(diff.most_common(8)))
print("identical pages by flags:", dict(same.most_common(8)), "first diff page", first)
PY
cp /nvme/pg_fts_cur.so $LIB/pg_fts.so; $B/pg_ctl -D /nvme/bench_s -w restart -l /nvme/bench_s/server.log >/dev/null
