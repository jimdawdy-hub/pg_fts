#!/bin/bash
# Single-client latency, 1.10.0 release benchmark (bench/PROTOCOL_110_2026-10-07.md).
# usage: lat3.sh <fts|pgts|psearch|vchord> <outdir>   (expects /nvme/c.tsv loaded into docs by setup_cluster)
set -uo pipefail
ENG=$1; OUT=$2; mkdir -p $OUT
B=/nvme/pg17/bin; P="$B/psql -h /tmp -U postgres -X -q -At -v ON_ERROR_STOP=1"
log() { echo "[$(date -u +%T)] $*" | tee -a $OUT/run.log; }
log "engine=$ENG host=<host> arch=$(uname -m) cpu=$(lscpu | sed -n 's/^Model name: *//p') nproc=$(nproc) pg=$($B/postgres --version)"
log "corpus md5=$(md5sum /nvme/c.tsv | cut -c1-32) rows=$($P -c 'select count(*) from docs')"
case $ENG in
fts)
  log "ext $($P -c "CREATE EXTENSION IF NOT EXISTS pg_fts; SELECT extversion FROM pg_extension WHERE extname='pg_fts'") so=$(md5sum $($B/pg_config --pkglibdir)/pg_fts.so | cut -c1-8)"
  $P -c "ALTER TABLE docs ADD COLUMN d ftsdoc" -c "UPDATE docs SET d = to_ftsdoc('english', content)" -c "VACUUM (FREEZE, ANALYZE) docs"
  s=$(date +%s.%N); $P -c "CREATE INDEX docs_idx ON docs USING fts (d)"; log "build_s=$(echo "$(date +%s.%N)-$s"|bc)"
  s=$(date +%s.%N); $P -c "SELECT fts_vacuum('docs_idx')" >/dev/null; log "fts_vacuum_s=$(echo "$(date +%s.%N)-$s"|bc)"
  log "size_bytes=$($P -c "select pg_relation_size('docs_idx')")"
  r() { echo "SELECT count(*) FROM (SELECT id FROM docs WHERE d @@@ to_ftsquery('english','$1') ORDER BY d <=> to_ftsquery('english','$1') LIMIT $2) s"; }
  BANDS=("rare_k10|$(r slovakia 10)" "mid_k10|$(r hungary 10)" "common_k10|$(r year 10)" "common_k100|$(r year 100)"
         "and_k10|$(r 'slovakia & hungary' 10)" "or_k10|$(r 'slovakia | hungary' 10)"
         "count_common|SELECT count(*) FROM docs WHERE d @@@ to_ftsquery('english','year')")
  CNT() { $P -c "SELECT count(*) FROM docs WHERE d @@@ to_ftsquery('english','$1')"; } ;;
pgts)
  log "ext $($P -c "CREATE EXTENSION IF NOT EXISTS pg_textsearch; SELECT extversion FROM pg_extension WHERE extname='pg_textsearch'")"
  $P -c "VACUUM (FREEZE, ANALYZE) docs"
  s=$(date +%s.%N); $P -c "CREATE INDEX docs_idx ON docs USING bm25(content) WITH (text_config='english')" 2>&1 | grep -v "too long"; log "build_s=$(echo "$(date +%s.%N)-$s"|bc)"
  log "size_bytes=$($P -c "select pg_relation_size('docs_idx')")"
  r() { echo "SELECT count(*) FROM (SELECT id FROM docs ORDER BY content <@> to_bm25query('$1','docs_idx') LIMIT $2) s"; }
  b() { echo "SELECT count(*) FROM (SELECT id FROM docs WHERE content @@ to_tsquery('english','$1') ORDER BY content <@> to_bm25query('$2','docs_idx') LIMIT 10) s"; }
  BANDS=("rare_k10|$(r slovakia 10)" "mid_k10|$(r hungary 10)" "common_k10|$(r year 10)" "common_k100|$(r year 100)"
         "and_k10|$(b 'slovakia & hungary' 'slovakia hungary')" "or_k10|$(b 'slovakia | hungary' 'slovakia hungary')"
         "phrase_k10|$(b 'united <-> states' 'united states')")
  CNT() { $P -c "SELECT count(*) FROM docs WHERE content @@ to_tsquery('english','$1')"; } ;;
psearch)
  log "ext $($P -c "CREATE EXTENSION IF NOT EXISTS pg_search CASCADE; SELECT string_agg(extname||' '||extversion, ', ') FROM pg_extension WHERE extname IN ('pg_search','vector')")"
  $P -c "VACUUM (FREEZE, ANALYZE) docs"
  s=$(date +%s.%N); $P -c "CREATE INDEX docs_idx ON docs USING paradedb (id, (content::pdb.simple('stemmer=english'))) WITH (key_field='id')"; log "build_s=$(echo "$(date +%s.%N)-$s"|bc)"
  log "size_bytes=$($P -c "select pg_relation_size('docs_idx')")"
  r() { echo "SELECT count(*) FROM (SELECT id FROM docs WHERE content ||| '$1' ORDER BY pdb.score(id) DESC LIMIT $2) s"; }
  BANDS=("rare_k10|$(r slovakia 10)" "mid_k10|$(r hungary 10)" "common_k10|$(r year 10)" "common_k100|$(r year 100)"
         "and_k10|SELECT count(*) FROM (SELECT id FROM docs WHERE content &&& 'slovakia hungary' ORDER BY pdb.score(id) DESC LIMIT 10) s"
         "or_k10|$(r 'slovakia hungary' 10)"
         "phrase_k10|SELECT count(*) FROM (SELECT id FROM docs WHERE content ### 'united states' ORDER BY pdb.score(id) DESC LIMIT 10) s"
         "count_common|SELECT count(*) FROM docs WHERE content ||| 'year'")
  CNT() { $P -c "SELECT count(*) FROM docs WHERE content ||| '$1'"; } ;;
vchord)
  log "ext $($P -c "CREATE EXTENSION IF NOT EXISTS pg_tokenizer CASCADE; CREATE EXTENSION IF NOT EXISTS vchord_bm25 CASCADE; SELECT string_agg(extname||' '||extversion, ', ') FROM pg_extension WHERE extname IN ('vchord_bm25','pg_tokenizer')")"
  # the documented setup: both extensions' schemas on the search path
  $P -c "ALTER DATABASE postgres SET search_path TO \"\$user\", public, tokenizer_catalog, bm25_catalog"
  # pg_tokenizer's documented English setup (docs/03-examples.md): text analyzer with
  # Porter2 stemming + NLTK stopwords, and a custom model built from this corpus
  $P -c "SELECT create_text_analyzer('en_ana', \$\$
pre_tokenizer = \"unicode_segmentation\"
[[character_filters]]
to_lowercase = {}
[[character_filters]]
unicode_normalization = \"nfkd\"
[[token_filters]]
skip_non_alphanumeric = {}
[[token_filters]]
stopwords = \"nltk_english\"
[[token_filters]]
stemmer = \"english_porter2\"
\$\$)" >/dev/null
  # documented "without trigger" form (docs/06-model.md): model from the table, tokenizer, UPDATE
  s=$(date +%s.%N); $P -c "SELECT create_custom_model('en_model', \$\$
table = 'docs'
column = 'content'
text_analyzer = 'en_ana'
\$\$)" >/dev/null; log "model_s=$(echo "$(date +%s.%N)-$s"|bc)"
  $P -c "SELECT create_tokenizer('en', \$\$
text_analyzer = 'en_ana'
model = 'en_model'
\$\$)" >/dev/null
  $P -c "ALTER TABLE docs ADD COLUMN emb bm25vector"
  s=$(date +%s.%N); $P -c "UPDATE docs SET emb = tokenize(content, 'en')"; log "tokenize_s=$(echo "$(date +%s.%N)-$s"|bc)"
  log "emb_filled=$($P -c "SELECT count(*) FROM docs WHERE emb IS NOT NULL")"
  $P -c "VACUUM (FREEZE, ANALYZE) docs"
  s=$(date +%s.%N); $P -c "CREATE INDEX docs_idx ON docs USING bm25 (emb bm25_ops)"; log "build_s=$(echo "$(date +%s.%N)-$s"|bc)"
  log "size_bytes=$($P -c "select pg_relation_size('docs_idx')")"
  r() { echo "SELECT count(*) FROM (SELECT id FROM docs ORDER BY emb <&> to_bm25query('docs_idx', tokenize('$1', 'en')) LIMIT $2) s"; }
  BANDS=("rare_k10|$(r slovakia 10)" "mid_k10|$(r hungary 10)" "common_k10|$(r year 10)" "common_k100|$(r year 100)" "or_k10|$(r 'slovakia hungary' 10)")
  CNT() { echo "n/a"; } ;;
esac
$P -c "CREATE EXTENSION IF NOT EXISTS pg_prewarm" -c "SELECT pg_prewarm('docs'), pg_prewarm('docs_idx')" >/dev/null
for t in slovakia hungary year; do log "count $t=$(CNT $t 2>&1 | tail -1)"; done
for t in slovakia hungary; do log "regex $t=$($P -c "SELECT count(*) FROM docs WHERE content ~* '\\m$t\\M'")"; done
log "regex years?=$($P -c "SELECT count(*) FROM docs WHERE content ~* '\\myears?\\M'")"
for bq in "${BANDS[@]}"; do n=${bq%%|*}; sql=${bq#*|}; { echo "== $n"; $P -c "SET default_text_search_config = 'english'" -c "EXPLAIN $sql"; } >> $OUT/explain.txt 2>&1; done
for pass in 1 2 3; do
  for bq in "${BANDS[@]}"; do n=${bq%%|*}; sql=${bq#*|}
    { echo "SET statement_timeout = '300s'; SET default_text_search_config = 'english';"; echo '\timing on'; for i in 1 2 3 4 5 6 7 8; do echo "$sql;"; done; } > /tmp/b.sql
    $P -f /tmp/b.sql > /tmp/b.out 2>&1
    rows=$(grep -v '^Time:' /tmp/b.out | sort -u | tr '\n' ',')
    grep -q "statement timeout" /tmp/b.out && rows="TIMEOUT(300s)"
    ts=$(sed -n 's/^Time: \([0-9.]*\) ms.*/\1/p' /tmp/b.out | tail -8 | tr '\n' ' ')
    med=$(echo "$ts" | tr ' ' '\n' | grep . | tail -5 | sort -n | sed -n 3p)
    echo "pass=$pass band=$n rows=$rows median_last5=$med raw=[$ts]" | tee -a $OUT/latency.txt
  done
done
if [ $ENG = fts ]; then
  $P -c "DROP INDEX docs_idx"
  s=$(date +%s.%N); $P -c "CREATE INDEX docs_idx ON docs USING fts (d) WITH (positions = on)"; log "pos_build_s=$(echo "$(date +%s.%N)-$s"|bc)"
  $P -c "SELECT fts_vacuum('docs_idx')" >/dev/null; log "pos_size_bytes=$($P -c "select pg_relation_size('docs_idx')")"
  $P -c "SELECT pg_prewarm('docs_idx')" >/dev/null
  sql="SELECT count(*) FROM (SELECT id FROM docs WHERE d @@@ to_ftsquery('english','\"united states\"') ORDER BY d <=> to_ftsquery('english','\"united states\"') LIMIT 10) s"
  log "phrase count=$($P -c "SELECT count(*) FROM docs WHERE d @@@ to_ftsquery('english','\"united states\"')") regex=$($P -c "SELECT count(*) FROM docs WHERE content ~* '\\munited\\s+states\\M'")"
  for pass in 1 2 3; do
    { echo '\timing on'; for i in 1 2 3 4 5 6 7 8; do echo "$sql;"; done; } > /tmp/b.sql
    $P -f /tmp/b.sql > /tmp/b.out 2>&1
    ts=$(sed -n 's/^Time: \([0-9.]*\) ms.*/\1/p' /tmp/b.out | tail -8 | tr '\n' ' ')
    echo "pass=$pass band=phrase_k10 rows=$(grep -v '^Time:' /tmp/b.out | sort -u | tr '\n' ',') median_last5=$(echo "$ts" | tr ' ' '\n' | grep . | tail -5 | sort -n | sed -n 3p) raw=[$ts]" | tee -a $OUT/latency.txt
  done
  # concurrency on the non-positional index (the release default)
  $P -c "DROP INDEX docs_idx" -c "CREATE INDEX docs_idx ON docs USING fts (d)" >/dev/null; $P -c "SELECT fts_vacuum('docs_idx')" -c "SELECT pg_prewarm('docs_idx')" >/dev/null
fi
log LAT_DONE
# ---- throughput: pgbench, 16/32/64 clients, 30 s, 2 passes, warm-up at 8 --------
export PGOPTIONS="-c default_text_search_config=english"
for bq in "${BANDS[@]}"; do n=${bq%%|*}; case $n in rare_k10|mid_k10|common_k10|count_common) ;; *) continue ;; esac
  echo "${bq#*|};" > /tmp/w_$n.sql
  $B/pgbench -h /tmp -U postgres -n -f /tmp/w_$n.sql -c 8 -j 8 -T 10 postgres >/dev/null 2>&1
  for pass in 1 2; do line="pass=$pass band=$n"
    for c in 16 32 64; do j=$(( c < 8 ? c : 8 ))
      line="$line c$c=$($B/pgbench -h /tmp -U postgres -n -f /tmp/w_$n.sql -c $c -j $j -T 30 postgres 2>&1 | sed -n 's/^tps = \([0-9.]*\).*/\1/p')"
    done; echo "$line" | tee -a $OUT/tps.txt
  done
done
log CONC_DONE
