-- phrase_gate: a ranked phrase query on a positions=on index checks adjacency
-- per WAND candidate (the lazy phrase gate, 1.9.1) instead of building the full
-- phrase match set first.  It must return exactly what the collect path
-- (pg_fts.lazy_phrase = off) returns -- ids, order and distances -- for 2..4
-- term phrases, NEAR, a repeated term, ties, several segments, deletes, an
-- absent term, the fts_search() SRF, and high-tf documents.
SET client_min_messages = warning;
SET enable_seqscan = off;
SET enable_bitmapscan = off;
CREATE TABLE pg (id int PRIMARY KEY, d ftsdoc);
-- vocabulary w0..w7 in a deterministic pseudo-random order: adjacent pairs,
-- reversed pairs, gaps of every size, and repeats all occur
-- plus planted 3- and 4-term phrases (and near-misses) so every shape has hits
INSERT INTO pg SELECT g, to_ftsdoc('simple',
  (SELECT string_agg('w' || ((g * 7 + i * i * 3 + (g % 11) * i) % 8), ' ')
     FROM generate_series(1, 3 + (g % 23)) i)
  || CASE WHEN g % 13 = 0 THEN ' w1 w2 w3 w4'
          WHEN g % 13 = 1 THEN ' w1 w2 w4 w3'
          WHEN g % 17 = 0 THEN ' w0 w5 w2'
          WHEN g % 17 = 1 THEN ' w0 w5 w6 w2' ELSE '' END)
FROM generate_series(1, 4000) g;
CREATE INDEX pg_fts_ix ON pg USING fts (d) WITH (positions = on);
VACUUM ANALYZE pg;

CREATE FUNCTION pg_same(qs text, k int) RETURNS text LANGUAGE plpgsql AS $$
DECLARE lz text; cl text; f1 text; f2 text; q ftsquery := to_ftsquery('simple', qs); n int;
BEGIN
  SET LOCAL pg_fts.lazy_phrase = on;
  SELECT string_agg(id || ':' || (d <=> q)::text, ','), count(*) INTO lz, n
    FROM (SELECT id, d FROM pg WHERE d @@@ q ORDER BY d <=> q LIMIT k) s;
  SELECT string_agg(ctid::text || ':' || score::text, ',') INTO f1 FROM fts_search('pg_fts_ix', q, k);
  SET LOCAL pg_fts.lazy_phrase = off;
  SELECT string_agg(id || ':' || (d <=> q)::text, ',') INTO cl
    FROM (SELECT id, d FROM pg WHERE d @@@ q ORDER BY d <=> q LIMIT k) s;
  SELECT string_agg(ctid::text || ':' || score::text, ',') INTO f2 FROM fts_search('pg_fts_ix', q, k);
  IF lz IS DISTINCT FROM cl OR f1 IS DISTINCT FROM f2 THEN
    RETURN 'DIFF ' || qs || ' k=' || k;
  END IF;
  RETURN 'ok ' || coalesce(n, 0);
END $$;

-- every phrase shape must agree; the second column proves the probes are not
-- comparing empty against empty (rule 9: non-zero hits)
SELECT qs, k, pg_same(qs, k) AS lazy_vs_collect
FROM (VALUES ('"w1 w2"'), ('"w2 w1"'), ('"w3 w3"'), ('"w0 w5 w2"'), ('"w1 w2 w3 w4"'),
             ('NEAR(w1 w6, 3)'), ('"w7 w0"')) qq(qs),
     (VALUES (1), (10), (100), (5000)) ks(k)
ORDER BY qs COLLATE "C", k;

-- the phrase set the gate admits must equal @@@ exactly (an unbounded ranked
-- scan returns every match)
SET pg_fts.lazy_phrase = on;
SELECT (SELECT count(*) FROM (SELECT id FROM pg WHERE d @@@ to_ftsquery('simple','"w1 w2"')
          ORDER BY d <=> to_ftsquery('simple','"w1 w2"')) s)
     = (SELECT fts_count('pg_fts_ix', to_ftsquery('simple','"w1 w2"'))) AS ranked_set_is_exact,
       (SELECT fts_count('pg_fts_ix', to_ftsquery('simple','"w1 w2"'))) <
       (SELECT fts_count('pg_fts_ix', to_ftsquery('simple','w1 & w2'))) AS phrase_lt_and;
-- an absent term anywhere in the phrase: no rows, on both paths
SELECT count(*) AS absent_term_rows FROM (SELECT id FROM pg WHERE d @@@ to_ftsquery('simple','"w1 nosuch"')
  ORDER BY d <=> to_ftsquery('simple','"w1 nosuch"') LIMIT 10) s;
RESET pg_fts.lazy_phrase;

-- deletes: tombstoned docs must not be admitted
DELETE FROM pg WHERE id % 5 = 0;
VACUUM pg;
SELECT qs, pg_same(qs, 50) AS after_delete
FROM (VALUES ('"w1 w2"'), ('"w0 w5 w2"'), ('NEAR(w1 w6, 3)')) qq(qs) ORDER BY qs COLLATE "C";

-- two segments (VACUUM flushes the pending rows into a NEW segment): one
-- cursor per (term, segment), so the gate must pick the pivot's cursors among
-- several per term.  The new segment's 'w2 w7 w7 w7 w1' docs hold only
-- reversed and gapped pairs and must never be admitted for "w1 w2".
INSERT INTO pg SELECT g, to_ftsdoc('simple',
  CASE WHEN g % 4 = 0 THEN 'w2 w7 w7 w7 w1'
       ELSE (SELECT string_agg('w' || ((g * 5 + i * 3) % 8), ' ') FROM generate_series(1, 4 + (g % 9)) i) END)
FROM generate_series(4001, 6000) g;
VACUUM pg;
SELECT fts_index_nsegments('pg_fts_ix') AS nsegments;
SELECT qs, pg_same(qs, 200) AS multiseg
FROM (VALUES ('"w1 w2"'), ('"w2 w1"'), ('"w0 w5 w2"'), ('"w2 w7"'), ('"w7 w1"')) qq(qs) ORDER BY qs COLLATE "C";

-- moderate tf (Sum(tf) in the thousands per block, still fits a page): the
-- per-block positions decode with long per-posting runs
INSERT INTO pg SELECT g, to_ftsdoc('simple', repeat('w1 w3 ', 8 + g % 9) || 'w1 w2 ' || repeat('w2 w4 ', 6 + g % 5))
FROM generate_series(6501, 6900) g;
SELECT fts_merge('pg_fts_ix') IS NOT NULL AS merged2;
SELECT pg_same('"w1 w2"', 300) AS moderate_tf, pg_same('"w3 w1 w2"', 50) AS moderate_tf3,
       pg_same('"w2 w1"', 10) AS moderate_tf_reversed;
-- very high tf: a block whose positions exceed a page is written WITHOUT
-- positions, so the gate cannot decide it and the scan redoes the query on the
-- collect path -- same answer
INSERT INTO pg SELECT g, to_ftsdoc('simple', repeat('w1 ', 300 + g % 50) || 'w1 w2 ' || repeat('w2 ', 200))
FROM generate_series(7001, 7300) g;
SELECT fts_merge('pg_fts_ix') IS NOT NULL AS merged3;
SELECT pg_same('"w1 w2"', 400) AS high_tf;
SELECT pg_same('"w2 w1"', 10) AS high_tf_reversed;
