#!/bin/bash
# dictionary lookups must be unchanged: df for 40 terms (incl. first/last/absent, terms that are
# first-on-page) via fts_index_df == count via @@@ (index), and == the 1.10.0 binary's df.
B=/nvme/pgs/bin; P="$B/psql -h /tmp -p 55440 -U postgres -X -q -At"
TERMS="a aa aardvark abbey able also year film united states hungary slovakia zzzz zyzzyva zygote zulu zoo the of and in to was for is on as by with he that at from it his an were are which this be or has had first one new other their after its who but also been"
for t in $TERMS; do
  df=$($P -c "SELECT (fts_index_df('docs_fts', to_ftsquery('english','$t')))[1]" 2>/dev/null)
  ct=$($P -c "SET enable_seqscan=off; SELECT count(*) FROM docs WHERE d @@@ to_ftsquery('english','$t')" 2>/dev/null)
  echo "$t $df $ct"
done
