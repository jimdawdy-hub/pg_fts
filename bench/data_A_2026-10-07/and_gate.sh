#!/bin/bash
# A2 correctness: conjunctive best-first (bestfirst=on) vs the docid-order BMW path (off),
# on the plain index (AND) and the positions index (AND and phrase); k = 1, 10, 100, 1000.
B=/nvme/pgs/bin; P="$B/psql -h /tmp -p 55440 -U postgres -X -q -At"
same=0; diff=0; tieonly=0
for idx in docs_fts docs_fts_pos; do
  other=$([ $idx = docs_fts ] && echo docs_fts_pos || echo docs_fts)
  for Q in 'united & states' 'slovakia & hungary' 'year & film' 'world & war' 'river & valley & mountain' 'also & year' 'slovakia & hungary & poland & austria' '"united states"' '"world war"' '"new york city"' '"the united states"' 'zzzq & year'; do
    [ $idx = docs_fts ] && [[ "$Q" == \"* ]] && continue
    for k in 1 10 100 1000; do
      r=()
      for bf in on off; do
        r+=("$($P -c "BEGIN; UPDATE pg_index SET indisvalid=false WHERE indexrelid='$other'::regclass; SET LOCAL enable_seqscan=off; SET LOCAL enable_bitmapscan=off; SET LOCAL pg_fts.bestfirst=$bf;" -c "SET extra_float_digits=3; SELECT string_agg(id::text||':'||round((1/dist-1)::numeric,9)::text, ',') FROM (SELECT id, d <=> to_ftsquery('english','$Q') dist FROM docs WHERE d @@@ to_ftsquery('english','$Q') ORDER BY d <=> to_ftsquery('english','$Q') LIMIT $k) s" -c "ROLLBACK" 2>&1 | grep -v -E '^(BEGIN|UPDATE|SET|ROLLBACK)')")
      done
      if [ "${r[0]}" = "${r[1]}" ]; then same=$((same+1))
      else
        a=$(echo "${r[0]}" | tr ',' '\n' | cut -d: -f2 | md5sum); b=$(echo "${r[1]}" | tr ',' '\n' | cut -d: -f2 | md5sum)
        if [ "$a" = "$b" ]; then tieonly=$((tieonly+1)); else diff=$((diff+1)); echo "DIFF $idx [$Q] k=$k on=$(echo ${r[0]} | cut -c1-120) off=$(echo ${r[1]} | cut -c1-120)"; fi
      fi
      [ -z "${r[0]}" ] && [ "$Q" != 'zzzq & year' ] && echo "EMPTY $idx [$Q] k=$k"
    done
  done
done
echo "TOTAL same=$same tie-order-only=$tieonly differ=$diff"
