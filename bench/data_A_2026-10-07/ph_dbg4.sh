#!/bin/bash
# does the collect path (lazy=off) sum in a different order from lazy+bmw? compare raw doubles
B=/nvme/pg17/bin; P="$B/psql -h /tmp -p 55432 -U postgres -X -q -At -d postgres"
for Q in '"w0 w5 w2"' '"w1 w2 w3 w4"'; do
  for cfg in "lazy_phrase=on;bestfirst=on" "lazy_phrase=on;bestfirst=off" "lazy_phrase=off;bestfirst=on" "lazy_phrase=off;bestfirst=off"; do
    S="SET pg_fts.${cfg%%;*}; SET pg_fts.${cfg##*;}; SET extra_float_digits=3"
    echo "[$Q] $cfg $($P -c "$S" -c "SELECT md5(string_agg(ctid::text||':'||score::text, ',' ORDER BY ctid)) FROM fts_search('pg_fts_ix', to_ftsquery('simple','$Q'), 1000)")"
  done
done
