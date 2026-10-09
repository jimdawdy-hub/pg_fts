#!/bin/bash
B=/nvme/pgs/bin; export PATH=$B:$PATH
for mb in 64 0 64 0; do
  echo "SET pg_fts.doclen_cache_mb = $mb;" > /tmp/w_set.sql
  out=""
  for c in 16 64; do
    tps=$(PGOPTIONS="-c pg_fts.doclen_cache_mb=$mb" pgbench -h /tmp -p 55440 -U postgres -n -f /tmp/w_rare.sql -c $c -j 8 -T 15 postgres 2>&1 | sed -n 's/^tps = \([0-9.]*\).*/\1/p')
    out="$out c$c=$tps"
  done
  echo "doclen_cache_mb=$mb $out"
done
