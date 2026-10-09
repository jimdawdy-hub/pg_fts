#!/bin/bash
# Approach A benchmark, pg_fts host (bench/PROTOCOL_A_2026-10-07.md).
# usage: fts_ab.sh <outdir>      both .so in /nvme/pg_fts_110.so and /nvme/pg_fts_a.so
set -uo pipefail
OUT=$1; mkdir -p $OUT
B=/nvme/pg17/bin; D=/nvme/pgdata; LIB=$($B/pg_config --pkglibdir)
P="$B/psql -h /tmp -U postgres -X -q -At -v ON_ERROR_STOP=1"
log() { echo "[$(date -u +%T)] $*" | tee -a $OUT/run.log; }
use() {  # switch the installed binary and restart (same data, same index files)
  $B/pg_ctl -D $D -w stop >/dev/null 2>&1; cp /nvme/pg_fts_$1.so $LIB/pg_fts.so
  $B/pg_ctl -D $D -l $D/server.log -w start >/dev/null; ARM=$1; }
log "host=<host> arch=$(uname -m) cpu=$(lscpu | sed -n 's/^Model name: *//p') nproc=$(nproc) pg=$($B/postgres --version)"
log "corpus md5=$(md5sum /nvme/c.tsv | cut -c1-32) rows=$($P -c 'select count(*) from docs')"
log "so 110=$(md5sum /nvme/pg_fts_110.so | cut -c1-8) a=$(md5sum /nvme/pg_fts_a.so | cut -c1-8) a_tree=$(cat /tmp/fts_a.commit 2>/dev/null)"
$P -c "CREATE EXTENSION IF NOT EXISTS pg_fts" -c "CREATE EXTENSION IF NOT EXISTS pg_prewarm" -c "CREATE EXTENSION IF NOT EXISTS pg_buffercache" >/dev/null
log "ext $($P -c "SELECT extversion FROM pg_extension WHERE extname='pg_fts'")"

# ---- builds ----  (SKIP_BUILDS=1: reuse the indexes of a previous run; run.log keeps their numbers)
if [ "${SKIP_BUILDS:-0}" != 1 ]; then
-------------------------------------------------------------------
# (a) expression index on the raw table: analysis inside the build, like the other engines
for arm in 110 a; do use $arm
  $P -c "DROP INDEX IF EXISTS docs_expr" >/dev/null
  s=$(date +%s.%N); $P -c "SET client_min_messages=warning" -c "CREATE INDEX docs_expr ON docs USING fts (to_ftsdoc('english', content))"; e=$(date +%s.%N)
  sz=$($P -c "select pg_relation_size('docs_expr')")
  s2=$(date +%s.%N); $P -c "SET client_min_messages=warning" -c "SELECT fts_vacuum('docs_expr')" >/dev/null; e2=$(date +%s.%N)
  log "arm=$arm expr_build_s=$(echo "$e-$s"|bc) size_after_build=$sz fts_vacuum_s=$(echo "$e2-$s2"|bc) size=$($P -c "select pg_relation_size('docs_expr')")"
  $P -c "DROP INDEX docs_expr" >/dev/null
done
# (b) stored column, as 1.10.0 measured it (the fill is timed separately, once)
s=$(date +%s.%N); $P -c "ALTER TABLE docs ADD COLUMN d ftsdoc" -c "UPDATE docs SET d = to_ftsdoc('english', content)" -c "VACUUM (FREEZE, ANALYZE) docs" >/dev/null; log "column_fill_s=$(echo "$(date +%s.%N)-$s"|bc)"
for arm in 110 a; do use $arm
  for pos in off on; do ix=docs_$( [ $pos = on ] && echo pos || echo idx )_$arm
    $P -c "DROP INDEX IF EXISTS $ix" >/dev/null
    s=$(date +%s.%N); $P -c "SET client_min_messages=warning" -c "CREATE INDEX $ix ON docs USING fts (d) WITH (positions = $pos)"; e=$(date +%s.%N)
    sz=$($P -c "select pg_relation_size('$ix')")
    s2=$(date +%s.%N); $P -c "SET client_min_messages=warning" -c "SELECT fts_vacuum('$ix')" >/dev/null; e2=$(date +%s.%N)
    log "arm=$arm positions=$pos column_build_s=$(echo "$e-$s"|bc) size_after_build=$sz fts_vacuum_s=$(echo "$e2-$s2"|bc) size=$($P -c "select pg_relation_size('$ix')")"
  done
done
# measure on the indexes the approach-a arm built (both arms read them: no format change);
# drop the 1.10.0-built copies so the planner has one choice per positions setting
$P -c "DROP INDEX docs_idx_110" -c "DROP INDEX docs_pos_110" >/dev/null
$P -c "ALTER INDEX docs_idx_a RENAME TO docs_idx" -c "ALTER INDEX docs_pos_a RENAME TO docs_pos" >/dev/null
log "measuring on docs_idx=$($P -c "select pg_relation_size('docs_idx')") docs_pos=$($P -c "select pg_relation_size('docs_pos')") (built by arm a)"

fi
# a restart (SKIP_BUILDS=1) after the throughput phase dropped docs_pos: rebuild it with arm a
if [ "${SKIP_BUILDS:-0}" = 1 ] && [ -z "$($P -c "SELECT to_regclass('docs_pos')")" ]; then
  use a; s=$(date +%s.%N); $P -c "SET client_min_messages=warning" -c "CREATE INDEX docs_pos ON docs USING fts (d) WITH (positions = on)"
  log "restart: rebuilt docs_pos with arm a in $(echo "$(date +%s.%N)-$s"|bc) s, size=$($P -c "select pg_relation_size('docs_pos')")"
fi
# ---- bands ------------------------------------------------------------------------
r() { echo "SELECT id FROM docs WHERE d @@@ to_ftsquery('english','$1') ORDER BY d <=> to_ftsquery('english','$1') LIMIT $2"; }
# name;index-to-hide;query;k   (';' separated: queries contain '|')
BANDS=("rare_k10;docs_pos;slovakia;10" "mid_k10;docs_pos;hungary;10" "common_k10;docs_pos;year;10" "common_k100;docs_pos;year;100"
       "and_k10;docs_pos;slovakia & hungary;10" "or_k10;docs_pos;slovakia | hungary;10"
       "and_common_k10;docs_pos;united & states;10" "and_ww_k10;docs_pos;world & war;10"
       "or4_k10;docs_pos;film | music | album | band;10"
       "phrase_k10;docs_idx;\"united states\";10" "phrase_ww_k10;docs_idx;\"world war\";10")
hide() { echo "BEGIN; UPDATE pg_index SET indisvalid = false WHERE indexrelid = '$1'::regclass;"; }

# correctness gate: both arms return the same ids and (within 1e-9) the same distances
for arm in 110 a; do use $arm
  for bq in "${BANDS[@]}"; do IFS=';' read n hx q k <<< "$bq"
    ix=$([ $hx = docs_pos ] && echo docs_idx || echo docs_pos)
    # ids in ORDER BY order from the ranked index scan, then the index's OWN scores
    # (fts_search; a visible d <=> q is the per-row fallback, not the index score)
    { hide $hx; echo "SET LOCAL enable_seqscan=off; SET LOCAL enable_bitmapscan=off;"
      echo "SELECT string_agg(id::text, ',') FROM ($(r "$q" $k)) s;"
      echo "SELECT string_agg(ctid::text || ':' || round(score::numeric, 9)::text, ',') FROM fts_search('$ix', to_ftsquery('english','$q'), $k);"
      echo "ROLLBACK;"; } > /tmp/g.sql
    $P -f /tmp/g.sql 2>&1 | grep -v -E '^(BEGIN|UPDATE|SET|ROLLBACK)' > $OUT/gate_${arm}_$n.txt
  done
  echo "count_common $($P -c "SELECT count(*) FROM docs WHERE d @@@ to_ftsquery('english','year')")" > $OUT/gate_${arm}_count.txt
done
ok=0; bad=0
for f in $OUT/gate_*.txt; do grep -q ERROR $f && { bad=$((bad+1)); log "GATE ERROR in $f"; }; done
for bq in "${BANDS[@]}" "count;x;x;x"; do n=${bq%%;*}
  if cmp -s $OUT/gate_110_$n.txt $OUT/gate_a_$n.txt; then ok=$((ok+1)); else
    # same scores in the same order is a tie reorder; anything else is a failure
    a=$(tail -n 1 $OUT/gate_110_$n.txt | tr ',' '\n' | sed 's/.*://' | md5sum); b=$(tail -n 1 $OUT/gate_a_$n.txt | tr ',' '\n' | sed 's/.*://' | md5sum)
    [ "$a" = "$b" ] && { ok=$((ok+1)); log "gate $n: tie order differs, scores identical"; } || { bad=$((bad+1)); log "GATE FAIL $n"; }
  fi
done
for f in $OUT/gate_a_*.txt; do [ -s $f ] && ! grep -q '^$' $f || { bad=$((bad+1)); log "GATE EMPTY $f"; }; done
log "gate: $ok bands identical, $bad differ"
# or4_k10 (4 terms, MaxScore) is EXPECTED to differ: 1.10.0's MaxScore split returned none of the
# true top-10 (CHANGELOG, Unreleased).  Arm a is checked against the exhaustive oracle instead
# (or4_oracle.txt, below); 1.10.0 is not timed on that band (protocol: a band whose reference
# check fails is not timed).
if [ $bad -eq 1 ] && ! cmp -s $OUT/gate_110_or4_k10.txt $OUT/gate_a_or4_k10.txt; then
  use a; python3 /tmp/mt_oracle.py "film | music | album | band" > $OUT/or4_oracle.txt 2>&1
  if grep -q "TOTAL 3 cases, 0 differ" $OUT/or4_oracle.txt; then
    bad=0; log "or4_k10: 1.10.0 differs (the MaxScore bug); arm a == exhaustive oracle ($(tail -n 1 $OUT/or4_oracle.txt)); 1.10.0 not timed on or4_k10"
    SKIP110_OR4=1
  fi
fi
[ $bad -eq 0 ] || { log "GATE FAILED: not timing"; exit 1; }

# warm latency: 3 passes per band per arm, alternating arms within each pass
$P -c "SELECT pg_prewarm('docs'), pg_prewarm('docs_idx'), pg_prewarm('docs_pos')" >/dev/null
for pass in 1 2 3; do for arm in 110 a; do use $arm
  $P -c "SELECT pg_prewarm('docs'), pg_prewarm('docs_idx'), pg_prewarm('docs_pos')" >/dev/null
  for bq in "${BANDS[@]}" "count_common;docs_pos;COUNT;0"; do IFS=';' read n hx q k <<< "$bq"
    [ "$arm" = 110 ] && [ "$n" = or4_k10 ] && [ "${SKIP110_OR4:-0}" = 1 ] && continue
    if [ "$q" = COUNT ]; then sql="SELECT count(*) FROM docs WHERE d @@@ to_ftsquery('english','year')"; else sql="SELECT count(*) FROM ($(r "$q" $k)) s"; fi
    { hide $hx; echo "SET LOCAL enable_seqscan=off; SET LOCAL enable_bitmapscan=off;"; echo '\timing on'; for i in 1 2 3 4 5 6 7 8; do echo "$sql;"; done; echo "ROLLBACK;"; } > /tmp/b.sql
    $P -f /tmp/b.sql > /tmp/b.out 2>&1
    ts=$(sed -n 's/^Time: \([0-9.]*\) ms.*/\1/p' /tmp/b.out | head -n 8 | tr '\n' ' ')
    med=$(echo "$ts" | tr ' ' '\n' | grep . | tail -5 | sort -n | sed -n 3p)
    echo "pass=$pass arm=$arm band=$n rows=$(grep -v -E '^(Time|BEGIN|UPDATE|SET|ROLLBACK)' /tmp/b.out | sort -u | tr '\n' ',') median_last5=$med raw=[$ts]" | tee -a $OUT/latency.txt
  done
done; done
log LAT_DONE

# cold band: autoprewarm off, drop caches, one query, 5 reps, median of EXPLAIN execution time
$P -c "ALTER SYSTEM SET pg_prewarm.autoprewarm = off" >/dev/null; rm -f $D/autoprewarm.blocks
for eic in 1 16; do $P -c "ALTER SYSTEM SET effective_io_concurrency = $eic" >/dev/null
  for arm in 110 a; do
    for bq in "rare_k10;docs_pos;slovakia;10" "common_k10;docs_pos;year;10" "and_common_k10;docs_pos;united & states;10"; do IFS=';' read n hx q k <<< "$bq"
      vals=""
      for rep in 1 2 3 4 5; do
        use $arm; $B/pg_ctl -D $D -w stop >/dev/null 2>&1; sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
        $B/pg_ctl -D $D -l $D/server.log -w start >/dev/null
        $P -c "SELECT to_ftsquery('english','x')" >/dev/null
        v=$({ hide $hx; echo "SET LOCAL enable_seqscan=off; SET LOCAL enable_bitmapscan=off;"; echo "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) $(r "$q" $k);"; echo "ROLLBACK;"; } | $P -f - 2>&1 | grep -v -E '^(BEGIN|UPDATE|SET|ROLLBACK)' | python3 -c "import json,sys; j=json.loads(sys.stdin.read())[0]; p=j['Plan']; print('%.2f/%d' % (j['Execution Time'], p.get('Shared Read Blocks',0)))")
        vals="$vals $v"
      done
      med=$(echo $vals | tr ' ' '\n' | sort -t/ -k1 -n | sed -n 3p)
      echo "eic=$eic arm=$arm band=$n cold_median_ms/reads=$med all=[$vals]" | tee -a $OUT/cold.txt
    done
  done
done
$P -c "ALTER SYSTEM RESET effective_io_concurrency" -c "ALTER SYSTEM RESET pg_prewarm.autoprewarm" >/dev/null
log COLD_DONE

# throughput: settled (CHECKPOINT, sync, 60 s idle) then pgbench 16/32/64, 30 s, 2 passes;
# on the non-positional index only (the release default), as 1.10.0
$P -c "DROP INDEX docs_pos" >/dev/null
for arm in 110 a; do use $arm
  $P -c "SELECT pg_prewarm('docs'), pg_prewarm('docs_idx')" >/dev/null
  $P -c "CHECKPOINT" >/dev/null; sync; sleep 60
  for bq in "rare_k10;slovakia;10" "mid_k10;hungary;10" "common_k10;year;10" "and_common_k10;united & states;10" "count_common;COUNT;0"; do IFS=';' read n q k <<< "$bq"
    if [ "$q" = COUNT ]; then echo "SELECT count(*) FROM docs WHERE d @@@ to_ftsquery('english','year');" > /tmp/w_$n.sql; else echo "SELECT count(*) FROM ($(r "$q" $k)) s;" > /tmp/w_$n.sql; fi
    PGOPTIONS="-c enable_seqscan=off -c enable_bitmapscan=off" $B/pgbench -h /tmp -U postgres -n -f /tmp/w_$n.sql -c 8 -j 8 -T 10 postgres >/dev/null 2>&1
    for pass in 1 2; do line="arm=$arm pass=$pass band=$n"
      for c in 16 32 64; do j=$(( c < 8 ? c : 8 ))
        line="$line c$c=$(PGOPTIONS="-c enable_seqscan=off -c enable_bitmapscan=off" $B/pgbench -h /tmp -U postgres -n -f /tmp/w_$n.sql -c $c -j $j -T 30 postgres 2>&1 | sed -n 's/^tps = \([0-9.]*\).*/\1/p')"
      done; echo "$line" | tee -a $OUT/tps.txt
    done
  done
done
log ALL_DONE
