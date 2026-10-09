#!/bin/bash
# best-first vs dense exhaustive vs docid-order WAND, ids+distances, on the OLD index (1.10.0
# corner bounds) and after REINDEX (new effective-length bounds).
B=/nvme/pgs/bin; P="$B/psql -h /tmp -p 55440 -U postgres -X -q -At"
run() {
  n=0; bad=0
  for t in year also film united states hungary slovakia 'hung*' the; do for k in 1 10 100 1000; do
    sql="SELECT md5(string_agg(id||':'||dist, ',')), count(*) FROM (SELECT id, d <=> to_ftsquery('english','$t') dist FROM docs WHERE d @@@ to_ftsquery('english','$t') ORDER BY d <=> to_ftsquery('english','$t') LIMIT $k) s"
    pre="SET enable_seqscan=off; SET enable_bitmapscan=off;"
    bf=$($P -c "$pre SET pg_fts.bestfirst=on;" -c "$sql")
    dn=$($P -c "$pre SET pg_fts.bestfirst=off; SET pg_fts.dense_score_min_df=1;" -c "$sql")
    wd=$($P -c "$pre SET pg_fts.bestfirst=off; SET pg_fts.dense_score_min_df=0;" -c "$sql")
    n=$((n+1)); if [ "$bf" = "$dn" ] && [ "$bf" = "$wd" ]; then :; else bad=$((bad+1)); echo "DIFF $1 t=$t k=$k bf=$bf dense=$dn wand=$wd"; fi
  done; done
  echo "$1: $n cases, $bad differ"
}
$P -c "SELECT pg_prewarm('docs'), pg_prewarm('docs_fts')" >/dev/null
run "old-bounds(1.10.0 writer)"
s=$(date +%s); $P -c "REINDEX INDEX docs_fts" && $P -c "SELECT fts_vacuum('docs_fts')" >/dev/null; echo "reindex+vacuum $(( $(date +%s)-s ))s size=$($P -c "select pg_relation_size('docs_fts')")"
$P -c "SELECT pg_prewarm('docs_fts')" >/dev/null
run "new-bounds(effective length)"
