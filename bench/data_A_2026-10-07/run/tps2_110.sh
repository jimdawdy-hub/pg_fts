#!/bin/bash
# Throughput re-run, identical for every engine: CHECKPOINT + sync + 60 s settle + prewarm, then
# pgbench 16/32/64 clients x 30 s x 2 passes after a 10 s warm-up at 8 (bench/PROTOCOL_110_2026-10-07.md).
# usage: tps2.sh <fts|pgts|psearch|vchord> <outfile>
ENG=$1; OUT=$2; B=/nvme/pg17/bin; P="$B/psql -h /tmp -U postgres -X -q -At"
export PGOPTIONS="-c default_text_search_config=english"
case $ENG in
fts) r(){ echo "SELECT count(*) FROM (SELECT id FROM docs WHERE d @@@ to_ftsquery('english','$1') ORDER BY d <=> to_ftsquery('english','$1') LIMIT 10) s;"; }
     CNT="SELECT count(*) FROM docs WHERE d @@@ to_ftsquery('english','year');" ;;
pgts) r(){ echo "SELECT count(*) FROM (SELECT id FROM docs ORDER BY content <@> to_bm25query('$1','docs_idx') LIMIT 10) s;"; }; CNT="" ;;
psearch) r(){ echo "SELECT count(*) FROM (SELECT id FROM docs WHERE content ||| '$1' ORDER BY pdb.score(id) DESC LIMIT 10) s;"; }
     CNT="SELECT count(*) FROM docs WHERE content ||| 'year';" ;;
vchord) r(){ echo "SELECT count(*) FROM (SELECT id FROM docs ORDER BY emb <&> to_bm25query('docs_idx', tokenize('$1', 'en')) LIMIT 10) s;"; }; CNT="" ;;
esac
r slovakia > /tmp/t_rare_k10.sql; r hungary > /tmp/t_mid_k10.sql; r year > /tmp/t_common_k10.sql; [ -n "$CNT" ] && echo "$CNT" > /tmp/t_count_common.sql
$P -c "CHECKPOINT"; sync; sleep 60
$P -c "SELECT pg_prewarm('docs'), pg_prewarm('docs_idx')" >/dev/null
echo "engine=$ENG $(date -u +%FT%TZ) loadavg=$(cut -d' ' -f1-3 /proc/loadavg)" | tee $OUT
for n in rare_k10 mid_k10 common_k10 count_common; do [ -f /tmp/t_$n.sql ] || continue
  echo "$n rows=$($P -f /tmp/t_$n.sql | tail -1)" | tee -a $OUT
  $B/pgbench -h /tmp -U postgres -n -f /tmp/t_$n.sql -c 8 -j 8 -T 10 postgres >/dev/null 2>&1
  for pass in 1 2; do line="pass=$pass band=$n"
    for c in 16 32 64; do j=$(( c < 8 ? c : 8 ))
      line="$line c$c=$($B/pgbench -h /tmp -U postgres -n -f /tmp/t_$n.sql -c $c -j $j -T 30 postgres 2>&1 | sed -n 's/^tps = \([0-9.]*\).*/\1/p')"
    done; echo "$line" | tee -a $OUT
  done
done
echo TPS2_DONE | tee -a $OUT
