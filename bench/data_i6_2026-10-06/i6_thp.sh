#!/bin/bash
B=/nvme/pgs/bin; export PATH=$B:$PATH
echo "thp: $(cat /sys/kernel/mm/transparent_hugepage/enabled)"
for mode in madvise always madvise always; do
  echo $mode | sudo tee /sys/kernel/mm/transparent_hugepage/enabled >/dev/null
  out=""
  for c in 16 64; do
    tps=$(pgbench -h /tmp -p 55440 -U postgres -n -f /tmp/w_rare.sql -c $c -j 8 -T 15 postgres 2>&1 | sed -n 's/^tps = \([0-9.]*\).*/\1/p')
    out="$out c$c=$tps"
  done
  echo "thp=$mode $out  AnonHuge=$(grep AnonHugePages /proc/meminfo | awk '{print $2}')kB"
done
echo madvise | sudo tee /sys/kernel/mm/transparent_hugepage/enabled >/dev/null
