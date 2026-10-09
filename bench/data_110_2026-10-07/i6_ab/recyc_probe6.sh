# Search for a schedule where a NEW segment's doclenstart equals a RETIRED (still-held) copy's doclenstart.
B=/nvme/pg17/bin; P="$B/psql -h /tmp -p 55432 -U postgres -X -q -At"
cp(){ $P -c "SELECT coalesce(string_agg(doclenstart::text||'/'||ndocs||(CASE WHEN retired THEN 'R' ELSE '' END), ',' ORDER BY doclenstart),'') FROM fts_shared_doclen_stats() WHERE relfilenumber = pg_relation_filenode('rc6_fts')"; }
$P -c "DROP TABLE IF EXISTS rc6" -c "CREATE TABLE rc6 (id int, d ftsdoc)" -c "INSERT INTO rc6 SELECT g, to_ftsdoc('simple', 'a ' || repeat('b ', g % 7)) FROM generate_series(1, 300) g" -c "CREATE INDEX rc6_fts ON rc6 USING fts (d)" 2>&1 | grep -v NOTICE
$P -c "INSERT INTO rc6 SELECT g, to_ftsdoc('simple', 'a ' || repeat('z ', g % 9)) FROM generate_series(1, 41) g" -c "VACUUM rc6" >/dev/null
( $P <<'SQL' ) >/dev/null &
SET enable_seqscan=off; SET enable_bitmapscan=off;
BEGIN; DECLARE c CURSOR FOR SELECT id FROM rc6 WHERE d @@@ 'a'::ftsquery ORDER BY d <=> 'a'::ftsquery;
FETCH 1 FROM c; SELECT pg_sleep(20); COMMIT;
SQL
sleep 2; echo "held: $(cp)"
$P -c "SELECT fts_merge('rc6_fts')" >/dev/null
# flush small segments repeatedly: low-first allocation reuses the freed low pages
for i in 1 2 3 4 5 6; do
  $P -c "INSERT INTO rc6 SELECT g, to_ftsdoc('simple', 'a q$i ' || repeat('y ', g % 4)) FROM generate_series(1, 5) g" -c "VACUUM rc6" >/dev/null
  $P -c "SET enable_seqscan=off; SET enable_bitmapscan=off; SELECT count(*) FROM (SELECT id FROM rc6 WHERE d @@@ 'a'::ftsquery ORDER BY d <=> 'a'::ftsquery LIMIT 5) s" >/dev/null
  echo "flush $i: $(cp)  dir=$($P -c "select fts_index_nsegments('rc6_fts')")"
done
wait
