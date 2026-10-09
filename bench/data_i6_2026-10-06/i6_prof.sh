#!/bin/bash
# differential profile: per-transaction CPU cost by symbol at c=16 vs c=64
B=/nvme/pgs/bin; export PATH=$B:$PATH
for c in 16 64; do j=8
  pgbench -h /tmp -p 55440 -U postgres -n -f /tmp/w_rare.sql -c $c -j $j -T 22 postgres > /tmp/pgb_$c.out 2>&1 &
  PB=$!
  sleep 5
  vmstat 1 12 > /tmp/vm_$c.txt &
  sudo perf record -a -g -F 499 -e cpu-clock -o /tmp/i6_$c.data -- sleep 10 >/dev/null 2>&1
  wait $PB
  tps=$(sed -n 's/^tps = \([0-9.]*\).*/\1/p' /tmp/pgb_$c.out)
  echo "c=$c tps=$tps"
  awk 'NR>3{us+=$13; sy+=$14; id+=$15; cs+=$12; r+=$1; n++} END{printf "  vmstat avg: r=%.0f cs/s=%.0f us=%.0f sy=%.0f id=%.0f\n", r/n, cs/n, us/n, sy/n, id/n}' /tmp/vm_$c.txt
done
