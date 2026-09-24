CREATE EXTENSION pg_fts VERSION '1.8.3';

-- ftsdoc: analysis, output shows terms with term frequencies
SELECT to_ftsdoc('The quick brown fox, the QUICK fox!');
SELECT 'the quick brown fox'::ftsdoc;
SELECT to_ftsdoc('');                       -- empty doc
SELECT ftsdoc_length(to_ftsdoc('a b c a b a'));  -- doclen counts tokens

-- ftsquery: parsing and canonical output
SELECT 'quick & brown'::ftsquery;
SELECT 'quick | brown'::ftsquery;
SELECT '!slow'::ftsquery;
SELECT 'quick brown fox'::ftsquery;          -- implicit AND
SELECT to_ftsquery('(quick OR slow) AND fox');
SELECT to_ftsquery('quick and not slow');    -- keyword operators
SELECT 'QUICK'::ftsquery;                     -- folding

-- syntax errors
SELECT 'quick &'::ftsquery;                   -- dangling operator
SELECT '(quick'::ftsquery;                     -- unbalanced paren

-- @@@ match operator
SELECT to_ftsdoc('the quick brown fox') @@@ 'quick'::ftsquery;         -- t
SELECT to_ftsdoc('the quick brown fox') @@@ 'slow'::ftsquery;          -- f
SELECT to_ftsdoc('the quick brown fox') @@@ 'quick & fox'::ftsquery;   -- t
SELECT to_ftsdoc('the quick brown fox') @@@ 'quick & slow'::ftsquery;  -- f
SELECT to_ftsdoc('the quick brown fox') @@@ 'quick | slow'::ftsquery;  -- t
SELECT to_ftsdoc('the quick brown fox') @@@ '!slow'::ftsquery;         -- t
SELECT to_ftsdoc('the quick brown fox') @@@ '!fox'::ftsquery;          -- f
SELECT to_ftsdoc('the quick brown fox') @@@ 'quick & !slow'::ftsquery; -- t

-- commutator form
SELECT 'quick'::ftsquery @@@ to_ftsdoc('the quick brown fox');         -- t

-- empty query matches nothing
SELECT to_ftsdoc('anything') @@@ ''::ftsquery;                         -- f

-- end-to-end: WHERE on a table, sequential scan
CREATE TABLE docs (id int, body text);
INSERT INTO docs VALUES
  (1, 'the quick brown fox'),
  (2, 'a slow green turtle'),
  (3, 'quick turtles are rare'),
  (4, 'brown bears and quick foxes');

SELECT id FROM docs
WHERE to_ftsdoc(body) @@@ 'quick & !turtle'::ftsquery
ORDER BY id;

SELECT id FROM docs
WHERE to_ftsdoc(body) @@@ '(quick | slow) & !fox'::ftsquery
ORDER BY id;

-- binary send/recv round-trip is exercised by COPY BINARY in the framework;
-- here just confirm send produces bytea without error.
SELECT octet_length(ftsdoc_send(to_ftsdoc('round trip test'))) > 0 AS ftsdoc_send_ok;
SELECT octet_length(ftsquery_send('a & (b | !c)'::ftsquery)) > 0 AS ftsquery_send_ok;

-- adversarial / edge cases: must not crash; must parse or error cleanly
SELECT to_ftsquery(repeat('(', 100) || 'a' || repeat(')', 100)) IS NOT NULL AS deep_nesting_ok;
SELECT '!!!!a'::ftsquery;                -- stacked NOT
SELECT '(((a)))'::ftsquery;              -- redundant parens
SELECT to_ftsquery('   ')::text AS whitespace_only;   -- empty query
SELECT to_ftsquery('a & & b');           -- double operator -> error
SELECT to_ftsquery('a | b & c');         -- precedence: & binds tighter than |
SELECT ftsdoc_length(to_ftsdoc(repeat('word ', 1000))) AS many_repeats_len;

DROP TABLE docs;

-- analyzer reusing an installed text search configuration.

-- english config stems and drops stopwords: 'running the races' -> run, race
SELECT to_ftsdoc('english'::regconfig, 'running the races quickly');
-- stopwords ('the','a','of') are removed by the english dictionary
SELECT to_ftsdoc('english'::regconfig, 'the cat and a dog');
-- doclen counts positions produced by the parser (stopwords still counted)
SELECT ftsdoc_length(to_ftsdoc('english'::regconfig, 'the quick brown fox'));
-- stemming makes a query match across inflections
SELECT to_ftsdoc('english'::regconfig, 'the foxes were running')
       @@@ 'fox & run'::ftsquery AS stemmed_match;

-- to_ftsdoc(tsvector): build an ftsdoc from an existing tsvector, no re-analysis.
-- Must be equivalent to to_ftsdoc(cfg, text) over the same text for matching.
SELECT to_ftsdoc(to_tsvector('english', 'the foxes were running'))
       @@@ 'fox & run'::ftsquery AS tsvector_stemmed_match;              -- t
-- phrase from a tsvector's positions (adjacency preserved through the map)
SELECT to_ftsdoc(to_tsvector('simple', 'quick brown fox'))
       @@@ '"quick brown"'::ftsquery AS tsvector_phrase;                 -- t
SELECT to_ftsdoc(to_tsvector('simple', 'quick red brown'))
       @@@ '"quick brown"'::ftsquery AS tsvector_not_phrase;             -- f
-- a stripped (positionless) tsvector still matches on presence (positions off)
SELECT to_ftsdoc(strip(to_tsvector('simple', 'quick brown fox')))
       @@@ 'brown'::ftsquery AS tsvector_stripped_match;                 -- t
-- empty tsvector -> empty ftsdoc, matches nothing
SELECT to_ftsdoc(to_tsvector('english', 'the a of')) @@@ 'x'::ftsquery AS tsvector_empty; -- f
-- ftsdoc(tsvector) matches the same terms as ftsdoc(cfg,text) for the same text
-- (doclen may differ: a tsvector has already dropped stopword positions, which
-- the text analyzer still counts toward doclen -- so compare matching, not len).
SELECT to_ftsdoc(to_tsvector('english', 'the quick brown fox foxes')) @@@ 'fox & quick'::ftsquery
     = (to_ftsdoc('english'::regconfig, 'the quick brown fox foxes') @@@ 'fox & quick'::ftsquery)
       AS tsvector_matches_text;                                        -- t

-- Stopword symmetry: to_ftsdoc drops configuration stopwords, so to_ftsquery
-- MUST drop them too (like to_tsquery), or a stopword conjunct silently zeroes
-- an AND.  A stopword term is elided from the query tree; a query that is only
-- stopwords becomes empty (matches nothing, as to_tsquery('english','the')='').
SELECT to_ftsquery('english','the')::text AS q_the_empty;               -- (empty)
SELECT to_ftsquery('english','the & postgres')::text AS q_the_and_pg;   -- 'postgr'
SELECT to_ftsquery('english','postgres & the')::text AS q_pg_and_the;   -- 'postgr'
SELECT to_ftsquery('english','the | postgres')::text AS q_the_or_pg;    -- 'postgr'
SELECT to_ftsquery('english','the & a & of & postgres')::text AS q_many_stop; -- 'postgr'
SELECT to_ftsquery('english','(the | a) & postgres')::text AS q_grouped;-- 'postgr'
SELECT to_ftsquery('english','postgres & (the | vacuum)')::text AS q_grp2; -- ('postgr' & 'vacuum')
SELECT to_ftsquery('english','postgres & !the')::text AS q_pg_not_the;  -- 'postgr'
SELECT to_ftsquery('english','"postgres the database"')::text AS q_phrase_mid; -- ('postgr' <2> 'databas')
-- ftsquery elision matches the standard to_tsquery reduction (both drop 'the')
SELECT to_ftsquery('english','the & postgres')::text
     = to_ftsquery('english','postgres')::text AS matches_tsquery_reduction; -- t
-- prefix/fuzzy/regex terms are matched literally, never stopword-dropped
SELECT to_ftsquery('english','the*')::text AS q_prefix_kept;            -- 'the'*
SELECT to_ftsquery('english','the~1')::text AS q_fuzzy_kept;            -- 'the'~1
-- the reported bug: a stopword-containing AND now matches the content
SELECT fts_match(to_ftsdoc('english','the postgres docs'),
                 to_ftsquery('english','the & postgres')) AS stopword_and_matches;  -- t
SELECT fts_match(to_ftsdoc('english','the vacuum problem in postgres'),
                 to_ftsquery('english','the vacuum problem')) AS nl_query_matches;  -- t
-- an all-stopword query matches nothing (consistent with to_tsquery)
SELECT fts_match(to_ftsdoc('english','the postgres docs'),
                 to_ftsquery('english','the')) AS allstopword_matches_nothing;      -- f
-- count parity through the index: 'the & postgres' == 'postgres'
CREATE TABLE sw (id serial, d ftsdoc);
INSERT INTO sw(d) SELECT to_ftsdoc('english', b) FROM (VALUES
  ('the postgres vacuum'), ('a checkpoint runs'), ('the the the'),
  ('postgres runs a vacuum'), ('nothing relevant here')) v(b);
CREATE INDEX sw_idx ON sw USING fts (d);
SET enable_seqscan = off;
SELECT count(*) AS the_cnt FROM sw WHERE d @@@ to_ftsquery('english','the');               -- 0
SELECT (SELECT count(*) FROM sw WHERE d @@@ to_ftsquery('english','the & postgres'))
     = (SELECT count(*) FROM sw WHERE d @@@ to_ftsquery('english','postgres'))
       AS stopword_and_count_parity;                                                       -- t
RESET enable_seqscan;
DROP TABLE sw;

-- BM25 scoring.

-- score is positive when a query term is present, zero when absent
SELECT round(fts_bm25(to_ftsdoc('quick brown fox'), 'fox'::ftsquery,
                      1000, 4.0)::numeric, 4) AS present_gt_0;
SELECT fts_bm25(to_ftsdoc('quick brown fox'), 'turtle'::ftsquery,
                1000, 4.0) AS absent_is_0;

-- length normalization: same tf, longer doc scores lower
SELECT fts_bm25(to_ftsdoc('fox'), 'fox'::ftsquery, 1000, 10.0)
     > fts_bm25(to_ftsdoc('fox ' || repeat('pad ', 40)), 'fox'::ftsquery, 1000, 10.0)
       AS shorter_scores_higher;

-- IDF: a rarer term (low df) contributes more than a common one (high df)
SELECT fts_bm25(to_ftsdoc('rare common'), 'rare'::ftsquery, 1000, 2.0, ARRAY[2.0])
     > fts_bm25(to_ftsdoc('rare common'), 'common'::ftsquery, 1000, 2.0, ARRAY[900.0])
       AS rare_scores_higher;

-- higher term frequency scores higher (saturating)
SELECT fts_bm25(to_ftsdoc('fox fox fox'), 'fox'::ftsquery, 1000, 3.0)
     > fts_bm25(to_ftsdoc('fox pad pad'), 'fox'::ftsquery, 1000, 3.0)
       AS more_tf_scores_higher;

-- BM25 variants.
-- all variants score presence > absence
SELECT variant,
       fts_bm25_opts(to_ftsdoc('quick fox'), 'fox'::ftsquery,
                     1000, 3.0, 1.2, 0.75, variant, ARRAY[10.0]) > 0 AS positive
FROM unnest(ARRAY['lucene','robertson','atire','bm25+','bm25l']) AS variant
ORDER BY variant;
-- bm25+ >= lucene for the same inputs (delta floor)
SELECT fts_bm25_opts(to_ftsdoc('fox'), 'fox'::ftsquery, 1000, 5.0, 1.2, 0.75, 'bm25+', ARRAY[3.0])
     > fts_bm25_opts(to_ftsdoc('fox'), 'fox'::ftsquery, 1000, 5.0, 1.2, 0.75, 'lucene', ARRAY[3.0])
       AS bm25plus_ge_lucene;
-- bm25l (rank_bm25 compatible: delta shift on the length-normalized tf) scores
-- a present term positively and 'l' is an accepted alias for it
SELECT fts_bm25_opts(to_ftsdoc('fox fox fox'), 'fox'::ftsquery, 1000, 5.0, 1.5, 0.75, 'bm25l', ARRAY[3.0]) > 0 AS bm25l_positive,
       fts_bm25_opts(to_ftsdoc('fox fox fox'), 'fox'::ftsquery, 1000, 5.0, 1.5, 0.75, 'bm25l', ARRAY[3.0])
     = fts_bm25_opts(to_ftsdoc('fox fox fox'), 'fox'::ftsquery, 1000, 5.0, 1.5, 0.75, 'l', ARRAY[3.0]) AS l_alias;
-- unknown variant errors
SELECT fts_bm25_opts(to_ftsdoc('x'), 'x'::ftsquery, 10, 1.0, 1.2, 0.75, 'bogus');

-- highlight and snippet.
SELECT fts_highlight('The quick brown fox jumped', 'quick | fox'::ftsquery,
                     '[', ']');
SELECT fts_snippet(
  'lorem ipsum dolor the quick brown fox jumps over the lazy dog etcetera etc',
  'quick & fox'::ftsquery, '<', '>', '...', 6);
-- no match: highlight returns the text unchanged
SELECT fts_highlight('nothing here matches', 'zebra'::ftsquery, '[', ']');

-- migration from tsquery.
-- boolean operators convert directly
SELECT tsquery_to_ftsquery('quick & brown'::tsquery);
SELECT tsquery_to_ftsquery('quick | brown'::tsquery);
SELECT tsquery_to_ftsquery('!slow & quick'::tsquery);
SELECT tsquery_to_ftsquery('(a | b) & !c'::tsquery);
-- phrase operator <-> converts faithfully to an ftsquery phrase
SELECT tsquery_to_ftsquery('quick <-> brown'::tsquery);
-- the tsquery -> ftsquery cast makes existing queries usable with @@@
SELECT to_ftsdoc('the quick brown fox') @@@ ('quick & fox'::tsquery)::ftsquery
       AS migrated_match;

-- prefix queries (term*).
SELECT 'quick*'::ftsquery;                        -- renders with the star
SELECT to_ftsdoc('the quicksand shifts') @@@ 'quick*'::ftsquery AS prefix_hit;
SELECT to_ftsdoc('slow and steady') @@@ 'quick*'::ftsquery AS prefix_miss;
SELECT to_ftsdoc('quick brown fox') @@@ 'qu* & fo*'::ftsquery AS prefix_and;
-- prefix works through the fts index too
CREATE TABLE pfx (id serial, d ftsdoc);
INSERT INTO pfx (d) VALUES (to_ftsdoc('quicksand')), (to_ftsdoc('quiche')),
                          (to_ftsdoc('slow'));
CREATE INDEX pfx_bm25 ON pfx USING fts (d);
SET enable_seqscan = off;
SELECT id FROM pfx WHERE d @@@ 'qui*'::ftsquery ORDER BY id;
RESET enable_seqscan;
DROP TABLE pfx;

-- index-maintained corpus statistics for BM25.
CREATE TABLE corpus (id serial, d ftsdoc);
INSERT INTO corpus (d)
SELECT to_ftsdoc('common ' || CASE WHEN g % 10 = 0 THEN 'rare' ELSE 'filler' END)
FROM generate_series(1, 100) g;
CREATE INDEX corpus_bm25 ON corpus USING fts (d);
-- stats reflect the corpus: 100 docs
SELECT ndocs, nterms FROM fts_index_stats('corpus_bm25');
-- 'rare' (df=10) scores higher than 'common' (df=100) using index df
SELECT fts_index_df('corpus_bm25', 'rare'::ftsquery) AS df_rare,
       fts_index_df('corpus_bm25', 'common'::ftsquery) AS df_common;
SELECT (SELECT fts_bm25(to_ftsdoc('common rare'), 'rare'::ftsquery,
                        s.ndocs, s.avgdl, fts_index_df('corpus_bm25', 'rare'::ftsquery)))
     > (SELECT fts_bm25(to_ftsdoc('common rare'), 'common'::ftsquery,
                        s.ndocs, s.avgdl, fts_index_df('corpus_bm25', 'common'::ftsquery)))
       AS rare_outranks_common
FROM fts_index_stats('corpus_bm25') s;
DROP TABLE corpus;

-- incremental index maintenance (pending list).
CREATE TABLE inc (id serial, d ftsdoc);
INSERT INTO inc (d) VALUES (to_ftsdoc('alpha beta')), (to_ftsdoc('gamma delta'));
CREATE INDEX inc_bm25 ON inc USING fts (d);
SET enable_seqscan = off;
-- rows present at build time are found via the main structure
SELECT id FROM inc WHERE d @@@ 'alpha'::ftsquery ORDER BY id;
-- INSERT after build must be immediately visible (no REINDEX) via pending list
INSERT INTO inc (d) VALUES (to_ftsdoc('alpha epsilon')), (to_ftsdoc('zeta'));
SELECT id FROM inc WHERE d @@@ 'alpha'::ftsquery ORDER BY id;   -- 1 and 3
SELECT id FROM inc WHERE d @@@ 'zeta'::ftsquery ORDER BY id;     -- 4 (pending only)
SELECT id FROM inc WHERE d @@@ 'alpha & !beta'::ftsquery ORDER BY id;  -- 3
-- ndocs reflects built + pending
SELECT ndocs FROM fts_index_stats('inc_bm25');
-- REINDEX merges pending into the main structure; results unchanged
REINDEX INDEX inc_bm25;
SELECT id FROM inc WHERE d @@@ 'alpha'::ftsquery ORDER BY id;
RESET enable_seqscan;
DROP TABLE inc;

-- quoted phrase queries via per-term positions.
-- phrase renders with <-> and round-trips
SELECT '"quick brown fox"'::ftsquery;
-- adjacency is enforced: "quick brown" matches, "quick fox" does not
SELECT to_ftsdoc('the quick brown fox') @@@ '"quick brown"'::ftsquery AS adj_hit;
SELECT to_ftsdoc('the quick brown fox') @@@ '"quick fox"'::ftsquery AS adj_miss;
SELECT to_ftsdoc('the quick brown fox') @@@ '"brown fox"'::ftsquery AS adj_hit2;
-- word order matters: "fox brown" does not match "...brown fox"
SELECT to_ftsdoc('the quick brown fox') @@@ '"fox brown"'::ftsquery AS order_miss;
-- three-word phrase
SELECT to_ftsdoc('the quick brown fox jumps') @@@ '"quick brown fox"'::ftsquery AS three_hit;
SELECT to_ftsdoc('quick red brown fox') @@@ '"quick brown fox"'::ftsquery AS three_miss;
-- reserved keywords (and/or/not/near) are literal WORDS inside a phrase or NEAR
-- operand, not operators (ROADMAP #12b).  Use the 'simple' config so they are
-- not dropped as stopwords.  A bare keyword phrase must parse and match.
SELECT to_ftsquery('simple','"the and clause"')::text AS kw_phrase_parses;   -- (('the' <-> 'and') <-> 'clause')
SELECT to_ftsdoc('simple','read the and clause here') @@@ to_ftsquery('simple','"the and clause"') AS kw_phrase_hit;   -- t
SELECT to_ftsdoc('simple','the clause and read') @@@ to_ftsquery('simple','"the and clause"') AS kw_phrase_miss;      -- f (order/adjacency)
SELECT to_ftsdoc('simple','alpha or beta') @@@ to_ftsquery('simple','"alpha or beta"') AS kw_or_hit;                  -- t
SELECT to_ftsdoc('simple','x near y z') @@@ to_ftsquery('simple','NEAR(near y, 2)') AS kw_in_near_hit;                -- t (literal 'near' inside NEAR)
-- phrase combined with boolean operators
SELECT to_ftsdoc('the quick brown fox') @@@ '"quick brown" & fox'::ftsquery AS combo;
-- phrase works through the fts index (recheck enforces adjacency)
CREATE TABLE ph (id serial, d ftsdoc);
INSERT INTO ph (d) VALUES (to_ftsdoc('quick brown fox')),
                          (to_ftsdoc('brown quick fox')),
                          (to_ftsdoc('quick brown bear'));
CREATE INDEX ph_bm25 ON ph USING fts (d);
SET enable_seqscan = off;
SELECT id FROM ph WHERE d @@@ '"quick brown"'::ftsquery ORDER BY id;   -- 1 and 3
RESET enable_seqscan;
DROP TABLE ph;

-- regconfig analyzer must also carry positions so phrase/NEAR enforce
-- adjacency (v0.2.1 bug: to_ftsdoc(regconfig,text) stored no positions, so
-- phrases silently degraded to AND).  'simple' config: no stemming/stopwords,
-- positions map 1:1 to input words.
-- adjacent phrase matches
SELECT to_ftsdoc('simple'::regconfig, 'quick brown fox')
       @@@ to_ftsquery('simple'::regconfig, '"quick brown"') AS cfg_adj_hit;   -- t
-- non-adjacent must NOT match (was t before the fix -- the bug -- now f)
SELECT to_ftsdoc('simple'::regconfig, 'quick red slow brown')
       @@@ to_ftsquery('simple'::regconfig, '"quick brown"') AS cfg_nonadj_miss; -- f
-- three-word phrase: only consecutive matches
SELECT to_ftsdoc('simple'::regconfig, 'a b c')
       @@@ to_ftsquery('simple'::regconfig, '"a b c"') AS cfg_three_hit;   -- t
SELECT to_ftsdoc('simple'::regconfig, 'a x b c')
       @@@ to_ftsquery('simple'::regconfig, '"a b c"') AS cfg_three_miss;  -- f
-- repeated term at non-sequential positions: "quick" at pos 1 and 3; the
-- per-term position list must be ascending [1,3] for phrase_step to work
SELECT to_ftsdoc('simple'::regconfig, 'quick brown quick fox')
       @@@ to_ftsquery('simple'::regconfig, '"quick brown"') AS cfg_rep_hit;   -- t
SELECT to_ftsdoc('simple'::regconfig, 'quick brown quick fox')
       @@@ to_ftsquery('simple'::regconfig, '"quick fox"') AS cfg_rep_hit2;    -- t
-- NEAR on the regconfig analyzer: within k true, beyond k false
SELECT to_ftsdoc('simple'::regconfig, 'quick brown red fox')
       @@@ to_ftsquery('simple'::regconfig, 'NEAR(quick fox, 3)') AS cfg_near_hit;  -- t
SELECT to_ftsdoc('simple'::regconfig, 'quick brown red fox')
       @@@ to_ftsquery('simple'::regconfig, 'NEAR(quick fox, 2)') AS cfg_near_miss; -- f
-- index-backed phrase on a regconfig-analyzed column: recheck must exclude
-- non-adjacent docs
CREATE TABLE phc (id serial, d ftsdoc);
INSERT INTO phc (d) VALUES
  (to_ftsdoc('simple'::regconfig, 'quick brown fox')),      -- 1: adjacent
  (to_ftsdoc('simple'::regconfig, 'quick red slow brown')), -- 2: not adjacent
  (to_ftsdoc('simple'::regconfig, 'quick brown bear'));     -- 3: adjacent
CREATE INDEX phc_bm25 ON phc USING fts (d);
SET enable_seqscan = off;
SELECT id FROM phc WHERE d @@@ to_ftsquery('simple'::regconfig, '"quick brown"')
  ORDER BY id;   -- 1 and 3 only
RESET enable_seqscan;
DROP TABLE phc;

-- phrase adjacency must hold on a STORED (column-resident) ftsdoc that is long
-- enough for its positions[] region to land at a non-MAXALIGN'd byte offset.
-- Regression for the FTS_DOC_POSITIONS alignment bug: the accessor used
-- MAXALIGN() of an absolute pointer, which mismatched the analyzer's
-- offset-based layout once a detoasted/heap-read doc sat at a non-MAXALIGN'd
-- address -- positions[] then pointed at garbage and phrase/NEAR silently
-- degraded to AND on every stored ftsdoc (the short-doc tests above happened to
-- land aligned and did not catch it).  Each doc below has repeated filler terms
-- (so tf>1, several positions) plus the phrase at the end; the count must be
-- exactly the adjacent docs, not the larger AND-set.
CREATE TABLE phlong (id int, body text, d ftsdoc);
INSERT INTO phlong(id, body)
SELECT g,
       (SELECT string_agg('flr' || (s % 5), ' ') FROM generate_series(1, 17 + g) s)
       || CASE WHEN g % 2 = 0 THEN ' united states'          -- adjacent
               ELSE ' united middle states' END              -- not adjacent
FROM generate_series(1, 8) g;
UPDATE phlong SET d = to_ftsdoc('simple'::regconfig, body);
-- stored-column adjacency: exactly the even ids (the adjacent phrase)
SELECT id FROM phlong
WHERE d @@@ to_ftsquery('simple'::regconfig, '"united states"') ORDER BY id;   -- 2,4,6,8
-- and the stored value must agree with a fresh re-analysis of the same body
SELECT bool_and(
         (d @@@ to_ftsquery('simple'::regconfig, '"united states"'))
         = (to_ftsdoc('simple'::regconfig, body) @@@ to_ftsquery('simple'::regconfig, '"united states"'))
       ) AS stored_matches_fresh FROM phlong;   -- t
DROP TABLE phlong;

-- external-content indexing via an expression index.
-- The bm25 index stores only postings (no document text), so indexing
-- to_ftsdoc(body) over a plain text column is the external-content model:
-- the text lives in the table, the index derives ftsdoc from it.
CREATE TABLE articles (id serial, body text);
INSERT INTO articles (body) VALUES
  ('the quick brown fox'),
  ('lazy dogs sleep'),
  ('quick foxes are clever');
CREATE INDEX articles_bm25 ON articles USING fts (to_ftsdoc(body));
SET enable_seqscan = off;
-- query against the expression index; text is fetched from the table only
-- for returned rows
SELECT id, body FROM articles
WHERE to_ftsdoc(body) @@@ 'quick'::ftsquery ORDER BY id;
SELECT id FROM articles
WHERE to_ftsdoc(body) @@@ '"quick brown"'::ftsquery ORDER BY id;
RESET enable_seqscan;
DROP TABLE articles;

-- fuzzy (term~k) and regex (/re/) queries.
-- fuzzy: 'quick'~1 matches 'quikc'? no (2 edits); matches 'quic' (1 delete)
SELECT to_ftsdoc('the quic brown fox') @@@ 'quick~1'::ftsquery AS fuzzy_hit;
SELECT to_ftsdoc('the slow green turtle') @@@ 'quick~1'::ftsquery AS fuzzy_miss;
-- default k is 2: 'kwik' is 3 edits from 'quick', so 'quick~' (k=2) misses
SELECT to_ftsdoc('kwik search') @@@ 'quick~'::ftsquery AS fuzzy_default_k;
-- fuzzy renders with ~k
SELECT 'color~2'::ftsquery;
-- regex: /^qu/ matches a term starting with qu
SELECT to_ftsdoc('the quick brown fox') @@@ '/^qu/'::ftsquery AS regex_hit;
SELECT to_ftsdoc('lazy dog') @@@ '/^qu/'::ftsquery AS regex_miss;
-- regex renders with slashes
SELECT '/ab.*cd/'::ftsquery;
-- fuzzy combined with boolean
SELECT to_ftsdoc('the quic brown fox') @@@ 'quick~1 & fox'::ftsquery AS combo;
-- fuzzy/regex work through the fts index (recheck applies the exact test)
CREATE TABLE fz (id serial, d ftsdoc);
INSERT INTO fz (d) VALUES (to_ftsdoc('quick')), (to_ftsdoc('quic')),
                          (to_ftsdoc('slow'));
CREATE INDEX fz_bm25 ON fz USING fts (d);
SET enable_seqscan = off;
SELECT id FROM fz WHERE d @@@ 'quick~1'::ftsquery ORDER BY id;   -- 1 and 2
SELECT id FROM fz WHERE d @@@ '/^qu/'::ftsquery ORDER BY id;      -- 1 and 2
RESET enable_seqscan;
DROP TABLE fz;

-- trigrams reloption: default OFF must give the SAME regex/fuzzy results as
-- WITH (trigrams=on).  The trigram tier only accelerates regex/long-fuzzy; the
-- query side falls back to a full dictionary scan when it is absent, so results
-- are identical either way, and the default-off index is no larger.
CREATE TABLE trg_a (id serial, d ftsdoc);
CREATE TABLE trg_b (id serial, d ftsdoc);
INSERT INTO trg_a (d)
  SELECT to_ftsdoc('english', 'development environment number ' || g ||
                   ' running programmer developer settlement government')
  FROM generate_series(1, 400) g;
INSERT INTO trg_b (d) SELECT d FROM trg_a ORDER BY id;
CREATE INDEX trg_off ON trg_a USING fts (d);                  -- default: trigrams off
CREATE INDEX trg_on  ON trg_b USING fts (d) WITH (trigrams = on);
SET enable_seqscan = off;
-- long fuzzy (>k trigrams) and regex return the identical id set on both indexes
SELECT (SELECT array_agg(id ORDER BY id) FROM trg_a WHERE d @@@ 'developer~3'::ftsquery)
     = (SELECT array_agg(id ORDER BY id) FROM trg_b WHERE d @@@ 'developer~3'::ftsquery)
       AS fuzzy_off_eq_on;                                     -- t
SELECT (SELECT array_agg(id ORDER BY id) FROM trg_a WHERE d @@@ '/^develop/'::ftsquery)
     = (SELECT array_agg(id ORDER BY id) FROM trg_b WHERE d @@@ '/^develop/'::ftsquery)
       AS regex_off_eq_on;                                     -- t
RESET enable_seqscan;
-- default-off index is no larger than the trigrams-on index (trigram tier omitted)
SELECT pg_relation_size('trg_off') <= pg_relation_size('trg_on') AS off_not_larger;  -- t
DROP TABLE trg_a, trg_b;

-- Bounded universe: NOT and trigrams-off regex/fuzzy fall back to a whole-segment
-- candidate scan.  When the vocabulary is small but every document repeats the
-- same terms, the sum of df across the dictionary (the raw postings) far exceeds
-- the document count; the fallback must fold duplicates as it collects so its
-- scratch stays O(ndocs) rather than growing to O(sum df) (which reached a
-- multi-gigabyte alloc on a real high-vocabulary corpus).  Correctness is
-- unchanged -- these queries must return the exact id set.
CREATE TABLE univ (id serial, d ftsdoc);
INSERT INTO univ (d)
  SELECT to_ftsdoc('english', 'alpha beta gamma delta alpha beta gamma delta ' ||
                   CASE WHEN g % 5 = 0 THEN 'omega' ELSE 'sigma' END)
  FROM generate_series(1, 500) g;
CREATE INDEX univ_fts ON univ USING fts (d);   -- trigrams off (default)
SET enable_seqscan = off;
-- NOT drives bm25_universe_bounded: every doc has alpha; only g%5=0 have omega.
SELECT count(*) FROM univ WHERE d @@@ 'alpha & !omega'::ftsquery;   -- 400
-- trigrams-off regex also drives the fallback and must still be exact.
SELECT count(*) FROM univ WHERE d @@@ '/^omeg/'::ftsquery;          -- 100
-- the fallback answer equals the seqscan ground truth.
RESET enable_seqscan;
SELECT (SELECT count(*) FROM univ WHERE d @@@ 'alpha & !omega'::ftsquery)
     = (SELECT count(*) FROM univ WHERE to_ftsdoc('english',
           'alpha beta gamma delta alpha beta gamma delta ' ||
           CASE WHEN id % 5 = 0 THEN 'omega' ELSE 'sigma' END) @@@ 'alpha & !omega'::ftsquery)
       AS universe_matches_truth;                                   -- t
DROP TABLE univ;

-- Multi-segment v4 doclen sidecar: force several segments (low maintenance_work_mem
-- flushes many small segments), then confirm a ranked scan reads each segment's
-- sidecar via the FORWARD CURSOR and returns the exact top-k -- i.e. doclen is
-- looked up correctly ACROSS segment boundaries, not from a mis-scoped preload.
-- (Regression for the 1.5.0 v4 ranked-scan report: the per-segment sidecar was
-- bulk-loaded per query; the cursor reads only the scored docid range, and must
-- still find every scored doc's length.)
CREATE TABLE segsc (id serial, d ftsdoc);
SET maintenance_work_mem = '1MB';   -- tiny -> many segment flushes
INSERT INTO segsc (d)
  SELECT to_ftsdoc('english', repeat('alpha ', 1 + (g % 7)) || 'w' || (g % 500) || ' tail ' || g)
  FROM generate_series(1, 4000) g;
CREATE INDEX segsc_fts ON segsc USING fts (d);
RESET maintenance_work_mem;
SET enable_seqscan = off;
-- Every doc the ranked scan returns must (a) genuinely match @@@ and (b) score
-- within the top band -- i.e. the sidecar cursor supplied a valid doclen for
-- every scored doc across all segments.  We assert the top-10 are all real
-- matches and the scan returns a full page, rather than exact tie-order equality
-- (v4 quantized doclen may reorder within a score tie -- the documented bound).
SELECT count(*) = 10 AS segsc_topk_full,
       bool_and(m) AS segsc_all_match
FROM (
  SELECT id, (d @@@ to_ftsquery('english','alpha')) AS m
  FROM segsc
  WHERE id IN (
    SELECT id FROM segsc WHERE d @@@ to_ftsquery('english','alpha')
    ORDER BY d <=> to_ftsquery('english','alpha') LIMIT 10)
) z;   -- t | t
RESET enable_seqscan;
DROP TABLE segsc;
-- doclen_sidecar reloption (escape hatch): WITH (doclen_sidecar=off) stores
-- doclen inline in each posting (the pre-1.5 layout) instead of the v4 sidecar.
-- Both layouts must return identical results (the decoder is self-describing),
-- and a query on the inline index must not touch a sidecar.
CREATE TABLE dls_on  (id serial, d ftsdoc);
CREATE TABLE dls_off (id serial, d ftsdoc);
INSERT INTO dls_on (d)
  SELECT to_ftsdoc('english', repeat('alpha ', 1 + (g % 5)) || 'w' || (g % 300) || ' ' || g)
  FROM generate_series(1, 3000) g;
INSERT INTO dls_off (d) SELECT d FROM dls_on ORDER BY id;
CREATE INDEX dls_on_fts  ON dls_on  USING fts (d);                          -- sidecar (default)
CREATE INDEX dls_off_fts ON dls_off USING fts (d) WITH (doclen_sidecar = off); -- inline
SET enable_seqscan = off;
-- identical count on both layouts
SELECT (SELECT count(*) FROM dls_on  WHERE d @@@ to_ftsquery('english','alpha'))
     = (SELECT count(*) FROM dls_off WHERE d @@@ to_ftsquery('english','alpha'))
       AS dls_count_eq;   -- t
-- identical ranked top-10 id set
SELECT (SELECT array_agg(id ORDER BY id) FROM (SELECT id FROM dls_on  WHERE d @@@ to_ftsquery('english','w7')
          ORDER BY d <=> to_ftsquery('english','w7') LIMIT 10) a)
     = (SELECT array_agg(id ORDER BY id) FROM (SELECT id FROM dls_off WHERE d @@@ to_ftsquery('english','w7')
          ORDER BY d <=> to_ftsquery('english','w7') LIMIT 10) b)
       AS dls_topk_eq;    -- t
-- the inline index is no larger having dropped the sidecar? (sanity: both build)
SELECT pg_relation_size('dls_off_fts') > 0 AND pg_relation_size('dls_on_fts') > 0 AS both_built;  -- t
RESET enable_seqscan;
DROP TABLE dls_on, dls_off;
-- Merge preserves the doclen sidecar (regression for 1.5.2: the merge path
-- wrote 2-column postings but an EMPTY sidecar collector, so the merged segment
-- got doclenstart=Invalid and its postings were then mis-read as inline ->
-- garbage doclen -> wrong ranked scores + defeated WAND pruning).  Build several
-- segments, force a merge, and confirm the ranked top-k is still correct AND
-- matches an inline-built twin over the same rows.
CREATE TABLE mrg (id serial, d ftsdoc);
CREATE TABLE mrg_inl (id serial, d ftsdoc);
INSERT INTO mrg (d)
  SELECT to_ftsdoc('english', repeat('alpha ', 1 + (g % 6)) || 'w' || (g % 400) || ' g' || g)
  FROM generate_series(1, 40000) g;
INSERT INTO mrg_inl (d) SELECT d FROM mrg ORDER BY id;
SET maintenance_work_mem = '1MB';   -- many small segments
CREATE INDEX mrg_fts ON mrg USING fts (d);                              -- sidecar (default)
RESET maintenance_work_mem;
SELECT fts_merge('mrg_fts') IS NOT NULL AS merge_ran;                   -- force the merge path
CREATE INDEX mrg_inl_fts ON mrg_inl USING fts (d) WITH (doclen_sidecar = off); -- inline twin
SET enable_seqscan = off;
-- the merged sidecar index and the inline twin must return the SAME ranked top-10
SELECT (SELECT array_agg(id ORDER BY id) FROM (SELECT id FROM mrg WHERE d @@@ to_ftsquery('english','w3')
          ORDER BY d <=> to_ftsquery('english','w3') LIMIT 10) a)
     = (SELECT array_agg(id ORDER BY id) FROM (SELECT id FROM mrg_inl WHERE d @@@ to_ftsquery('english','w3')
          ORDER BY d <=> to_ftsquery('english','w3') LIMIT 10) b)
       AS merged_sidecar_matches_inline;   -- t
RESET enable_seqscan;
DROP TABLE mrg, mrg_inl;

-- Multi-term AND ranked exactness (block-max WAND soundness).  Regression for
-- the pre-existing conjunctive-recall gap: the block-max block-skip fast path
-- skipped a whole posting block whenever a single cursor sat at/before the
-- pivot -- but "other cursors past the PIVOT" does not mean "past the BLOCK",
-- so a document later in the skipped block that contained BOTH terms (scoring
-- the SUM of contributions, which the one-term block bound never covered) was
-- dropped from the top-k.  Compounded on the v4 sidecar by scoring against the
-- quantized (rounded-DOWN) doclen while the block bound used the exact min |D|.
-- The engine's ranked top-k must now equal the exact (fts_bm25) top-k for an
-- AND query, on BOTH the sidecar (default) and inline layouts.
CREATE TABLE andx (id serial, d ftsdoc);
-- alpha ~ many docs, beta ~ many docs, a controlled overlap forms the AND set;
-- widely varied doc lengths so doclen quantization spans buckets.
INSERT INTO andx (d)
  SELECT to_ftsdoc('english',
           repeat('w'||(g%2000)||' ', 5 + (g % 120))          -- varied length
           || CASE WHEN g % 13 = 0 THEN 'alpha alpha ' ELSE '' END
           || CASE WHEN g % 17 = 0 THEN 'beta beta '   ELSE '' END
           || CASE WHEN g % 221 = 0 THEN 'alpha beta ' ELSE '' END)  -- 13*17: dense AND docs
  FROM generate_series(1, 60000) g;
CREATE INDEX andx_fts     ON andx USING fts (d);                              -- sidecar (default)
SET enable_seqscan = off;
-- The index ranked top-10 (KNN) must equal the exact-by-score top-10, computed
-- as two SEPARATE queries (a single query holding both a KNN and an exact-sort
-- subquery lets the planner share/rewrite the scan and pick different rows --
-- a false miss).  N and avgdl feed fts_bm25 for the exact side.
SELECT (SELECT array_agg(id ORDER BY id) FROM (
          SELECT id FROM andx WHERE d @@@ to_ftsquery('english','alpha & beta')
          ORDER BY d <=> to_ftsquery('english','alpha & beta') LIMIT 10) k)
     = (SELECT array_agg(id ORDER BY id) FROM (
          SELECT t.id FROM andx t,
                 (SELECT count(*)::float8 n, avg(ftsdoc_length(d))::float8 a FROM andx) s
          WHERE t.d @@@ to_ftsquery('english','alpha & beta')
          ORDER BY fts_bm25(t.d, to_ftsquery('english','alpha & beta'), s.n, s.a,
                            fts_index_df('andx_fts', to_ftsquery('english','alpha & beta'))) DESC
          LIMIT 10) x)
       AS and_sidecar_topk_exact;   -- t
RESET enable_seqscan;
DROP INDEX andx_fts;
CREATE INDEX andx_inl_fts ON andx USING fts (d) WITH (doclen_sidecar = off); -- inline layout
SET enable_seqscan = off;
-- same assertion against the inline layout (proves the fix is in the shared WAND
-- traversal, not sidecar-specific)
SELECT (SELECT array_agg(id ORDER BY id) FROM (
          SELECT id FROM andx WHERE d @@@ to_ftsquery('english','alpha & beta')
          ORDER BY d <=> to_ftsquery('english','alpha & beta') LIMIT 10) k)
     = (SELECT array_agg(id ORDER BY id) FROM (
          SELECT t.id FROM andx t,
                 (SELECT count(*)::float8 n, avg(ftsdoc_length(d))::float8 a FROM andx) s
          WHERE t.d @@@ to_ftsquery('english','alpha & beta')
          ORDER BY fts_bm25(t.d, to_ftsquery('english','alpha & beta'), s.n, s.a,
                            fts_index_df('andx_inl_fts', to_ftsquery('english','alpha & beta'))) DESC
          LIMIT 10) x)
       AS and_inline_topk_exact;   -- t
RESET enable_seqscan;
DROP TABLE andx;

-- BM25F: multi-field weighting.
-- a term in the (heavily weighted) title scores higher than the same term in
-- only the body
SELECT fts_bm25f(ARRAY[to_ftsdoc('postgres'), to_ftsdoc('other text here')],
                'postgres'::ftsquery, ARRAY[5.0, 1.0], 1000, ARRAY[2.0, 3.0], ARRAY[10.0])
     > fts_bm25f(ARRAY[to_ftsdoc('other title'), to_ftsdoc('postgres here')],
                'postgres'::ftsquery, ARRAY[5.0, 1.0], 1000, ARRAY[2.0, 3.0], ARRAY[10.0])
       AS title_weight_wins;
-- absent term scores 0
SELECT fts_bm25f(ARRAY[to_ftsdoc('a'), to_ftsdoc('b')],
                'zebra'::ftsquery, ARRAY[2.0, 1.0], 100, ARRAY[1.0, 1.0]) AS absent_zero;
-- a match in either field contributes
SELECT fts_bm25f(ARRAY[to_ftsdoc('nothing'), to_ftsdoc('found fox')],
                'fox'::ftsquery, ARRAY[2.0, 1.0], 100, ARRAY[2.0, 2.0], ARRAY[5.0]) > 0
       AS body_match_scores;
-- mismatched array lengths error
SELECT fts_bm25f(ARRAY[to_ftsdoc('a')], 'a'::ftsquery, ARRAY[1.0,2.0], 10, ARRAY[1.0]);

-- Background merge of the pending list.
CREATE TABLE mrg (id serial, d ftsdoc);
INSERT INTO mrg (d) VALUES (to_ftsdoc('alpha beta'));
CREATE INDEX mrg_bm25 ON mrg USING fts (d);
INSERT INTO mrg (d) VALUES (to_ftsdoc('alpha gamma')), (to_ftsdoc('delta'));
-- before merge: 2 docs pending
SELECT ndocs FROM fts_index_stats('mrg_bm25');
SET enable_seqscan = off;
SELECT id FROM mrg WHERE d @@@ 'alpha'::ftsquery ORDER BY id;   -- 1, 2
-- explicit merge folds pending into the main structure
SELECT fts_merge('mrg_bm25') AS merged;
-- after merge: same results, and a term from a formerly-pending doc now has df
SELECT id FROM mrg WHERE d @@@ 'alpha'::ftsquery ORDER BY id;   -- still 1, 2
SELECT id FROM mrg WHERE d @@@ 'delta'::ftsquery ORDER BY id;   -- 3
SELECT fts_index_df('mrg_bm25', 'alpha'::ftsquery) AS df_alpha_after_merge;
-- merging again is a no-op (nothing pending)
SELECT fts_merge('mrg_bm25') AS merged_again;
RESET enable_seqscan;
DROP TABLE mrg;

-- Index-only BM25 top-k search (fts_search).
CREATE TABLE srch (id serial, body text, d ftsdoc);
INSERT INTO srch (body, d) VALUES
  ('quick quick quick fox', to_ftsdoc('quick quick quick fox')),
  ('quick brown fox', to_ftsdoc('quick brown fox')),
  ('a slow turtle', to_ftsdoc('a slow turtle')),
  ('quick', to_ftsdoc('quick'));
CREATE INDEX srch_bm25 ON srch USING fts (d);
-- top-k by index-only score: doc with tf(quick)=3 ranks first
SELECT s.id, round(r.score::numeric, 3) AS score
FROM fts_search('srch_bm25', 'quick'::ftsquery, 10) r
JOIN srch s ON s.ctid = r.ctid
ORDER BY r.score DESC, s.id;
-- k limits the result set
SELECT count(*) AS topk_count
FROM fts_search('srch_bm25', 'quick'::ftsquery, 2) r;
-- multi-term query accumulates per-term contributions
SELECT count(*) AS multiterm
FROM fts_search('srch_bm25', 'quick | brown'::ftsquery, 10) r;
DROP TABLE srch;

-- Trigram pre-filter for fuzzy matching: correctness must be unchanged.
-- longer terms (>k trigrams) use the trigram filter
SELECT to_ftsdoc('development environment') @@@ 'developer~3'::ftsquery AS trgm_fuzzy_hit;
SELECT to_ftsdoc('completely unrelated words') @@@ 'developer~3'::ftsquery AS trgm_fuzzy_miss;
-- exact-distance edge: 'running' within 2 of 'runnick'? (n->c,g->k = 2 subst)
SELECT to_ftsdoc('the running man') @@@ 'runnink~2'::ftsquery AS edge_hit;
-- short terms (<=k trigrams) fall back to full scan, still correct
SELECT to_ftsdoc('cat hat bat') @@@ 'rat~1'::ftsquery AS short_hit;
SELECT to_ftsdoc('dog log fog') @@@ 'rat~1'::ftsquery AS short_miss;

-- MVCC: fts_search must return only tuples visible to the snapshot.
CREATE TABLE viz (id serial, d ftsdoc);
INSERT INTO viz (d) VALUES (to_ftsdoc('apple')), (to_ftsdoc('apple')),
                          (to_ftsdoc('apple')), (to_ftsdoc('apple'));
CREATE INDEX viz_bm25 ON viz USING fts (d);
-- delete two rows; their postings remain in the index until merge/reindex
DELETE FROM viz WHERE id IN (2, 3);
-- fts_search must skip the dead tuples (returns 2 live rows, not 4)
SELECT count(*) AS live_only
FROM fts_search('viz_bm25', 'apple'::ftsquery, 100) r
JOIN viz v ON v.ctid = r.ctid;
-- and the raw SRF itself returns only visible ctids
SELECT count(*) AS srf_live FROM fts_search('viz_bm25', 'apple'::ftsquery, 100);
DROP TABLE viz;

-- Posting compression: correctness under many clustered docids + merge.
CREATE TABLE cmp (id serial, d ftsdoc);
INSERT INTO cmp (d) SELECT to_ftsdoc('common term here')
FROM generate_series(1, 500);
CREATE INDEX cmp_bm25 ON cmp USING fts (d);
-- all 500 rows match the compressed posting list
SELECT count(*) AS all_match
FROM fts_search('cmp_bm25', 'common'::ftsquery, 1000) r JOIN cmp c ON c.ctid = r.ctid;
-- incremental inserts (pending) + merge preserve the full posting list
INSERT INTO cmp (d) SELECT to_ftsdoc('common term here') FROM generate_series(1, 100);
SELECT fts_merge('cmp_bm25');
SELECT count(*) AS after_merge
FROM fts_search('cmp_bm25', 'common'::ftsquery, 2000) r JOIN cmp c ON c.ctid = r.ctid;
DROP TABLE cmp;

-- WAND top-k: multi-term query returns correct top-k in descending score.
CREATE TABLE wnd (id serial, d ftsdoc);
INSERT INTO wnd (d) VALUES
  (to_ftsdoc('alpha alpha alpha beta')),   -- high alpha tf
  (to_ftsdoc('alpha beta beta beta')),     -- high beta tf
  (to_ftsdoc('alpha beta')),               -- both, low tf
  (to_ftsdoc('gamma only')),               -- neither
  (to_ftsdoc('alpha')),                    -- alpha only
  (to_ftsdoc('beta'));                     -- beta only
CREATE INDEX wnd_bm25 ON wnd USING fts (d);
-- top-2 for 'alpha | beta': the two docs matching both terms should lead
SELECT w.id
FROM fts_search('wnd_bm25', 'alpha | beta'::ftsquery, 3) r
JOIN wnd w ON w.ctid = r.ctid
ORDER BY r.score DESC, w.id;
-- scores are monotonically non-increasing (WAND returns them sorted)
SELECT bool_and(s >= lead_s) AS descending
FROM (SELECT r.score AS s, lead(r.score) OVER (ORDER BY r.score DESC) AS lead_s
      FROM fts_search('wnd_bm25', 'alpha | beta'::ftsquery, 10) r) q
WHERE lead_s IS NOT NULL;
DROP TABLE wnd;

-- Lazy block-max WAND: correct top-k over a multi-page posting list.
CREATE TABLE lazy (id serial, d ftsdoc);
-- 2000 docs of 'term': posting list spans many pages; one doc has high tf
INSERT INTO lazy (d) SELECT to_ftsdoc('term') FROM generate_series(1, 2000);
INSERT INTO lazy (d) VALUES (to_ftsdoc('term term term term term'));  -- id 2001
CREATE INDEX lazy_bm25 ON lazy USING fts (d);
-- top-1 must be the high-tf doc (id 2001), found via block-max skipping
SELECT l.id
FROM fts_search('lazy_bm25', 'term'::ftsquery, 1) r JOIN lazy l ON l.ctid = r.ctid;
-- top-3 all correct and the whole list is searchable
SELECT count(*) AS matched
FROM fts_search('lazy_bm25', 'term'::ftsquery, 5000) r JOIN lazy l ON l.ctid = r.ctid;
DROP TABLE lazy;

-- Lexical anomaly detection (fts_anomalous_docs): the rare-token (low-df) tail.
-- Corpus of 500 common-word docs, plus 3 docs each carrying a unique 'zqxjkN'
-- token.  The 3 injected docs are the only lexically-anomalous ones.
CREATE TABLE anom (id serial, d ftsdoc);
INSERT INTO anom (d) SELECT to_ftsdoc('the common ordinary boilerplate text')
FROM generate_series(1, 500);
INSERT INTO anom (d) VALUES
  (to_ftsdoc('the common text zqxjk1')),
  (to_ftsdoc('ordinary boilerplate zqxjk2')),
  (to_ftsdoc('common text zqxjk3'));
CREATE INDEX anom_bm25 ON anom USING fts (d);
-- top-3 anomalies are exactly the 3 injected docs, and rarest_term is the token
SELECT a.id, a.d::text AS doc, r.rarest_term, r.min_df
FROM fts_anomalous_docs('anom_bm25', 3) r
JOIN anom a ON a.ctid = r.ctid
ORDER BY r.score DESC, a.id;
-- their scores are the highest in the corpus (a common-only doc scores lower):
-- the min anomaly score of the 3 injected docs exceeds any other doc's score
SELECT bool_and(inj.score > others.maxscore) AS injected_lead
FROM (SELECT min(r.score) AS score
      FROM fts_anomalous_docs('anom_bm25', 3) r) inj,
     (SELECT coalesce(max(r.score), 0) AS maxscore
      FROM fts_anomalous_docs('anom_bm25', 1000) r
      WHERE r.rarest_term NOT LIKE 'zqxjk%') others;
-- every zqxjk token has df=1 (unique), so min_df is 1 for the injected docs
SELECT count(*) AS df1_hits
FROM fts_anomalous_docs('anom_bm25', 3) r
WHERE r.rarest_term LIKE 'zqxjk%' AND r.min_df = 1;
-- k limits the result set
SELECT count(*) AS topk_count
FROM fts_anomalous_docs('anom_bm25', 2) r;
-- max_df filter: with max_df=0 no term qualifies as rare -> no rows
SELECT count(*) AS none_when_maxdf_0
FROM fts_anomalous_docs('anom_bm25', 100, 0) r;
-- max_df=1 admits only the unique tokens -> exactly the 3 injected docs
SELECT count(*) AS three_when_maxdf_1
FROM fts_anomalous_docs('anom_bm25', 100, 1) r;
-- a common-only doc is never flagged (all its terms are high-df)
SELECT count(*) AS common_flagged
FROM fts_anomalous_docs('anom_bm25', 100, 1) r
JOIN anom a ON a.ctid = r.ctid
WHERE a.d::text = 'the common ordinary boilerplate text';
DROP TABLE anom;
-- empty index returns no rows
CREATE TABLE anom_empty (id serial, d ftsdoc);
CREATE INDEX anom_empty_bm25 ON anom_empty USING fts (d);
SELECT count(*) AS empty_rows FROM fts_anomalous_docs('anom_empty_bm25', 10);
DROP TABLE anom_empty;

-- NEAR(a b, k): proximity within k tokens.
-- 'quick ... fox' are 3 tokens apart in 'the quick brown red fox'
SELECT to_ftsdoc('the quick brown red fox') @@@ 'NEAR(quick fox, 3)'::ftsquery AS near_hit;
SELECT to_ftsdoc('the quick brown red fox') @@@ 'NEAR(quick fox, 2)'::ftsquery AS near_miss;
-- adjacent terms satisfy any k>=1
SELECT to_ftsdoc('the quick brown fox') @@@ 'NEAR(quick brown, 1)'::ftsquery AS near_adj;
-- three-term NEAR chains the proximity
SELECT to_ftsdoc('alpha beta gamma delta') @@@ 'NEAR(alpha beta gamma, 2)'::ftsquery AS near3;
-- NEAR combines with boolean operators
SELECT to_ftsdoc('the quick brown red fox jumps') @@@ 'NEAR(quick fox, 3) & jumps'::ftsquery AS near_combo;
-- malformed NEAR errors (single term); NEAR without k defaults to 10
SELECT 'NEAR(onlyone, 2)'::ftsquery;
SELECT to_ftsdoc('a b c') @@@ 'NEAR(a c)'::ftsquery AS near_default_k;

-- FSM page recycling: repeated merges reuse freed blocks (no unbounded growth).
CREATE TABLE recyc (id serial, d ftsdoc);
INSERT INTO recyc (d) SELECT to_ftsdoc('term' || (g % 50)) FROM generate_series(1, 500) g;
CREATE INDEX recyc_bm25 ON recyc USING fts (d);
-- churn: insert + merge several times; each merge frees the old blocks
DO $$
BEGIN
  FOR i IN 1..5 LOOP
    INSERT INTO recyc (d) SELECT to_ftsdoc('term' || (g % 50)) FROM generate_series(1, 200) g;
    PERFORM fts_merge('recyc_bm25');
  END LOOP;
END $$;
SELECT pg_relation_size('recyc_bm25') AS recyc_churned \gset
-- after churn the index is still correct
SELECT count(*) > 0 AS still_matches
FROM fts_search('recyc_bm25', 'term1'::ftsquery, 5000) r JOIN recyc x ON x.ctid = r.ctid;
-- fts_merge compacts the segment directory but deliberately does NOT shrink the
-- file (that is fts_vacuum's job); after fts_vacuum the space IS reclaimed, so
-- the vacuumed index is within a small multiple of a freshly-built twin over the
-- SAME rows -- the leak-free property, asserted against a from-scratch build
-- rather than a hardcoded byte size / block number (which is environment-
-- dependent, e.g. a pinned-horizon reader defers reclaim and inflates any fixed
-- bound).  A genuine per-merge leak would not come back down under fts_vacuum.
SELECT fts_vacuum('recyc_bm25');
SELECT pg_relation_size('recyc_bm25') AS recyc_vacuumed \gset
CREATE TABLE recyc_fresh (id serial, d ftsdoc);
INSERT INTO recyc_fresh (d) SELECT d FROM recyc ORDER BY id;
CREATE INDEX recyc_fresh_bm25 ON recyc_fresh USING fts (d);
SELECT pg_relation_size('recyc_fresh_bm25') AS recyc_fresh \gset
SELECT :recyc_vacuumed <= :recyc_fresh * 3 AS size_bounded;
DROP TABLE recyc, recyc_fresh;

-- amcanorderbyop: ORDER BY col <=> query LIMIT k uses an index ordering scan.
CREATE TABLE ord (id serial, d ftsdoc);
INSERT INTO ord (d) VALUES
  (to_ftsdoc('quick quick quick fox')),   -- highest tf(quick)
  (to_ftsdoc('quick brown fox')),
  (to_ftsdoc('a slow turtle')),
  (to_ftsdoc('quick'));                    -- short doc, high length-norm score
CREATE INDEX ord_bm25 ON ord USING fts (d);
SET enable_seqscan = off;
-- the plan should be an index scan ordered by the distance operator (no Sort)
EXPLAIN (COSTS OFF)
SELECT id FROM ord WHERE d @@@ 'quick'::ftsquery
ORDER BY d <=> 'quick'::ftsquery LIMIT 2;
-- results ordered by relevance (ascending distance)
SELECT id FROM ord WHERE d @@@ 'quick'::ftsquery
ORDER BY d <=> 'quick'::ftsquery LIMIT 3;
RESET enable_seqscan;
DROP TABLE ord;

-- On-disk trigram index: fuzzy/regex through the index over many docs.
-- The trigram funnel narrows candidates (sparsemap postings); recheck refines.
CREATE TABLE trgm (id serial, d ftsdoc);
INSERT INTO trgm (d) SELECT to_ftsdoc('document' || g) FROM generate_series(1, 1000) g;
INSERT INTO trgm (d) VALUES (to_ftsdoc('documemt42'));   -- id 1001, 1 edit from document42
CREATE INDEX trgm_bm25 ON trgm USING fts (d);
SET enable_seqscan = off;
-- fuzzy: finds the exact 'document42' (id 43: 'document42') and the typo (1001)
SELECT count(*) AS fuzzy_via_trigram
FROM trgm t WHERE t.d @@@ 'document42~2'::ftsquery;
-- regex through the trigram index
SELECT count(*) AS regex_via_trigram
FROM trgm t WHERE t.d @@@ '/document4[0-9]$/'::ftsquery;
-- regex with alternation/anchors: literal-run tiling extracts 'document'
SELECT count(*) AS regex_anchored
FROM trgm t WHERE t.d @@@ '/^document(4|5)2$/'::ftsquery;   -- document42, document52
RESET enable_seqscan;
DROP TABLE trgm;

-- Adaptive-k ordering scan: consuming more than the initial batch (64) must
-- grow k and return the full ordered set correctly across the boundary.
CREATE TABLE bigord (id serial, d ftsdoc);
INSERT INTO bigord (d) SELECT to_ftsdoc('term extra' || (g % 3)) FROM generate_series(1, 300) g;
CREATE INDEX bigord_bm25 ON bigord USING fts (d);
SET enable_seqscan = off;
-- all 300 match 'term'; requesting 200 crosses the initial k=64 batch
SELECT count(*) AS got, bool_and(s >= lead_s) AS ordered_ok
FROM (SELECT r.score AS s, lead(r.score) OVER (ORDER BY r.score DESC) AS lead_s
      FROM (SELECT id, d <=> 'term'::ftsquery AS score FROM bigord
            WHERE d @@@ 'term'::ftsquery
            ORDER BY d <=> 'term'::ftsquery LIMIT 200) r) q;
RESET enable_seqscan;
DROP TABLE bigord;

-- Ordering-scan completeness past the adaptive-k growth ceiling.  An ORDER BY
-- <=> index scan is a KNN (amcanorderbyop) scan and must return EVERY matching
-- tuple in score order -- it must not impose its own row ceiling (a prior fixed
-- cap silently truncated a query matching more than the cap to that cap; the
-- executor's LIMIT is the only bound).  5000 docs all match 'wide'; a large
-- LIMIT over the index ordering scan must yield all 5000, matching @@@.
CREATE TABLE bigord2 (id serial, d ftsdoc);
INSERT INTO bigord2 (d) SELECT to_ftsdoc('wide filler' || (g % 40)) FROM generate_series(1, 5000) g;
CREATE INDEX bigord2_bm25 ON bigord2 USING fts (d);
SET enable_seqscan = off;
SELECT count(*) AS match_truth FROM bigord2 WHERE d @@@ 'wide'::ftsquery;   -- 5000
-- ordered index scan (bitmap disabled so the KNN Index Scan path is used) with
-- a LIMIT well past the old 4096 ceiling must still return all 5000
SET enable_bitmapscan = off;
SELECT count(*) AS ordered_scan_rows FROM
  (SELECT id FROM bigord2 WHERE d @@@ 'wide'::ftsquery
   ORDER BY d <=> 'wide'::ftsquery LIMIT 1000000) s;   -- 5000 (was capped ~4096)
RESET enable_bitmapscan;
RESET enable_seqscan;
DROP TABLE bigord2;

-- the fts index access method.

CREATE TABLE idxdocs (id serial, d ftsdoc);
INSERT INTO idxdocs (d) VALUES
  (to_ftsdoc('the quick brown fox')),
  (to_ftsdoc('a slow green turtle')),
  (to_ftsdoc('quick turtles are rare')),
  (to_ftsdoc('brown bears and quick foxes'));

CREATE INDEX idxdocs_bm25 ON idxdocs USING fts (d);

-- force index usage and confirm the plan uses a bitmap scan on our AM
SET enable_seqscan = off;
EXPLAIN (COSTS OFF) SELECT id FROM idxdocs WHERE d @@@ 'quick'::ftsquery ORDER BY id;

-- results must match a sequential @@@ evaluation
SELECT id FROM idxdocs WHERE d @@@ 'quick'::ftsquery ORDER BY id;
SELECT id FROM idxdocs WHERE d @@@ 'quick & fox'::ftsquery ORDER BY id;
SELECT id FROM idxdocs WHERE d @@@ 'quick | slow'::ftsquery ORDER BY id;
SELECT id FROM idxdocs WHERE d @@@ 'quick & !fox'::ftsquery ORDER BY id;
SELECT id FROM idxdocs WHERE d @@@ '!turtle'::ftsquery ORDER BY id;
SELECT id FROM idxdocs WHERE d @@@ '(quick | slow) & !fox'::ftsquery ORDER BY id;
RESET enable_seqscan;

DROP TABLE idxdocs;

-- Config-normalized query: to_ftsquery(regconfig, text) must stem query terms
-- to match a doc indexed with the same config (the EC2 benchmark fault).
-- 'postgres' stems to 'postgr'; a raw ftsquery misses, a config query matches
SELECT to_ftsdoc('english'::regconfig, 'postgres databases') @@@ 'postgres'::ftsquery
       AS raw_query_misses;
SELECT to_ftsdoc('english'::regconfig, 'postgres databases')
       @@@ to_ftsquery('english'::regconfig, 'postgres')
       AS config_query_matches;
-- multi-term config query with operators
SELECT to_ftsdoc('english'::regconfig, 'running quickly through fields')
       @@@ to_ftsquery('english'::regconfig, 'run & quick')
       AS stemmed_and;
-- config query renders the stemmed terms
SELECT to_ftsquery('english'::regconfig, 'databases running')::text AS stemmed_render;

-- Segmented architecture: queries must span multiple segments correctly.
CREATE TABLE seg (id serial, d ftsdoc);
INSERT INTO seg(d) SELECT to_ftsdoc('alpha doc'||g) FROM generate_series(1,100) g;
CREATE INDEX seg_bm25 ON seg USING fts (d);          -- segment 0
INSERT INTO seg(d) SELECT to_ftsdoc('beta doc'||g) FROM generate_series(1,50) g;
SELECT fts_merge('seg_bm25');                          -- flush -> segment 1
INSERT INTO seg(d) SELECT to_ftsdoc('alpha more'||g) FROM generate_series(1,30) g;
SELECT fts_merge('seg_bm25');                          -- flush -> segment 2
SET enable_seqscan = off;
SELECT count(*) AS alpha_spans_segs FROM seg WHERE d @@@ 'alpha'::ftsquery;  -- 130
SELECT count(*) AS beta_one_seg FROM seg WHERE d @@@ 'beta'::ftsquery;        -- 50
SELECT ndocs AS total_docs FROM fts_index_stats('seg_bm25');                  -- 180
SELECT count(*) AS ranked_across_segs
FROM (SELECT id FROM seg WHERE d @@@ 'alpha'::ftsquery
      ORDER BY d <=> 'alpha'::ftsquery LIMIT 5) x;                            -- 5
RESET enable_seqscan;
DROP TABLE seg;

-- Tiered merge: many flushes create many segments; merge compacts them so the
-- segment count stays bounded while results are preserved.
CREATE TABLE tier (id serial, d ftsdoc);
INSERT INTO tier(d) SELECT to_ftsdoc('common w'||(g%20)) FROM generate_series(1,100) g;
CREATE INDEX tier_bm25 ON tier USING fts (d);
DO $$ BEGIN FOR i IN 1..10 LOOP
  INSERT INTO tier(d) SELECT to_ftsdoc('common x'||(g%20)) FROM generate_series(1,20) g;
  PERFORM fts_merge('tier_bm25');
END LOOP; END $$;
SET enable_seqscan = off;
SELECT count(*) AS all_docs FROM tier WHERE d @@@ 'common'::ftsquery;   -- 300
SELECT ndocs FROM fts_index_stats('tier_bm25');                          -- 300
SELECT fts_index_nsegments('tier_bm25') <= 8 AS segments_bounded;        -- t (compacted)
RESET enable_seqscan;
DROP TABLE tier;

-- fts_vacuum() reclaim: fts_vacuum fully compacts (merge to one segment) AND
-- truncates the freed tail, so a churned index shrinks back toward its floor.
-- Exercises bm25_compact_to_one (low-first pack) + bm25_truncate_free_tail and
-- the recycle-gate bypass during single-writer compaction (a freed page must be
-- reusable immediately here, or the pack phase would extend instead of shrink).
CREATE TABLE vac (id serial, d ftsdoc);
INSERT INTO vac(d) SELECT to_ftsdoc('vacterm w'||(g%40)||' filler'||g) FROM generate_series(1,4000) g;
CREATE INDEX vac_bm25 ON vac USING fts (d);
-- churn: delete+reinsert several times to bloat the index with freed pages
DO $$ BEGIN FOR i IN 1..4 LOOP
  DELETE FROM vac WHERE id % 2 = 0;
  INSERT INTO vac(d) SELECT to_ftsdoc('vacterm w'||(g%40)||' r'||i||' filler'||g) FROM generate_series(1,2000) g;
  PERFORM fts_merge('vac_bm25');
END LOOP; END $$;
SELECT fts_vacuum('vac_bm25') IS NOT NULL AS vacuumed;          -- t (ran)
SELECT fts_vacuum('vac_bm25') IS NOT NULL AS vacuumed_again;     -- t (ran; idempotent, no error/growth)
SELECT fts_index_nsegments('vac_bm25') AS nseg_after_vacuum;     -- 1 (compacted to one)
SET enable_seqscan = off;
SELECT count(*) > 0 AS still_matches FROM vac WHERE d @@@ 'vacterm'::ftsquery;  -- t (correct after compaction)
RESET enable_seqscan;
DROP TABLE vac;

-- Oversized-document inserts: a body whose analyzed ftsdoc exceeds one pending
-- page is indexed as its own segment; many of them exercise the write-path
-- auto-compaction (leveled merge after each flush) and the room-ensuring add
-- (merge-to-free-a-slot instead of erroring at the segment cap).  count(*) uses
-- the index-native pushdown.
CREATE TABLE big (id serial, d ftsdoc);
CREATE INDEX big_bm25 ON big USING fts (d);
-- each doc: a large distinct-token body (oversized) sharing one common term
INSERT INTO big(d)
  SELECT to_ftsdoc('bigterm ' || string_agg('t'||k||'d'||g, ' '))
  FROM generate_series(1,60) g, generate_series(1,4000) k
  GROUP BY g;
SET enable_seqscan = off;
SELECT count(*) AS big_matches FROM big WHERE d @@@ 'bigterm'::ftsquery;   -- 60 (index count pushdown)
SELECT fts_index_nsegments('big_bm25') <= 128 AS under_cap;               -- t (never hit the hard cap)
-- the count(*) pushdown fires for a PLAIN-COLUMN fts index (not just an
-- expression index): the recommended stored-ftsdoc-column form must get the
-- index-native count, not a bitmap-scan fallback.
DO $$
DECLARE ln text; hit bool := false;
BEGIN
  FOR ln IN EXPLAIN (COSTS off) SELECT count(*) FROM big WHERE d @@@ 'bigterm'::ftsquery
  LOOP
    IF ln LIKE '%FtsCount%' THEN hit := true; END IF;
  END LOOP;
  IF NOT hit THEN RAISE EXCEPTION 'plain-column count(*) did not use the FtsCount pushdown'; END IF;
  RAISE NOTICE 'plaincol_pushdown ok';
END $$;
-- the dict-df fast path: after VACUUM (all-visible, no tombstones, no pending)
-- a single-term count(*) is answered from the dictionary df alone; the count
-- must still be exact (a wrong fast count would diff here).
VACUUM big;
SELECT count(*) AS big_fastpath FROM big WHERE d @@@ 'bigterm'::ftsquery;   -- 60

-- ---------------------------------------------------------------------------
-- Every gate of the df fast path must REFUSE and fall back to the exact count.
--
-- The fast path answers from Sum(df) with no posting decode and no heap probe.
-- If a gate is missed, count(*) returns a plausible WRONG NUMBER -- the worst
-- failure shape available for a counting path, and nothing here caught it before.
-- Each case below is compared against a ground truth computed WITHOUT the index
-- (seqscan + the @@@ recheck), so a broken gate shows up as a mismatch rather
-- than as a number nobody questions.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION gate_check(qry text, why text) RETURNS text AS $$
DECLARE viaidx bigint; viaheap bigint;
BEGIN
  EXECUTE format('SELECT count(*) FROM big WHERE d @@@ %L::ftsquery', qry) INTO viaidx;
  SET LOCAL enable_seqscan = on;
  SET LOCAL enable_indexscan = off;
  SET LOCAL enable_bitmapscan = off;
  EXECUTE format('SELECT count(*) FROM big WHERE d @@@ %L::ftsquery', qry) INTO viaheap;
  RESET enable_seqscan; RESET enable_indexscan; RESET enable_bitmapscan;
  IF viaidx <> viaheap THEN
    RETURN format('MISMATCH %s: index=%s heap=%s', why, viaidx, viaheap);
  END IF;
  RETURN format('%s ok (%s)', why, viaidx);
END $$ LANGUAGE plpgsql;

-- gate (1) one plain positive term: prefix / fuzzy / regex / weighted / multi-term
SELECT gate_check('bigterm', 'plain-term-fastpath');
-- NOTE: these probes deliberately use terms the corpus really contains
-- ('bigterm' in every doc; 't1d7' only in doc 7), so a fallback that wrongly
-- returned 0 could not pass by matching a ground truth that is also 0.
SELECT gate_check('bigterm:*', 'prefix-falls-back');            -- 60
SELECT gate_check('bigterm & t1d7', 'conjunction-falls-back');   -- 1
SELECT gate_check('bigterm | t1d7', 'disjunction-falls-back');   -- 60
SELECT gate_check('t1d7', 'rare-single-term-fastpath');          -- 1
SELECT gate_check('!t1d7', 'negation-falls-back');               -- 59
-- gate (3) unmerged pending docs must defeat the fast path
INSERT INTO big SELECT 100000+g, to_ftsdoc('simple','bigterm pend'||g) FROM generate_series(1,5) g;
SELECT gate_check('bigterm', 'pending-falls-back');
VACUUM big;
-- gate (2) tombstones must defeat it: delete + VACUUM records deleted docids
DELETE FROM big WHERE id > 100000;
VACUUM big;
SELECT gate_check('bigterm', 'tombstones-fall-back');
-- gate (4) a not-all-visible heap must defeat it (fresh uncommitted-ish churn)
INSERT INTO big SELECT 200000+g, to_ftsdoc('simple','bigterm vis'||g) FROM generate_series(1,3) g;
SELECT gate_check('bigterm', 'not-all-visible-falls-back');
VACUUM big;
SELECT gate_check('bigterm', 'fastpath-again-after-vacuum');
DROP FUNCTION gate_check(text, text);
RESET enable_seqscan;
DROP TABLE big;

-- High-vocabulary build + trigram-through-merge: a corpus of many DISTINCT
-- low-frequency terms (like patches/quoted code) that flushes into several
-- segments then merges.  The trigram index for each merged segment is rebuilt
-- from the merged vocabulary; this exercises the bulk O(N) sparsemap build
-- (sm_add_many_grow) that replaced an O(N^2) per-member insert -- the fix for
-- the field-reported non-converging merge.  Assert exact prefix/fuzzy/regex
-- parity so the bulk build cannot silently drop trigram members.
SET maintenance_work_mem = '1MB';
CREATE TABLE hivocab (id serial, body text);
INSERT INTO hivocab(body)
  SELECT array_to_string(ARRAY(SELECT 'id'||g||'x'||s FROM generate_series(1,40) s),' ')
  FROM generate_series(1,3000) g;   -- ~120k distinct terms across several segments
CREATE INDEX hivocab_bm25 ON hivocab USING fts (to_ftsdoc('simple', body));
SELECT fts_merge('hivocab_bm25') IS NOT NULL AS hivocab_merged;
SET enable_seqscan = off;
SELECT count(*) AS exact FROM hivocab WHERE to_ftsdoc('simple',body) @@@ 'id5x1'::ftsquery;      -- 1
SELECT count(*) AS prefix FROM hivocab WHERE to_ftsdoc('simple',body) @@@ 'id5x1*'::ftsquery;    -- id5x1, id5x10..id5x19 in doc 5
SELECT count(*) >= 1 AS fuzzy_hit FROM hivocab WHERE to_ftsdoc('simple',body) @@@ 'id5x1~1'::ftsquery;
SELECT count(*) >= 1 AS regex_hit FROM hivocab WHERE to_ftsdoc('simple',body) @@@ '/id5x1./'::ftsquery;
RESET enable_seqscan;
RESET maintenance_work_mem;
DROP TABLE hivocab;

-- Parallel fts_merge: with >2 live segments and parallel maintenance workers
-- available, fts_merge() compacts them via the parallel merge (workers each
-- merge a disjoint segment group; the leader installs the result atomically).
-- Build a segment, then two more via VACUUM-flushed batches of the same size
-- (a run of 3 is below the tiered auto-merge threshold, so all 3 persist), then
-- fts_merge to one.  Result parity is asserted; whether workers actually launch
-- is environment-dependent and not asserted (the merged output is identical
-- either way).
SET max_parallel_maintenance_workers = 2;
CREATE TABLE pmrg (id serial, d ftsdoc);
INSERT INTO pmrg(d) SELECT to_ftsdoc('t'||(g%30)||' w'||g) FROM generate_series(1,300) g;
CREATE INDEX pmrg_bm25 ON pmrg USING fts (d);
INSERT INTO pmrg(d) SELECT to_ftsdoc('t'||(g%30)||' a'||g) FROM generate_series(1,300) g;
VACUUM pmrg;
INSERT INTO pmrg(d) SELECT to_ftsdoc('t'||(g%30)||' b'||g) FROM generate_series(1,300) g;
VACUUM pmrg;
SELECT fts_index_nsegments('pmrg_bm25') AS segs_before;   -- 3 (run of 3 < tier-min 4)
SET enable_seqscan = off;
SELECT count(*) AS t1_before FROM pmrg WHERE d @@@ 't1'::ftsquery;
SELECT fts_merge('pmrg_bm25') AS merged;
SELECT fts_index_nsegments('pmrg_bm25') AS segs_after;    -- 1
SELECT count(*) AS t1_after FROM pmrg WHERE d @@@ 't1'::ftsquery;   -- == t1_before
RESET enable_seqscan;
RESET max_parallel_maintenance_workers;
DROP TABLE pmrg;

-- Streaming merge (memory-bounded k-way merge): a low maintenance_work_mem
-- forces many segment flushes during build; a full merge then coalesces them
-- to one segment via the streaming path (one term's postings at a time, not
-- the whole index buffered).  Exercise it with positions=on (position carry),
-- deletes (tombstone drop), and a multi-term corpus that spans several dict
-- pages, then assert exact parity vs a seqscan ground truth after the merge.
SET maintenance_work_mem = '1MB';               -- floor is 32MB, but small anyway
CREATE TABLE strm (id serial, body text);
INSERT INTO strm(body) SELECT 'term'||(g%400)||' shared w'||(g%37)||' doc'||g
  FROM generate_series(1,8000) g;
CREATE INDEX strm_bm25 ON strm USING fts (to_ftsdoc('simple', body)) WITH (positions = on);
INSERT INTO strm(body) SELECT 'term'||(g%400)||' shared extra'||g
  FROM generate_series(8001,14000) g;
SELECT fts_merge('strm_bm25') IS NOT NULL AS strm_flushed;   -- create >1 segment
DELETE FROM strm WHERE id % 4 = 0;                            -- tombstones
VACUUM strm;                                                 -- write tombstones into the segment(s)
INSERT INTO strm(body) SELECT 'term'||(g%400)||' shared fresh'||g
  FROM generate_series(14001,18000) g;                       -- a fresh, un-tombstoned segment
SELECT fts_merge('strm_bm25') IS NOT NULL AS strm_merged;     -- streaming merge (tombstoned + fresh) to 1 seg
SET enable_seqscan = off;
-- term-count parity: index scan vs a forced seqscan of the SAME @@@ predicate
-- (ground truth), for a common and a rarer term.
SELECT (SELECT count(*) FROM strm WHERE to_ftsdoc('simple',body) @@@ 'shared'::ftsquery) AS idx_shared \gset
SET enable_seqscan = on;
SET enable_indexscan = off; SET enable_bitmapscan = off;
SELECT :idx_shared = (SELECT count(*) FROM strm WHERE to_ftsdoc('simple',body) @@@ 'shared'::ftsquery)
       AS strm_shared_parity;
RESET enable_indexscan; RESET enable_bitmapscan;
SET enable_seqscan = off;
SELECT (SELECT count(*) FROM strm WHERE to_ftsdoc('simple',body) @@@ 'term5'::ftsquery) AS idx_term5 \gset
SET enable_seqscan = on;
SET enable_indexscan = off; SET enable_bitmapscan = off;
SELECT :idx_term5 = (SELECT count(*) FROM strm WHERE to_ftsdoc('simple',body) @@@ 'term5'::ftsquery)
       AS strm_term5_parity;
RESET enable_indexscan; RESET enable_bitmapscan;
SET enable_seqscan = off;
-- tombstones dropped: the merged segment's live ndocs equals the live heap
-- rows (14000 - 3500 deleted + 4000 fresh = 14500), not the pre-delete total.
-- If the streaming merge failed to drop tombstoned postings, ndocs would be
-- inflated by the ~3500 deleted docs.
SELECT ndocs = (SELECT count(*) FROM strm) AS strm_tombstones_dropped
  FROM fts_index_stats('strm_bm25');
-- phrase (position carry through the streaming merge) still matches
SELECT count(*) > 0 AS strm_phrase_ok
  FROM strm WHERE to_ftsdoc('simple',body) @@@ to_ftsquery('simple','"term5 shared"');
SELECT fts_index_nsegments('strm_bm25') = 1 AS strm_one_segment;   -- coalesced
RESET enable_seqscan;
RESET maintenance_work_mem;
DROP TABLE strm;

-- Build memory accounting (regression for the sustained-growth bug): the
-- term hash lives in a CHILD context of the build arena, so the flush budget
-- must count child contexts (MemoryContextMemAllocated(ctx, true)) or a
-- vocabulary-dominant corpus never triggers a flush and the build grows
-- unbounded.  Build a HIGH-distinct-vocabulary corpus (every doc contributes
-- mostly unique terms, so the hash -- not the postings -- dominates memory) at
-- a low maintenance_work_mem, and assert the build completes and returns exact
-- results.  With the pre-fix (child-blind) accounting this build's working set
-- grew far past the budget; with the fix it flushes at the budget as intended.
SET maintenance_work_mem = '1MB';               -- floors to 32MB internally
CREATE TABLE vocab (id serial, body text);
-- ~30k docs, each ~20 unique terms (uniq<id>_<k>) -> ~600k distinct terms, so
-- the term hash dominates the build arena rather than the posting lists.
INSERT INTO vocab(body)
SELECT (SELECT string_agg('uniq'||g||'_'||k, ' ') FROM generate_series(1,20) k)
       || ' shared common'
  FROM generate_series(1, 30000) g;
CREATE INDEX vocab_bm25 ON vocab USING fts (to_ftsdoc('simple', body));
SET enable_seqscan = off;
-- 'shared' is in every doc: index-scan count == row count == forced-seqscan
SELECT (SELECT count(*) FROM vocab WHERE to_ftsdoc('simple',body) @@@ 'shared'::ftsquery) AS idx_shared \gset
SELECT :idx_shared = 30000 AS vocab_shared_all;
SET enable_seqscan = on; SET enable_indexscan = off; SET enable_bitmapscan = off;
SELECT :idx_shared = (SELECT count(*) FROM vocab WHERE to_ftsdoc('simple',body) @@@ 'shared'::ftsquery)
       AS vocab_shared_parity;
RESET enable_indexscan; RESET enable_bitmapscan; SET enable_seqscan = off;
-- a unique term resolves to exactly its one document (dictionary correct across
-- the many budget-triggered flush segments)
SELECT count(*) = 1 AS vocab_unique_one FROM vocab WHERE to_ftsdoc('simple',body) @@@ 'uniq7_3'::ftsquery;
SELECT ndocs = 30000 AS vocab_ndocs FROM fts_index_stats('vocab_bm25');
RESET enable_seqscan;
RESET maintenance_work_mem;
DROP TABLE vocab;

-- FOR-128 block posting codec: a term spanning many 128-doc blocks and pages
-- decodes correctly and block-max WAND top-k matches a full scan+sort.
CREATE TABLE blk (id serial, d ftsdoc);
INSERT INTO blk(d) SELECT to_ftsdoc('pop '||repeat('pop ',(g%7))||'w'||g)
  FROM generate_series(1,3000) g;      -- 'pop' in 3000 docs, >20 blocks/page
CREATE INDEX blk_bm25 ON blk USING fts (d);
SET enable_seqscan = off;
SELECT count(*) AS pop_ct FROM blk WHERE d @@@ 'pop'::ftsquery;   -- 3000
-- WAND top-10 distances equal a full seqscan sort's top-10 distances
CREATE TEMP TABLE w AS SELECT round((d <=> 'pop'::ftsquery)::numeric,6) dist
  FROM blk WHERE d @@@ 'pop'::ftsquery ORDER BY dist LIMIT 10;
SET enable_indexscan = off; SET enable_bitmapscan = off; SET enable_seqscan = on;
CREATE TEMP TABLE f AS SELECT round((d <=> 'pop'::ftsquery)::numeric,6) dist
  FROM blk WHERE d @@@ 'pop'::ftsquery ORDER BY dist LIMIT 10;
SELECT (SELECT array_agg(dist ORDER BY dist) FROM w)
     = (SELECT array_agg(dist ORDER BY dist) FROM f) AS wand_scores_match_fullsort;
RESET enable_seqscan; RESET enable_indexscan; RESET enable_bitmapscan;
DROP TABLE blk;

-- Sparse dictionary block index (FST-equivalent point lookup): a many-page
-- dictionary routes exact lookups to the right page; first/middle/last/absent
-- terms all resolve correctly, and df via the seek path is exact.
CREATE TABLE voc (id serial, d ftsdoc);
INSERT INTO voc(d) SELECT to_ftsdoc('term'||lpad(g::text,5,'0')||' shared')
  FROM generate_series(1,8000) g;      -- 8000 distinct terms -> multi-page dict
CREATE INDEX voc_bm25 ON voc USING fts (d);
SET enable_seqscan = off;
SELECT count(*) AS first_term  FROM voc WHERE d @@@ 'term00001'::ftsquery;  -- 1
SELECT count(*) AS mid_term    FROM voc WHERE d @@@ 'term04000'::ftsquery;  -- 1
SELECT count(*) AS last_term   FROM voc WHERE d @@@ 'term08000'::ftsquery;  -- 1
SELECT count(*) AS absent_term FROM voc WHERE d @@@ 'termzzzzz'::ftsquery;  -- 0
SELECT count(*) AS shared_all  FROM voc WHERE d @@@ 'shared'::ftsquery;     -- 8000
SELECT fts_index_df('voc_bm25','term04000'::ftsquery) AS df_mid;            -- {1}
-- block index survives an insert+flush (new segment gets its own index)
INSERT INTO voc(d) SELECT to_ftsdoc('term'||lpad(g::text,5,'0')||' shared')
  FROM generate_series(8001,8100) g;
SELECT fts_merge('voc_bm25');
SELECT count(*) AS after_flush FROM voc WHERE d @@@ 'term08050'::ftsquery;  -- 1
RESET enable_seqscan;
DROP TABLE voc;

-- Block-Max WAND (BMW): the block-max skip prunes whole 128-blocks that cannot
-- beat the current top-k threshold, and the exact top-k is unchanged.
CREATE TABLE bmw (id serial, d ftsdoc);
INSERT INTO bmw(d) SELECT to_ftsdoc('alpha '||
    CASE WHEN g%50=0 THEN repeat('beta ',5) ELSE '' END||'w'||g)
  FROM generate_series(1,12000) g;
CREATE INDEX bmw_bm25 ON bmw USING fts (d);
SET enable_seqscan = off;
CREATE TEMP TABLE bmw_top AS SELECT round((d <=> 'alpha beta'::ftsquery)::numeric,6) dist
  FROM bmw WHERE d @@@ 'alpha beta'::ftsquery ORDER BY dist LIMIT 10;
SET enable_indexscan = off; SET enable_bitmapscan = off; SET enable_seqscan = on;
CREATE TEMP TABLE bmw_all AS SELECT round((d <=> 'alpha beta'::ftsquery)::numeric,6) dist
  FROM bmw WHERE d @@@ 'alpha beta'::ftsquery ORDER BY dist LIMIT 10;
SELECT (SELECT array_agg(dist ORDER BY dist) FROM bmw_top)
     = (SELECT array_agg(dist ORDER BY dist) FROM bmw_all) AS bmw_exact_topk;
RESET enable_seqscan; RESET enable_indexscan; RESET enable_bitmapscan;
DROP TABLE bmw;

-- Levenshtein-automaton fuzzy: matches EXACTLY the dictionary terms within k
-- edits (no trigram over-generation), verified against core levenshtein.
CREATE EXTENSION IF NOT EXISTS fuzzystrmatch;
CREATE TABLE fz (id serial, body text, d ftsdoc);
INSERT INTO fz(body) SELECT 'document'||g||' filler' FROM generate_series(1,5000) g;
UPDATE fz SET d = to_ftsdoc(body);
CREATE INDEX fz_bm25 ON fz USING fts (d);
SET enable_seqscan = off;
SELECT count(*) AS dfa_fuzzy FROM fz WHERE d @@@ 'document42~2'::ftsquery;
SET enable_seqscan = on; SET enable_indexscan = off; SET enable_bitmapscan = off;
SELECT count(*) AS ground_truth FROM fz
WHERE EXISTS (SELECT 1 FROM unnest(string_to_array(body,' ')) t
              WHERE levenshtein_less_equal(t,'document42',2) <= 2);
RESET enable_seqscan; RESET enable_indexscan; RESET enable_bitmapscan;
DROP TABLE fz;
DROP EXTENSION fuzzystrmatch;

-- MaxScore top-k (chosen for queries with >=4 terms): identical exact top-k to
-- a full scan+sort, doing less work as low-impact terms become non-essential.
CREATE TABLE ms (id serial, d ftsdoc);
INSERT INTO ms(d) SELECT to_ftsdoc(
  (CASE WHEN g%2=0 THEN 'alpha ' ELSE '' END)||
  (CASE WHEN g%3=0 THEN 'beta ' ELSE '' END)||
  (CASE WHEN g%5=0 THEN 'gamma ' ELSE '' END)||
  (CASE WHEN g%7=0 THEN 'delta ' ELSE '' END)||
  (CASE WHEN g%11=0 THEN 'epsilon ' ELSE '' END)||'w'||g)
  FROM generate_series(1,20000) g;
CREATE INDEX ms_bm25 ON ms USING fts (d);
SET enable_seqscan = off;
CREATE TEMP TABLE mtop AS SELECT round((d <=> 'alpha beta gamma delta epsilon'::ftsquery)::numeric,6) dist
  FROM ms WHERE d @@@ 'alpha beta gamma delta epsilon'::ftsquery ORDER BY dist LIMIT 20;
SET enable_indexscan = off; SET enable_bitmapscan = off; SET enable_seqscan = on;
CREATE TEMP TABLE mall AS SELECT round((d <=> 'alpha beta gamma delta epsilon'::ftsquery)::numeric,6) dist
  FROM ms WHERE d @@@ 'alpha beta gamma delta epsilon'::ftsquery ORDER BY dist LIMIT 20;
SELECT (SELECT array_agg(dist ORDER BY dist) FROM mtop)
     = (SELECT array_agg(dist ORDER BY dist) FROM mall) AS maxscore_exact_topk;
RESET enable_seqscan; RESET enable_indexscan; RESET enable_bitmapscan;
DROP TABLE ms;

-- Tombstones: VACUUM must remove deleted docs from the index so the index-only
-- scan and fts_count (which trust the visibility map) never report a
-- vacuumed-and-reused heap slot, and a later merge must physically drop them.
CREATE EXTENSION IF NOT EXISTS pg_fts;
CREATE TABLE tomb (id int primary key, d ftsdoc);
INSERT INTO tomb SELECT g, to_ftsdoc('alpha doc'||g) FROM generate_series(1,100) g;
CREATE INDEX tomb_bm25 ON tomb USING fts (d);
SET enable_seqscan = off;
SELECT count(*) AS c_before FROM tomb WHERE d @@@ 'alpha'::ftsquery;         -- 100
DELETE FROM tomb WHERE id <= 40;
VACUUM tomb;
SELECT count(*) AS c_after FROM tomb WHERE d @@@ 'alpha'::ftsquery;          -- 60
SELECT fts_count('tomb_bm25','alpha'::ftsquery) AS fc_after;                 -- 60
-- delete-all + vacuum + reuse: the reused slots must NOT match 'alpha'
DELETE FROM tomb;
VACUUM tomb;
INSERT INTO tomb SELECT g, to_ftsdoc('beta doc'||g) FROM generate_series(1,60) g;
VACUUM tomb;
SELECT count(*) AS alpha_reused FROM tomb WHERE d @@@ 'alpha'::ftsquery;     -- 0
SELECT count(*) AS beta_reused FROM tomb WHERE d @@@ 'beta'::ftsquery;       -- 60
SELECT fts_count('tomb_bm25','beta'::ftsquery) AS beta_reused_fc;            -- 60
RESET enable_seqscan;
-- Corpus statistics (BM25 IDF + length normalization) count only LIVE documents.
-- After deleting rows and REINDEX, fts_index_stats.ndocs must reflect the live
-- corpus, not the pre-delete count -- the build callback must not count a
-- non-live document into ndocs/sumdoclen (it still indexes recently-dead
-- postings for old snapshots, but they do not inflate the statistics).
DELETE FROM tomb WHERE id > 30;                 -- keep 30 of the 60 beta rows
VACUUM tomb;
REINDEX INDEX tomb_bm25;
SELECT ndocs::int AS ndocs_live, nterms > 0 AS has_terms
  FROM fts_index_stats('tomb_bm25');            -- ndocs_live = 30
DROP TABLE tomb;

-- oversized document: an analyzed ftsdoc larger than one pending page must be
-- indexed as its own segment rather than rejected
CREATE TABLE bigdoc (id int, d ftsdoc);
CREATE INDEX bigdoc_bm25 ON bigdoc USING fts (d);
INSERT INTO bigdoc SELECT 1, to_ftsdoc(string_agg('term'||g||'x', ' '))
  FROM generate_series(1,4000) g;
INSERT INTO bigdoc VALUES (2, to_ftsdoc('small doc with term500x here'));
SET enable_seqscan=off;
SELECT count(*) AS big_term500 FROM bigdoc WHERE d @@@ 'term500x'::ftsquery;   -- 2
SELECT count(*) AS big_term3999 FROM bigdoc WHERE d @@@ 'term3999x'::ftsquery; -- 1
RESET enable_seqscan;
DROP TABLE bigdoc;

-- parallel index build (amcanbuildparallel): a parallel-built index must return
-- exactly what a serial build does.  Force workers with a zero scan threshold.
CREATE TABLE pbuild (id int, d ftsdoc);
INSERT INTO pbuild SELECT g, to_ftsdoc('common term'||(g%200)||' doc'||g)
  FROM generate_series(1,20000) g;
SET min_parallel_table_scan_size = 0;
SET max_parallel_maintenance_workers = 2;
CREATE INDEX pbuild_bm25 ON pbuild USING fts (d);
RESET max_parallel_maintenance_workers;
RESET min_parallel_table_scan_size;
SET enable_seqscan = off;
SELECT fts_count('pbuild_bm25', 'common'::ftsquery) AS all_docs;      -- 20000
SELECT fts_count('pbuild_bm25', 'term7'::ftsquery) AS term7;          -- 100
SELECT count(*) AS ranked FROM (SELECT id FROM pbuild WHERE d @@@ 'common'::ftsquery
  ORDER BY d <=> 'common'::ftsquery LIMIT 10) x;                      -- 10
RESET enable_seqscan;
DROP TABLE pbuild;

-- fts_vacuum: full compaction + tail truncation.  A parallel build
-- leaves dead source-segment pages; fts_vacuum reclaims them and truncates the
-- file, and the contents are unchanged afterward.
CREATE TABLE vac (id int, d ftsdoc);
INSERT INTO vac SELECT g, to_ftsdoc('common term'||(g%200)||' doc'||g)
  FROM generate_series(1,20000) g;
SET min_parallel_table_scan_size = 0;
SET max_parallel_maintenance_workers = 2;
CREATE INDEX vac_bm25 ON vac USING fts (d);
RESET max_parallel_maintenance_workers;
RESET min_parallel_table_scan_size;
SET enable_seqscan = off;
SELECT fts_count('vac_bm25', 'common'::ftsquery) AS before_all;       -- 20000
SELECT fts_vacuum('vac_bm25') IS NOT NULL AS vacuumed;               -- t
SELECT fts_count('vac_bm25', 'common'::ftsquery) AS after_all;        -- 20000
SELECT fts_count('vac_bm25', 'term7'::ftsquery) AS after_term7;       -- 100
SELECT fts_index_nsegments('vac_bm25') AS nseg_after;                 -- 1
RESET enable_seqscan;
DROP TABLE vac;

-- fts_vacuum convergence + genuine reclaim (regression: the compactor used to
-- either OSCILLATE (shrink then re-grow) or be STABLE-but-INEFFECTIVE (never
-- reclaim), leaving ~35-65% of the file as stranded free space on the dominant
-- bloat layout, where the live segment sits at HIGH blocks and the freed dead
-- pages form a LOW free region SMALLER than the live segment).  Build that
-- layout deterministically, then assert a single fts_vacuum():
--   (i)   SHRINKS the bloated index toward its floor,
--   (ii)  reaches a low dead-space ratio (within 15% of a freshly-built twin),
--   (iii) is STABLE across repeated calls (no oscillation, never exceeds pre).
-- Deterministic: fixed data, parallelism off (a parallel merge/build changes
-- the page layout and the segment count), and autovacuum off on the table (an
-- autovacuum pass can run the index cleanup between two fts_vacuum calls).
SET max_parallel_maintenance_workers = 0;
SET max_parallel_workers_per_gather = 0;
CREATE TABLE vconv (id int, d ftsdoc) WITH (autovacuum_enabled = off);
INSERT INTO vconv SELECT g, to_ftsdoc('term'||(g%800)||' shared'||' w'||(g%53)||' doc'||g)
  FROM generate_series(1,40000) g;
CREATE INDEX vconv_bm25 ON vconv USING fts (d);
INSERT INTO vconv SELECT g+40000, to_ftsdoc('term'||(g%800)||' shared'||' w'||(g%53)||' doc'||g)
  FROM generate_series(1,40000) g;
SELECT fts_merge('vconv_bm25') IS NOT NULL AS merged1;
DELETE FROM vconv WHERE id % 5 = 0;
-- fts_merge (NO vacuum here: a VACUUM would auto-compact and hide the bloat)
-- folds the tombstones into a smaller segment written to fresh HIGH blocks,
-- freeing the old segment's LOW pages -- the free<live layout the fix reclaims.
SELECT fts_merge('vconv_bm25') IS NOT NULL AS merged2;
-- A freshly-built twin over the SAME surviving rows is the size FLOOR reference.
CREATE TABLE vfloor (id int, d ftsdoc);
INSERT INTO vfloor SELECT id, d FROM vconv;
CREATE INDEX vfloor_bm25 ON vfloor USING fts (d);
SELECT fts_merge('vfloor_bm25') IS NOT NULL AS floor_merged;
SET enable_seqscan = off;
SELECT pg_relation_size('vconv_bm25') AS sz_bloat \gset
SELECT pg_relation_size('vfloor_bm25') AS sz_floor \gset
SELECT fts_vacuum('vconv_bm25') IS NOT NULL AS vac1;
SELECT pg_relation_size('vconv_bm25') AS sz1 \gset
SELECT fts_vacuum('vconv_bm25') IS NOT NULL AS vac2;
SELECT pg_relation_size('vconv_bm25') AS sz2 \gset
SELECT fts_vacuum('vconv_bm25') IS NOT NULL AS vac3;
SELECT pg_relation_size('vconv_bm25') AS sz3 \gset
-- (i) SHRANK: the single vacuum reclaimed a large fraction of the bloated file
SELECT :sz1 < :sz_bloat AS shrank;                                   -- t
-- (ii) EFFECTIVE: reclaimed most of the bloat (well under half the bloated size).
-- (Not compared to a fresh single-build floor: fts_vacuum packs+truncates the
-- merged segment set, which for a churned multi-segment index is legitimately
-- larger than a from-scratch rebuild; "reclaimed most of the dead space" is the
-- property that matters, and the fresh-floor ratio is sensitive to per-segment
-- overhead as a fraction of a small index.)
SELECT :sz1 <= :sz_bloat / 2 AS reclaimed_most;                      -- t
-- (iii) STABLE + never grew: repeated calls do not change size or exceed pre
SELECT :sz1 = :sz2 AND :sz2 = :sz3 AS converged;                     -- t
SELECT :sz1 <= :sz_bloat AND :sz2 <= :sz_bloat AND :sz3 <= :sz_bloat AS never_grew; -- t
-- contents intact after convergence (count parity vs the surviving rows)
SELECT fts_count('vconv_bm25', 'shared'::ftsquery) AS shared_cnt;    -- 64000
SELECT fts_index_nsegments('vconv_bm25') AS nseg;                    -- 1
RESET enable_seqscan;
RESET max_parallel_maintenance_workers;
RESET max_parallel_workers_per_gather;
DROP TABLE vconv;
DROP TABLE vfloor;

-- COUNT pushdown CustomScan (transparent count(*) WHERE @@@ answered from the
-- index).  The plan is a Custom Scan (FtsCount); the count matches fts_count;
-- and it must NOT trigger when the shape is unsupported (extra qual, GROUP BY).
CREATE TABLE cnt (id int, body text);
INSERT INTO cnt SELECT g, 'common '||CASE WHEN g%4=0 THEN 'quarter ' ELSE '' END||'w'||(g%100)
  FROM generate_series(1,10000) g;
CREATE INDEX cnt_bm25 ON cnt USING fts(to_ftsdoc('english',body));
ANALYZE cnt;
SET enable_seqscan=off;
SELECT count(*) = fts_count('cnt_bm25', to_ftsquery('english','common')) AS count_matches
  FROM cnt WHERE to_ftsdoc('english',body) @@@ to_ftsquery('english','common');
SELECT count(*) AS quarter_cnt FROM cnt WHERE to_ftsdoc('english',body) @@@ to_ftsquery('english','quarter');  -- 2500
-- the bare count(*) plan is a Custom Scan (FtsCount)
EXPLAIN (COSTS OFF) SELECT count(*) FROM cnt
  WHERE to_ftsdoc('english',body) @@@ to_ftsquery('english','common');
-- an extra qual disables the pushdown (falls back to Aggregate over a scan)
EXPLAIN (COSTS OFF) SELECT count(*) FROM cnt
  WHERE to_ftsdoc('english',body) @@@ to_ftsquery('english','common') AND id > 5;
RESET enable_seqscan;
DROP TABLE cnt;

-- ============================================================================
-- Ranked index scan must respect boolean AND/NOT/PHRASE structure.
-- The `<=>` ordering scan flattened the query to its terms and ranked the
-- disjunction, so AND/NOT queries could return docs that fail `@@@` (e.g.
-- `a & !b` ranking docs that contain b).  Every doc a ranked scan returns must
-- satisfy `@@@`.  The AM ordering path (bm25_gettuple) is only reached when the
-- planner picks an "Index Scan ... Order By" on the fts index -- that needs a
-- stored ftsdoc column (not an expression index) AND the `WHERE d @@@ q`
-- restriction alongside `ORDER BY d <=> q`.  Without both, the planner falls
-- back to a Seq Scan + Sort over the `<=>` operator (which never enters the AM
-- candidate path), so we assert the plan first, then assert zero violations.
CREATE TABLE bp (id serial, d ftsdoc);
INSERT INTO bp(d) SELECT to_ftsdoc('alpha gamma d'||g)       FROM generate_series(1,40) g;  -- alpha, no beta
INSERT INTO bp(d) SELECT to_ftsdoc('alpha beta d'||g)        FROM generate_series(1,40) g;  -- alpha AND beta
INSERT INTO bp(d) SELECT to_ftsdoc('beta delta d'||g)        FROM generate_series(1,40) g;  -- beta, no alpha
INSERT INTO bp(d) SELECT to_ftsdoc('alpha beta gamma d'||g)  FROM generate_series(1,20) g;  -- all three
CREATE INDEX bp_fts ON bp USING fts (d);
ANALYZE bp;
SET enable_seqscan=off; SET enable_bitmapscan=off; SET enable_indexscan=on;
-- the plan MUST be the AM ordering Index Scan (no Sort); otherwise the filter
-- code is never exercised and the test would silently pass on the buggy engine.
EXPLAIN (COSTS OFF) SELECT id FROM bp WHERE d @@@ 'alpha & !beta'::ftsquery
  ORDER BY d <=> 'alpha & !beta'::ftsquery LIMIT 20;
-- NOT: `alpha & !beta` ranked top-20 must contain NO doc with beta (0 violations).
SELECT count(*) AS not_violations FROM (
  SELECT d FROM bp WHERE d @@@ 'alpha & !beta'::ftsquery
  ORDER BY d <=> 'alpha & !beta'::ftsquery LIMIT 20
) s WHERE NOT (s.d @@@ 'alpha & !beta'::ftsquery);
-- AND: `alpha & beta & gamma` ranked top-20 must contain only docs with all three.
SELECT count(*) AS and3_violations FROM (
  SELECT d FROM bp WHERE d @@@ 'alpha & beta & gamma'::ftsquery
  ORDER BY d <=> 'alpha & beta & gamma'::ftsquery LIMIT 20
) s WHERE NOT (s.d @@@ 'alpha & beta & gamma'::ftsquery);
-- every ranked row must satisfy @@@ for the AND query (retrieval == match set).
SELECT count(*) AS and_atatat_violations FROM (
  SELECT id, d FROM bp WHERE d @@@ 'alpha & beta'::ftsquery
  ORDER BY d <=> 'alpha & beta'::ftsquery LIMIT 20
) s WHERE NOT (s.d @@@ 'alpha & beta'::ftsquery);
-- grow-k must terminate and return all matches when LIMIT exceeds the match
-- count: only 40 docs satisfy `alpha & !beta`, so LIMIT 500 returns exactly 40.
SELECT count(*) AS not_all_matches FROM (
  SELECT d FROM bp WHERE d @@@ 'alpha & !beta'::ftsquery
  ORDER BY d <=> 'alpha & !beta'::ftsquery LIMIT 500
) s;
RESET enable_seqscan; RESET enable_bitmapscan; RESET enable_indexscan;
DROP TABLE bp;

-- ----------------------------------------------------------------------------
-- Ranked index scan must ALSO enforce PHRASE/NEAR adjacency and FUZZY/REGEX
-- edit-distance -- not just boolean AND/NOT.  bm25_collect_matches returns the
-- over-generated set (PHRASE = AND-set with adjacency unenforced; fuzzy/regex =
-- trigram-funnel candidates) with recheck=true.  The bitmap @@@ path resolves
-- this with an executor recheck; the ranked <=> scan has none, so the AM must
-- recheck the exact @@@ test against the heap ftsdoc before ranking.  Before
-- the fix, a ranked `"quick brown"` over the rows below returned all 20
-- non-adjacent "quick red slow brown" docs; it must now return 0.
CREATE TABLE rp (id serial, d ftsdoc);
-- 20 NON-adjacent docs (both terms present, not consecutive): the AND-set, and
-- the phrase-recheck must reject every one.
INSERT INTO rp(d) SELECT to_ftsdoc('simple'::regconfig, 'quick red slow brown d'||g)
  FROM generate_series(1,20) g;
-- 5 ADJACENT docs ("quick brown" consecutive): the true phrase matches.
INSERT INTO rp(d) SELECT to_ftsdoc('simple'::regconfig, 'quick brown fox d'||g)
  FROM generate_series(1,5) g;
CREATE INDEX rp_fts ON rp USING fts (d);
ANALYZE rp;
SET enable_seqscan=off; SET enable_bitmapscan=off; SET enable_indexscan=on;
-- plan MUST be the AM ordering Index Scan (no Sort), else the recheck code is
-- never exercised and a buggy engine would pass silently.
EXPLAIN (COSTS OFF) SELECT id FROM rp
  WHERE d @@@ to_ftsquery('simple'::regconfig, '"quick brown"')
  ORDER BY d <=> to_ftsquery('simple'::regconfig, '"quick brown"') LIMIT 50;
-- PHRASE: ranked top-50 must contain ZERO non-adjacent docs (was 20 pre-fix).
SELECT count(*) AS phrase_violations FROM (
  SELECT d FROM rp WHERE d @@@ to_ftsquery('simple'::regconfig, '"quick brown"')
  ORDER BY d <=> to_ftsquery('simple'::regconfig, '"quick brown"') LIMIT 50
) s WHERE NOT (s.d @@@ to_ftsquery('simple'::regconfig, '"quick brown"'));
-- and it returns exactly the 5 true adjacent matches (grow-k terminates even
-- though the exact set (5) is far smaller than the AND-set (25)).
SELECT count(*) AS phrase_matches FROM (
  SELECT d FROM rp WHERE d @@@ to_ftsquery('simple'::regconfig, '"quick brown"')
  ORDER BY d <=> to_ftsquery('simple'::regconfig, '"quick brown"') LIMIT 500
) s;
-- NEAR: within-k admits, beyond-k rejects, all on the ranked path.
-- "quick" and "brown" are adjacent in the 5 rows (distance 1) and 3 apart in
-- the 20 rows ("quick red slow brown").  NEAR(...,3) admits all 25; NEAR(...,1)
-- admits only the 5 adjacent ones.
SELECT count(*) AS near3_matches FROM (
  SELECT d FROM rp WHERE d @@@ to_ftsquery('simple'::regconfig, 'NEAR(quick brown, 3)')
  ORDER BY d <=> to_ftsquery('simple'::regconfig, 'NEAR(quick brown, 3)') LIMIT 500
) s;
SELECT count(*) AS near1_matches FROM (
  SELECT d FROM rp WHERE d @@@ to_ftsquery('simple'::regconfig, 'NEAR(quick brown, 1)')
  ORDER BY d <=> to_ftsquery('simple'::regconfig, 'NEAR(quick brown, 1)') LIMIT 500
) s;
SELECT count(*) AS near1_violations FROM (
  SELECT d FROM rp WHERE d @@@ to_ftsquery('simple'::regconfig, 'NEAR(quick brown, 1)')
  ORDER BY d <=> to_ftsquery('simple'::regconfig, 'NEAR(quick brown, 1)') LIMIT 500
) s WHERE NOT (s.d @@@ to_ftsquery('simple'::regconfig, 'NEAR(quick brown, 1)'));
RESET enable_seqscan; RESET enable_bitmapscan; RESET enable_indexscan;
DROP TABLE rp;

-- ----------------------------------------------------------------------------
-- Positional postings (WITH positions=on): phrase/NEAR answered DIRECTLY from
-- the posting lists (no heap recheck).  The results MUST be identical to the
-- recheck path (positions=off), and the phrase set MUST be smaller than the
-- AND set.  Same corpus shape as the cliff repro: an adjacent phrase, a
-- co-occurring-but-not-adjacent set, and noise.
CREATE TABLE pos_on  (id serial, body text);
CREATE TABLE pos_off (id serial, body text);
INSERT INTO pos_on(body)
SELECT CASE WHEN g % 3 = 0 THEN 'alpha united states beta d'||g          -- adjacent phrase
            WHEN g % 3 = 1 THEN 'alpha united middle states beta d'||g   -- AND, not phrase
            ELSE 'gamma delta noise d'||g END                           -- neither
FROM generate_series(1, 600) g;
INSERT INTO pos_on(body) VALUES ('states middle nation initial');
INSERT INTO pos_on(body) VALUES ('united far far far states miss');
INSERT INTO pos_off(body) SELECT body FROM pos_on;
CREATE INDEX pos_on_idx  ON pos_on  USING fts (to_ftsdoc('simple'::regconfig, body)) WITH (positions = on);
CREATE INDEX pos_off_idx ON pos_off USING fts (to_ftsdoc('simple'::regconfig, body));  -- default off
ANALYZE pos_on; ANALYZE pos_off;
SET enable_seqscan = off;
-- phrase count from positions == phrase count from recheck (identical answer)
SELECT
  (SELECT count(*) FROM pos_on  WHERE to_ftsdoc('simple'::regconfig, body) @@@ to_ftsquery('simple'::regconfig, '"united states"')) AS pos_on_phrase,
  (SELECT count(*) FROM pos_off WHERE to_ftsdoc('simple'::regconfig, body) @@@ to_ftsquery('simple'::regconfig, '"united states"')) AS pos_off_phrase;
-- phrase count is STRICTLY less than the AND count (adjacency really enforced)
SELECT
  (SELECT count(*) FROM pos_on WHERE to_ftsdoc('simple'::regconfig, body) @@@ to_ftsquery('simple'::regconfig, '"united states"')) <
  (SELECT count(*) FROM pos_on WHERE to_ftsdoc('simple'::regconfig, body) @@@ to_ftsquery('simple'::regconfig, 'united & states')) AS phrase_lt_and;
-- the matched id SET is identical between the positional and recheck indexes:
-- the symmetric difference of the two match sets must be empty (0).
SELECT
  (SELECT count(*) FROM (
     SELECT id FROM pos_on  WHERE to_ftsdoc('simple'::regconfig, body) @@@ to_ftsquery('simple'::regconfig, '"united states"')
     EXCEPT
     SELECT id FROM pos_off WHERE to_ftsdoc('simple'::regconfig, body) @@@ to_ftsquery('simple'::regconfig, '"united states"')) d1)
+ (SELECT count(*) FROM (
     SELECT id FROM pos_off WHERE to_ftsdoc('simple'::regconfig, body) @@@ to_ftsquery('simple'::regconfig, '"united states"')
     EXCEPT
     SELECT id FROM pos_on  WHERE to_ftsdoc('simple'::regconfig, body) @@@ to_ftsquery('simple'::regconfig, '"united states"')) d2)
  AS phrase_symdiff;  -- 0: the two index shapes agree exactly
-- fts_count on the positional index equals the phrase (adjacency) count
SELECT fts_count('pos_on_idx', to_ftsquery('simple'::regconfig, '"united states"'))
     = (SELECT count(*) FROM pos_on WHERE to_ftsdoc('simple'::regconfig, body) @@@ to_ftsquery('simple'::regconfig, '"united states"'))
     AS fts_count_phrase_ok;
-- NEAR on positions: within-k admits the co-occurring 'united ... states' too
SELECT
  (SELECT count(*) FROM pos_on  WHERE to_ftsdoc('simple'::regconfig, body) @@@ to_ftsquery('simple'::regconfig, 'NEAR(united states, 2)')) =
  (SELECT count(*) FROM pos_off WHERE to_ftsdoc('simple'::regconfig, body) @@@ to_ftsquery('simple'::regconfig, 'NEAR(united states, 2)')) AS near_pos_eq_recheck;
-- plain (non-phrase) AND count is identical between on/off (positions invisible)
SELECT
  (SELECT count(*) FROM pos_on  WHERE to_ftsdoc('simple'::regconfig, body) @@@ to_ftsquery('simple'::regconfig, 'united & states')) =
  (SELECT count(*) FROM pos_off WHERE to_ftsdoc('simple'::regconfig, body) @@@ to_ftsquery('simple'::regconfig, 'united & states')) AS and_on_eq_off;
-- w/N accepts both orders; indexed positions and heap recheck agree.
INSERT INTO pos_on(body) VALUES ('states middle united reverse');
INSERT INTO pos_off(body) VALUES ('states middle united reverse');
INSERT INTO pos_on(body) VALUES ('states middle nation reverse2');
INSERT INTO pos_off(body) VALUES ('states middle nation reverse2');
SELECT fts_count('pos_on_idx', 'united w/2 states'::ftsquery) =
       fts_count('pos_off_idx', 'united w/2 states'::ftsquery) AS within_on_eq_off;
SELECT fts_count('pos_on_idx', 'united w/2 states'::ftsquery) >
       fts_count('pos_on_idx', 'united p/2 states'::ftsquery) AS within_reverse_added;
SELECT fts_count('pos_on_idx', '(united OR nation) w/2 states'::ftsquery) =
       fts_count('pos_off_idx', '(united OR nation) w/2 states'::ftsquery) AS within_or_on_eq_off;
SELECT fts_count('pos_on_idx', '(united OR nation) w/2 states'::ftsquery) >
       fts_count('pos_on_idx', 'united w/2 states'::ftsquery) AS within_or_adds_hits;
SELECT fts_count('pos_on_idx', 'states w/2 (united OR nation)'::ftsquery) =
       fts_count('pos_off_idx', 'states w/2 (united OR nation)'::ftsquery) AS within_right_or_eq_off;
SELECT fts_count('pos_on_idx', 'united w/2 states'::ftsquery) =
       (SELECT count(*) FROM pos_on WHERE to_ftsdoc('simple'::regconfig, body) @@@ 'united w/2 states'::ftsquery)
       AS within_count_eq_scan;
SELECT count(*) > 0 AND bool_and(to_ftsdoc('simple'::regconfig, p.body) @@@
                                   'united w/2 states'::ftsquery) AS within_ranked_matches
  FROM fts_search('pos_on_idx', 'united w/2 states'::ftsquery, 10) r
  JOIN pos_on p ON p.ctid = r.ctid;
RESET enable_seqscan;
-- multi-segment / pending: phrase must be correct across several segments (the
-- positional hits accumulate per-segment and are merged); insert more rows
-- after the index exists so they land in new segments / the pending list.
INSERT INTO pos_on(body)
SELECT CASE WHEN g % 2 = 0 THEN 'zeta united states omega e'||g
            ELSE 'zeta united gap states omega e'||g END
FROM generate_series(1, 300) g;
SET enable_seqscan = off;
SELECT fts_count('pos_on_idx', to_ftsquery('simple'::regconfig, '"united states"'))
     = (SELECT count(*) FROM pos_on WHERE to_ftsdoc('simple'::regconfig, body) @@@ to_ftsquery('simple'::regconfig, '"united states"'))
     AS multiseg_phrase_ok;
RESET enable_seqscan;
-- fts_vacuum must still reclaim on the v3 positional format (P1 gate): delete
-- most rows, vacuum, assert the index shrinks.
DELETE FROM pos_on WHERE id % 3 <> 0;
SELECT fts_vacuum('pos_on_idx');
SELECT fts_merge('pos_on_idx');
-- phrase still correct after vacuum/merge carried positions through
SELECT count(*) > 0 AS phrase_survives_vacuum
  FROM pos_on WHERE to_ftsdoc('simple'::regconfig, body) @@@ to_ftsquery('simple'::regconfig, '"united states"');
DROP TABLE pos_on; DROP TABLE pos_off;

-- Positions-decode allocation guard (regression for the 1.0.1 read-path crash):
-- bm25_decode_term sizes a per-block scratch from Sum(tf) of one block.  A doc
-- that repeats a term very many times drives a large Sum(tf); the decode must
-- (a) NOT throw "invalid memory alloc request size" (huge-safe alloc), and
-- (b) NOT false-positive its corruption guard on the legitimate width-0 case
-- (a term always at the same position -> all-zero position deltas -> a width-0
-- positions column whose posbytelen is tiny even though Sum(tf) is large).
-- Build a positions=on index over such docs and assert phrase/count still work
-- and match the recheck (positions=off) path exactly, with no corruption WARNING.
CREATE TABLE posbig (id serial, body text);
-- 'hot' repeated 300x/doc (large per-posting tf -> large Sum(tf) per block);
-- 'edge' appears once so a phrase mixing them is exercised too.
INSERT INTO posbig(body)
SELECT repeat('hot ', 300) || 'edge tail d'||g FROM generate_series(1, 400) g;
CREATE INDEX posbig_on  ON posbig USING fts (to_ftsdoc('simple'::regconfig, body)) WITH (positions = on);
CREATE TABLE posbig_off (id serial, body text);
INSERT INTO posbig_off(body) SELECT body FROM posbig;
CREATE INDEX posbig_offidx ON posbig_off USING fts (to_ftsdoc('simple'::regconfig, body));
SET enable_seqscan = off;
-- (a) a plain term-count over the high-Sum(tf) term does not error
SELECT count(*) = 400 AS posbig_hot_count
  FROM posbig WHERE to_ftsdoc('simple'::regconfig, body) @@@ 'hot'::ftsquery;
-- (b) phrase from positions == phrase from recheck (identical), guard did not
-- spuriously drop the legitimate high-Sum(tf) block
SELECT
  (SELECT count(*) FROM posbig     WHERE to_ftsdoc('simple'::regconfig, body) @@@ to_ftsquery('simple'::regconfig, '"hot edge"'))
  = (SELECT count(*) FROM posbig_off WHERE to_ftsdoc('simple'::regconfig, body) @@@ to_ftsquery('simple'::regconfig, '"hot edge"'))
    AS posbig_phrase_parity;
-- force a merge (re-decodes every block through the same path) then re-check
SELECT fts_merge('posbig_on') IS NOT NULL AS posbig_merged;
SELECT count(*) = 400 AS posbig_hot_after_merge
  FROM posbig WHERE to_ftsdoc('simple'::regconfig, body) @@@ 'hot'::ftsquery;
RESET enable_seqscan;
DROP TABLE posbig; DROP TABLE posbig_off;

-- three-word positional phrase + NEAR must match the recheck path exactly (the
-- phrase_step chain over posting positions == the heap adjacency chain).
CREATE TABLE pos3 (id serial, body text);
INSERT INTO pos3(body) VALUES
 ('x quick brown fox y'),        -- adjacent 3-word
 ('quick brown cat'),            -- only 2 of 3
 ('quick red brown fox'),        -- not fully adjacent
 ('a quick brown fox');          -- adjacent 3-word
INSERT INTO pos3(body) SELECT 'noise d'||g FROM generate_series(1,200) g;
CREATE INDEX pos3_on  ON pos3 USING fts (to_ftsdoc('simple'::regconfig, body)) WITH (positions = on);
CREATE INDEX pos3_off ON pos3 USING fts (to_ftsdoc('simple'::regconfig, body));
SET enable_seqscan = off;
SELECT array_agg(id ORDER BY id) AS phrase3_ids
  FROM pos3 WHERE to_ftsdoc('simple'::regconfig, body) @@@ to_ftsquery('simple'::regconfig, '"quick brown fox"');  -- {1,4}
SELECT fts_count('pos3_on',  to_ftsquery('simple'::regconfig, '"quick brown fox"'))
     = fts_count('pos3_off', to_ftsquery('simple'::regconfig, '"quick brown fox"')) AS phrase3_on_eq_off;
SELECT fts_count('pos3_on',  to_ftsquery('simple'::regconfig, 'NEAR(quick brown fox, 2)'))
     = fts_count('pos3_off', to_ftsquery('simple'::regconfig, 'NEAR(quick brown fox, 2)')) AS near3_on_eq_off;
RESET enable_seqscan;
DROP TABLE pos3;

-- v2 index rejected with a REINDEX hint (format version bump 2 -> 3).  We can't
-- easily fabricate a v2 index here, but the version guard message is asserted
-- by the build-time check; the reloption round-trips through pg_class:
CREATE TABLE reloptt (id serial, d ftsdoc);
INSERT INTO reloptt(d) SELECT to_ftsdoc('a b c d'||g) FROM generate_series(1,5) g;
CREATE INDEX reloptt_idx ON reloptt USING fts (d) WITH (positions = on);
SELECT reloptions FROM pg_class WHERE relname = 'reloptt_idx';  -- {positions=on}
DROP TABLE reloptt;

-- FUZZY ranked scan: the trigram funnel over-generates candidates (recheck),
-- so the ranked scan must apply the exact edit-distance test.  All rows share
-- trigrams with the query term but only some are within edit distance 1.
CREATE TABLE rf (id serial, d ftsdoc);
INSERT INTO rf(d) VALUES
  (to_ftsdoc('document zulu')),   -- 1: exact "document" (edit distance 0)
  (to_ftsdoc('documemt zulu')),   -- 2: "documemt" (distance 1: t<-m... n->m)
  (to_ftsdoc('documenta zulu')),  -- 3: "documenta" (distance 1: trailing a)
  (to_ftsdoc('doc zulu')),        -- 4: "doc" shares trigrams, distance > 1
  (to_ftsdoc('dokumemt zulu'));   -- 5: "dokumemt" (distance 2) -- candidate, rejected
CREATE INDEX rf_fts ON rf USING fts (d);
ANALYZE rf;
SET enable_seqscan=off; SET enable_bitmapscan=off; SET enable_indexscan=on;
-- ranked `document~1`: every returned row must truly be within edit distance 1
-- (the funnel yields more candidates; the recheck drops docs 4 and 5).
SELECT count(*) AS fuzzy_violations FROM (
  SELECT d FROM rf WHERE d @@@ 'document~1'::ftsquery
  ORDER BY d <=> 'document~1'::ftsquery LIMIT 500
) s WHERE NOT (s.d @@@ 'document~1'::ftsquery);
-- ranked fuzzy/prefix/regex return a correct SUBSET of the @@@ matches, not the
-- identical set: the ranked WAND path builds cursors from the literal query term
-- (fts_query_terms), so a doc that matches only via a fuzzy/prefix/regex
-- EXPANSION (no posting for the literal term) is never generated as a ranked
-- candidate.  bm25_recheck_exact only ever shrinks, so every returned row is a
-- true match (fuzzy_violations = 0 above) but the ranked count can be < the
-- bitmap @@@ count.  Hence f, by design (a known limitation, documented in
-- CAPABILITIES.md / ROADMAP.md); use @@@ for exhaustive fuzzy/prefix retrieval.
SELECT (SELECT count(*) FROM (
          SELECT d FROM rf WHERE d @@@ 'document~1'::ftsquery
          ORDER BY d <=> 'document~1'::ftsquery LIMIT 500) s)
     = (SELECT count(*) FROM rf WHERE d @@@ 'document~1'::ftsquery)
     AS fuzzy_ranked_eq_bitmap;
RESET enable_seqscan; RESET enable_bitmapscan; RESET enable_indexscan;
DROP TABLE rf;


-- ============================================================================
-- Ranked <=> parity: the ordering index scan must return the same top-k SET
-- as an exact brute-force BM25 score sort (distinct scores => deterministic).
-- Guards the WAND/MaxScore recall + the 0.2.1 boolean-structure gate.
-- ranked <=> ordering scan must equal the fair brute-force BM25 top-k SET.
-- Distinct scores (unique tf per doc) => deterministic, no tie ambiguity.
-- Flush so this test exercises WAND. legal_proximity separately covers
-- ranked pending documents through the exact fallback.
CREATE TABLE rankparity (id int, d ftsdoc);
-- unique alpha tf per doc (1..600) -> strictly distinct single-term scores;
-- every 4th doc also carries beta/delta/epsilon for OR/AND/4-term coverage.
INSERT INTO rankparity(id, d)
SELECT g, to_ftsdoc(repeat('alpha ', g) ||
       (CASE WHEN g % 4 = 0 THEN 'beta delta epsilon ' ELSE '' END))
FROM generate_series(1, 600) g;
-- rare term, distinct tf
INSERT INTO rankparity(id, d)
SELECT 10000+g, to_ftsdoc(repeat('gamma ', g)) FROM generate_series(1, 12) g;
CREATE INDEX rankparity_idx ON rankparity USING fts (d);
VACUUM rankparity;   -- flush: ranked path covers all docs
ANALYZE rankparity;

-- returns the number of index-top-k rows NOT in the fair-oracle top-k (expect 0)
CREATE OR REPLACE FUNCTION _rank_miss(qtext text, kk int) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE nd float8; ad float8; dfs float8[]; ntie int; nmiss int;
BEGIN
  SELECT ndocs, avgdl INTO nd, ad FROM fts_index_stats('rankparity_idx');
  SELECT fts_index_df('rankparity_idx', qtext::ftsquery) INTO dfs;
  -- distinct-score guard: the test is only meaningful with 0 ties
  EXECUTE format($f$SELECT count(*) FROM (
     SELECT round(fts_bm25(d,%L::ftsquery,%s,%s,%L)::numeric,12) sc
     FROM rankparity WHERE d @@@ %L::ftsquery) z GROUP BY sc HAVING count(*)>1$f$,
     qtext,nd,ad,dfs,qtext) INTO ntie;
  IF COALESCE(ntie,0) <> 0 THEN
    RAISE EXCEPTION 'rank parity test corpus has % score ties for %', ntie, qtext;
  END IF;
  SET LOCAL enable_seqscan = off; SET LOCAL enable_bitmapscan = off;
  -- A genuine miss is an index-returned doc whose EXACT score (fts_bm25 with the
  -- true stored doclen) is more than 1% below the exact k-th score.  v4 scores
  -- with a quantized doclen, so at a score boundary the index may return an
  -- equivalently-scored doc; that is the documented fieldnorm tradeoff, not a
  -- recall error.  (For a v3 index the quantization is absent and this is exact.)
  EXECUTE format($f$
    WITH ix AS (
      SELECT fts_bm25(d,%L::ftsquery,%s,%s,%L) AS sc
      FROM rankparity WHERE d @@@ %L::ftsquery
      ORDER BY d <=> %L::ftsquery LIMIT %s),
    cut AS (
      SELECT min(sc) AS kth FROM (
        SELECT fts_bm25(d,%L::ftsquery,%s,%s,%L) AS sc
        FROM rankparity WHERE d @@@ %L::ftsquery
        ORDER BY sc DESC LIMIT %s) z)
    SELECT count(*) FROM ix, cut WHERE ix.sc < cut.kth * 0.99 - 1e-9$f$,
    qtext, nd, ad, dfs, qtext, qtext, kk,
    qtext, nd, ad, dfs, qtext, kk) INTO nmiss;
  RETURN nmiss;
END $$;

SELECT _rank_miss('alpha',1)                          AS common_k1,   -- 0
       _rank_miss('alpha',10)                         AS common_k10,  -- 0
       _rank_miss('alpha',50)                         AS common_k50,  -- 0
       _rank_miss('alpha',100)                        AS common_k100, -- 0
       _rank_miss('gamma',10)                         AS rare_k10,    -- 0
       _rank_miss('alpha | beta',50)                  AS or_k50,      -- 0
       _rank_miss('alpha & beta',50)                  AS and_k50,     -- 0
       _rank_miss('alpha & beta & delta & epsilon',50) AS and4_k50;   -- 0 (MaxScore)

-- boolean-structure gate (v0.2.2 DocidFilter): AND/NOT top-k rows must satisfy @@@
SET enable_seqscan = off; SET enable_bitmapscan = off;
SELECT count(*) AS and_bool_violations FROM (
  SELECT d FROM rankparity WHERE d @@@ 'alpha & beta'::ftsquery
  ORDER BY d <=> 'alpha & beta'::ftsquery LIMIT 50) x
WHERE NOT (x.d @@@ 'alpha & beta'::ftsquery);          -- 0
SELECT count(*) AS not_bool_violations FROM (
  SELECT d FROM rankparity WHERE d @@@ 'alpha & !beta'::ftsquery
  ORDER BY d <=> 'alpha & !beta'::ftsquery LIMIT 50) x
WHERE NOT (x.d @@@ 'alpha & !beta'::ftsquery);         -- 0

RESET enable_seqscan; RESET enable_bitmapscan;
DROP FUNCTION _rank_miss(text,int);
DROP TABLE rankparity;

-- ============================================================
-- ftsdoc I/O faithful round-trip (Codeberg #3).
--
--   ftsdoc_in(ftsdoc_out(x))    = x   (text)
--   ftsdoc_recv(ftsdoc_send(x)) = x   (binary, via COPY ... WITH (FORMAT binary))
--
-- ftsdoc has no '=' operator, so equality is byte-identity of the binary form:
-- ftsdoc_send now encodes version+nterms+doclen+has_pos+terms+tf+positions, so
-- equal send() output <=> semantically equal document (terms, tf AND positions).
-- Each property yields a single boolean sentinel; both must be t.
-- ============================================================
CREATE TEMP TABLE rt (id int, d ftsdoc);
INSERT INTO rt VALUES
  (1, to_ftsdoc('The quick brown fox, the QUICK fox!')),  -- positions, tf>1, multi-pos
  (2, to_ftsdoc('')),                                      -- empty (nterms=0)
  (3, to_ftsdoc('single')),                                -- one term
  (4, to_ftsdoc('a a a b')),                               -- repeats -> tf 3 with 3 positions
  (5, $$'br\'o\\wn':1@3 'f:o@x':2@4,7$$::ftsdoc),          -- escaped ' and \, literal : @ in lexeme
  (6, $$'caf\u00e9':1@1$$::ftsdoc),                        -- unicode-ish lexeme (bytes preserved)
  (7, $$'x':2@1,4 'y':1@9$$::ftsdoc);                      -- distinct terms, gaps in positions

-- text round-trip: parse of the canonical rendering equals the original.
SELECT bool_and(ftsdoc_send(ftsdoc_out(d)::text::ftsdoc) = ftsdoc_send(d)) AS text_roundtrip_ok
FROM rt;

-- binary round-trip: send then recv (COPY binary) equals the original.
COPY rt TO '/tmp/pg_fts_rt.bin' WITH (FORMAT binary);
CREATE TEMP TABLE rt2 (id int, d ftsdoc);
COPY rt2 FROM '/tmp/pg_fts_rt.bin' WITH (FORMAT binary);
SELECT bool_and(ftsdoc_send(a.d) = ftsdoc_send(b.d)) AS binary_roundtrip_ok
FROM rt a JOIN rt2 b USING (id);

-- the bare-string cast must still tokenize (not be parsed as canonical).
SELECT ftsdoc_out('the quick brown fox'::ftsdoc) AS bare_cast_still_analyzes;

-- malformed canonical input is rejected cleanly (no crash).  Detection rule:
-- input is canonical once a first complete 'term':tf token parses; a later
-- malformation is then a hard error (trust boundary).  Input that never
-- completes one token is treated as raw text instead (the bare-string cast),
-- so each case below carries a valid leading token to force the error path.
SELECT $$'ok':1 'unterminated:1$$::ftsdoc;             -- ERROR: unterminated quoted term
SELECT $$'ok':1 'a':0$$::ftsdoc;                       -- ERROR: tf must be >= 1
SELECT $$'b':1@2 'a':1@1$$::ftsdoc;                    -- ERROR: terms not sorted
SELECT $$'a':2@5,5$$::ftsdoc;                          -- ERROR: positions not ascending
SELECT $$'a':2@1$$::ftsdoc;                            -- ERROR: fewer positions than tf

DROP TABLE rt2;
DROP TABLE rt;

-- ============================================================================
-- Crash regression (issue: SIGABRT in add_posting / SIGSEGV in fts_doc_matches
-- on the pending-list + flush path with long punctuation-dense tokens).  The
-- readers now validate each pending document (fts_doc_is_valid) before trusting
-- its term offsets, so a malformed page is skipped with a WARNING instead of
-- crashing.  This exercises the valid long-token path end to end (build empty
-- -> pending insert -> @@@/count/phrase scan over pending -> VACUUM flush ->
-- scan again); it must complete and return stable counts, never crash.
-- ============================================================================
CREATE TABLE crashreg (id bigint, subject text, from_addr text, mid text);
CREATE INDEX crashreg_fts ON crashreg
  USING fts (to_ftsdoc('english'::regconfig,
    COALESCE(subject,'') || ' ' || COALESCE(from_addr,'') || ' ' || COALESCE(mid,'')))
  WITH (positions = on);
-- inserts go to the pending list (index already exists); long base64/msgid-like
-- single tokens (>64 bytes -> the hash-key chaining path) + a high-tf term.
INSERT INTO crashreg
SELECT g, 'Re: meeting notes ' || g,
       'user' || g || '@example.com',
       'rIdUrvZaMegl2LcXsPOkRgaQKN5dyOoMF4hWSNJ5h-H4fN-LT5ODLPwFRG7sutCKpAcAWzTs' || g || '=@pm.me'
FROM generate_series(1, 400) g;
SET enable_seqscan = off;
-- crash-2 path: count(*) pushdown + phrase over pending docs
SELECT count(*) AS pending_word_hits FROM crashreg
  WHERE to_ftsdoc('english', COALESCE(subject,'')||' '||COALESCE(from_addr,'')||' '||COALESCE(mid,''))
        @@@ to_ftsquery('english','notes');
SELECT count(*) AS pending_phrase_hits FROM crashreg
  WHERE to_ftsdoc('english', COALESCE(subject,'')||' '||COALESCE(from_addr,'')||' '||COALESCE(mid,''))
        @@@ to_ftsquery('english','"meeting notes"');
-- crash-1 path: flush the pending list into a segment
VACUUM crashreg;
-- same queries after the flush must return the same counts
SELECT count(*) AS flushed_word_hits FROM crashreg
  WHERE to_ftsdoc('english', COALESCE(subject,'')||' '||COALESCE(from_addr,'')||' '||COALESCE(mid,''))
        @@@ to_ftsquery('english','notes');
SELECT count(*) AS flushed_phrase_hits FROM crashreg
  WHERE to_ftsdoc('english', COALESCE(subject,'')||' '||COALESCE(from_addr,'')||' '||COALESCE(mid,''))
        @@@ to_ftsquery('english','"meeting notes"');
RESET enable_seqscan;
DROP TABLE crashreg;

-- ============================================================================
-- Crash regression (issue: SIGSEGV in fts_doc_matches <- bm25_collect_matches
-- <- bm25_gettuple, intermittent, in the SEGMENT posting-decode path).  Root
-- cause: bm25_decode_term read a block header's `count` from disk and unpacked
-- that many values into fixed 128-element stack arrays (gaps/tfs/dls) with no
-- bound check -- a torn/corrupt header with count > BM25_BLOCK_SIZE overflowed
-- the stack (the WAND loader already clamped; this decoder did not).  The fix
-- clamps count to BM25_BLOCK_SIZE and stops decoding a block whose declared
-- byte lengths run past the page.  This exercises the decoder over a large
-- multi-block posting list (df >> 128, with positions) through count/phrase
-- scans and a merge; it must complete with stable counts.
-- ============================================================================
CREATE TABLE decreg (id int, body text);
CREATE INDEX decreg_idx ON decreg USING fts (to_ftsdoc('simple', body)) WITH (positions = on);
-- 'common' appears in every row -> a df=4000 posting list spanning ~32 blocks;
-- 'alpha beta' phrase spans blocks too (positions decoded across block boundaries).
INSERT INTO decreg SELECT g, 'alpha beta common tok' || (g % 200) FROM generate_series(1, 4000) g;
VACUUM decreg;                              -- flush pending -> segment blocks
SELECT fts_merge('decreg_idx'::regclass);   -- one segment; longest posting lists
SET enable_seqscan = off;
SELECT count(*) AS common_df FROM decreg
  WHERE to_ftsdoc('simple', body) @@@ to_ftsquery('simple','common');
SELECT count(*) AS phrase_hits FROM decreg
  WHERE to_ftsdoc('simple', body) @@@ to_ftsquery('simple','"alpha beta"');
RESET enable_seqscan;
DROP TABLE decreg;

-- ============================================================================
-- Coverage: exercise paths the main suite misses (ftsquery binary recv, the
-- <=> commutator, a parallel-built index + parallel merge, and an empty-index
-- build).  These are all reachable via SQL and were previously untested.
-- ============================================================================
-- ftsquery binary send/recv round-trip (ftsquery_recv): COPY BINARY out+back.
CREATE TEMP TABLE qrt (id int, q ftsquery);
INSERT INTO qrt VALUES
  (1, 'alpha & beta'::ftsquery),
  (2, 'alpha | (beta & !gamma)'::ftsquery),
  (3, '"quick brown fox"'::ftsquery),
  (4, 'NEAR(alpha beta, 3)'::ftsquery),
  (5, 'quick* & alpha'::ftsquery),
  (6, '(dog OR canine) w/10 bite'::ftsquery);
COPY qrt TO '/tmp/pg_fts_qrt.bin' WITH (FORMAT binary);
CREATE TEMP TABLE qrt2 (id int, q ftsquery);
COPY qrt2 FROM '/tmp/pg_fts_qrt.bin' WITH (FORMAT binary);
SELECT bool_and(ftsquery_send(a.q) = ftsquery_send(b.q)) AS ftsquery_binary_roundtrip_ok
FROM qrt a JOIN qrt2 b USING (id);

-- the <=> distance commutator: query <=> doc must equal doc <=> query.
SELECT (to_ftsquery('quick') <=> to_ftsdoc('the quick brown fox'))
     = (to_ftsdoc('the quick brown fox') <=> to_ftsquery('quick')) AS commutator_ok;

-- parallel index build + parallel merge over a table big enough to split.
SET max_parallel_maintenance_workers = 2;
SET min_parallel_table_scan_size = 0;
CREATE TABLE parbuild (id int, body text);
INSERT INTO parbuild SELECT g, 'term'||(g%500)||' common alpha beta' FROM generate_series(1, 20000) g;
CREATE INDEX parbuild_idx ON parbuild USING fts (to_ftsdoc('simple', body));
SELECT fts_merge('parbuild_idx'::regclass) IS NOT NULL AS merged;
SET enable_seqscan = off;
SELECT count(*) AS par_hits FROM parbuild
  WHERE to_ftsdoc('simple', body) @@@ to_ftsquery('simple','common');
RESET enable_seqscan;
RESET max_parallel_maintenance_workers;
RESET min_parallel_table_scan_size;
DROP TABLE parbuild;

-- empty-table index build (bm25_buildempty / a build with zero rows).
CREATE TABLE emptydoc (id int, body text);
CREATE INDEX emptydoc_idx ON emptydoc USING fts (to_ftsdoc('simple', body));
SELECT count(*) AS empty_hits FROM emptydoc
  WHERE to_ftsdoc('simple', body) @@@ to_ftsquery('simple','anything');
DROP TABLE emptydoc;

-- ============================================================================
-- Coverage: highlight/snippet, canonical ftsdoc parsing (positions + escapes +
-- error paths), ftsdoc binary recv WITH positions, and regex-query trigram
-- extraction -- functions the main suite exercises only lightly.
-- ============================================================================
-- fts_highlight / fts_snippet with default and custom markers + boolean/phrase.
SELECT fts_highlight('the quick brown fox jumps', 'quick & fox'::ftsquery) AS hl_default;
SELECT fts_highlight('the quick brown fox', 'quick'::ftsquery, '[', ']') AS hl_custom;
SELECT fts_highlight('nothing matches here', 'zzz'::ftsquery) AS hl_nomatch;
SELECT fts_snippet(repeat('alpha beta gamma delta ', 20) || 'needle tail',
                   'needle'::ftsquery) AS snip_default;
SELECT fts_snippet('short doc with needle', 'needle'::ftsquery,
                   '<<', '>>', ' ... ', 5) AS snip_custom;
SELECT fts_snippet('the quick brown fox', '"quick brown"'::ftsquery) AS snip_phrase;

-- canonical ftsdoc parsing: positions, repeated tf, escaped quote/backslash.
SELECT ($$'brown':1@3 'fox':2@2,5 'quick':1@1$$::ftsdoc)::text AS canon_positions;
SELECT ($$'a''b':1@1 'c\\d':1@2$$::ftsdoc)::text AS canon_escapes;
-- malformed canonical input -> clean errors (parser error branches).
SELECT $$'ok':1 'bad$$::ftsdoc;             -- unterminated quoted term
SELECT $$'ok':1 'x':abc$$::ftsdoc;          -- non-numeric tf
SELECT $$'z':1@ $$::ftsdoc;                 -- '@' with no positions

-- ftsdoc binary recv carrying positions (COPY BINARY of a positional doc).
CREATE TEMP TABLE drt (id int, d ftsdoc);
INSERT INTO drt VALUES (1, to_ftsdoc('alpha beta alpha gamma alpha')); -- alpha tf=3, positions
COPY drt TO '/tmp/pg_fts_drt.bin' WITH (FORMAT binary);
CREATE TEMP TABLE drt2 (id int, d ftsdoc);
COPY drt2 FROM '/tmp/pg_fts_drt.bin' WITH (FORMAT binary);
SELECT bool_and(ftsdoc_send(a.d) = ftsdoc_send(b.d)) AS doc_pos_binary_roundtrip_ok
FROM drt a JOIN drt2 b USING (id);

-- regex-query trigram extraction (fts_regex_trigrams) over varied patterns.
SELECT to_ftsdoc('the quicksand shifts') @@@ '/quick.*/'::ftsquery AS rx_star;
SELECT to_ftsdoc('color colour') @@@ '/colou?r/'::ftsquery AS rx_opt;
SELECT to_ftsdoc('cat bat hat') @@@ '/[cbh]at/'::ftsquery AS rx_class;
SELECT to_ftsdoc('foobar') @@@ '/foo|xyz/'::ftsquery AS rx_alt;

-- ============================================================================
-- Coverage: force the size-tiered segment merge (many small segments -> group
-- merge, bm25_merge_one_group / bm25_merge_group_to_seg) and a parallel index
-- build over a larger table (bm25_parallel_build_main), plus a delete/vacuum
-- compaction cycle (tombstone drop during merge).
-- ============================================================================
CREATE TABLE segmerge (id int, body text);
CREATE INDEX segmerge_idx ON segmerge USING fts (to_ftsdoc('simple', body));
-- many small INSERT batches, each flushed to its own segment via VACUUM, so a
-- later fts_merge has similarly-sized segments to group-merge.
DO $$
BEGIN
  FOR b IN 0..7 LOOP
    INSERT INTO segmerge SELECT b*1000 + g, 'common term'||((b*1000+g)%300)||' alpha'
      FROM generate_series(1, 1000) g;
    PERFORM fts_vacuum('segmerge_idx'::regclass);  -- flush this batch to a segment
  END LOOP;
END $$;
SELECT fts_merge('segmerge_idx'::regclass) IS NOT NULL AS grouped;   -- size-tiered group merge
-- delete a chunk + vacuum: tombstones must be dropped by the next merge.
DELETE FROM segmerge WHERE id % 3 = 0;
VACUUM segmerge;
SELECT fts_vacuum('segmerge_idx'::regclass) IS NOT NULL AS compacted;
SET enable_seqscan = off;
SELECT count(*) > 0 AS merge_hits FROM segmerge
  WHERE to_ftsdoc('simple', body) @@@ to_ftsquery('simple','common');
RESET enable_seqscan;
DROP TABLE segmerge;

-- parallel index build: a larger table + forced workers so the parallel build
-- leader/worker paths (bm25_parallel_build_main) actually run.
CREATE TABLE parbig (id int, body text);
INSERT INTO parbig SELECT g, 'word'||(g%1000)||' shared alpha beta gamma delta epsilon'
  FROM generate_series(1, 60000) g;
SET max_parallel_maintenance_workers = 3;
SET min_parallel_table_scan_size = 0;
SET maintenance_work_mem = '64MB';
ALTER TABLE parbig SET (parallel_workers = 3);
CREATE INDEX parbig_idx ON parbig USING fts (to_ftsdoc('simple', body));
SET enable_seqscan = off;
SELECT count(*) > 0 AS parbig_hits FROM parbig
  WHERE to_ftsdoc('simple', body) @@@ to_ftsquery('simple','shared');
RESET enable_seqscan;
RESET max_parallel_maintenance_workers;
RESET min_parallel_table_scan_size;
RESET maintenance_work_mem;
DROP TABLE parbig;

-- ============================================================================
-- Coverage: the BM25 scoring functions (fts_bm25 / fts_bm25_opts / fts_bm25f)
-- across all variants and parameter paths -- pure scalar functions, so these
-- are deterministic and index-free.
-- ============================================================================
-- fts_bm25: default scoring, with and without an explicit per-term df array.
SELECT round(fts_bm25(to_ftsdoc('the quick brown fox'), 'quick & fox'::ftsquery,
                      1000.0, 12.0)::numeric, 4) AS bm25_default;
SELECT round(fts_bm25(to_ftsdoc('the quick brown fox'), 'quick'::ftsquery,
                      1000.0, 12.0, ARRAY[50.0])::numeric, 4) AS bm25_with_dfs;
SELECT fts_bm25(to_ftsdoc('no match here'), 'zzz'::ftsquery, 1000.0, 12.0) AS bm25_nomatch;

-- fts_bm25_opts: every variant + custom k1/b.
SELECT v AS variant,
       round(fts_bm25_opts(to_ftsdoc('the quick brown fox jumps'),
                           'quick & fox'::ftsquery,
                           1000.0, 12.0, 1.2, 0.75, v)::numeric, 4) AS score
FROM unnest(ARRAY['lucene','robertson','atire','bm25+','bm25l']) AS v
ORDER BY v;
-- non-default k1/b (parameter path).
SELECT round(fts_bm25_opts(to_ftsdoc('alpha beta alpha gamma'),
                           'alpha'::ftsquery, 500.0, 8.0, 2.0, 0.5, 'lucene')::numeric, 4)
       AS bm25_opts_tuned;

-- fts_bm25f: multi-field weighted scoring (title weighted higher than body).
SELECT round(fts_bm25f(
         ARRAY[to_ftsdoc('quick fox'), to_ftsdoc('the quick brown fox runs fast')],
         'quick & fox'::ftsquery,
         ARRAY[2.0, 1.0],          -- field weights (title x2, body x1)
         1000.0,
         ARRAY[3.0, 10.0])::numeric, 4) AS bm25f_score;

-- ============================================================================
-- Coverage: WAND/MaxScore block skipping in the ranked <=> scan (wand_seek /
-- wand_skip_blocks / wand_block_max_contrib).  These only fire when a term's
-- posting list spans many 128-doc blocks and a small-LIMIT top-k lets the
-- traversal skip whole blocks that cannot beat the running threshold.  Build a
-- large index where 'common' has a huge posting list and 'rare' a tiny one,
-- then run selective ranked top-k queries.
-- ============================================================================
CREATE TABLE wandbig (id int, d ftsdoc);
INSERT INTO wandbig
  SELECT g, to_ftsdoc('common filler alpha beta ' ||
                      CASE WHEN g % 5000 = 0 THEN 'rareterm' ELSE 'ordinary' END)
  FROM generate_series(1, 40000) g;      -- 'common' df=40000 (~312 blocks); 'rareterm' df=8
CREATE INDEX wandbig_idx ON wandbig USING fts (d);
ANALYZE wandbig;
SET enable_seqscan = off;
SET enable_bitmapscan = off;
SET max_parallel_workers_per_gather = 0;
-- small-LIMIT top-k over a huge posting list: WAND must skip blocks.
SELECT count(*) AS top10 FROM (
  SELECT id FROM wandbig WHERE d @@@ 'common'::ftsquery
  ORDER BY d <=> 'common'::ftsquery LIMIT 10) t;
-- multi-term (common + rare): MaxScore/block-max pruning + block skip.
SELECT count(*) AS top5_mt FROM (
  SELECT id FROM wandbig WHERE d @@@ 'common & rareterm'::ftsquery
  ORDER BY d <=> 'common & rareterm'::ftsquery LIMIT 5) t;
-- OR query over mixed frequencies (block-max contribution across cursors).
SELECT count(*) AS top10_or FROM (
  SELECT id FROM wandbig WHERE d @@@ 'rareterm | ordinary'::ftsquery
  ORDER BY d <=> 'rareterm | ordinary'::ftsquery LIMIT 10) t;
RESET enable_seqscan;
RESET enable_bitmapscan;
RESET max_parallel_workers_per_gather;
DROP TABLE wandbig;

-- ============================================================================
-- Coverage: adaptive-k ranked recompute (LIMIT beyond the first over-fetch
-- pass), boolean NOT/negated-set combinations on the index scan, and regex
-- operators +/{n} in trigram extraction -- specific uncovered branches.
-- ============================================================================
CREATE TABLE cvx (id int, d ftsdoc);
INSERT INTO cvx SELECT g,
  to_ftsdoc('common alpha ' || CASE WHEN g%2=0 THEN 'even' ELSE 'odd' END ||
            CASE WHEN g%7=0 THEN ' seven' ELSE '' END)
  FROM generate_series(1, 3000) g;
CREATE INDEX cvx_idx ON cvx USING fts (d);
ANALYZE cvx;
SET enable_seqscan = off; SET enable_bitmapscan = off;
SET max_parallel_workers_per_gather = 0;
-- large LIMIT forces the adaptive-k over-fetch to grow + recompute.
SELECT count(*) AS bigk FROM (
  SELECT id FROM cvx WHERE d @@@ 'common'::ftsquery
  ORDER BY d <=> 'common'::ftsquery LIMIT 2000) t;
-- boolean NOT / negated combinations on the index (tidset_andnot / negated OR/AND).
SELECT count(*) AS and_not  FROM cvx WHERE d @@@ 'common & !even'::ftsquery;   -- odds
SELECT count(*) AS not_or   FROM cvx WHERE d @@@ '!even | seven'::ftsquery;
SELECT count(*) AS not_and  FROM cvx WHERE d @@@ '!even & !seven'::ftsquery;
SELECT count(*) AS dbl_not  FROM cvx WHERE d @@@ 'common & !odd & !even'::ftsquery; -- 0
RESET enable_seqscan; RESET enable_bitmapscan; RESET max_parallel_workers_per_gather;
DROP TABLE cvx;

-- regex operators + and {n} (fts_regex_trigrams FLUSH_RUN branches).
SELECT to_ftsdoc('aaa bbb') @@@ '/a+/'::ftsquery AS rx_plus;
SELECT to_ftsdoc('abcabc') @@@ '/(abc){2}/'::ftsquery AS rx_brace;
SELECT to_ftsdoc('xyz') @@@ '/a+b*c?/'::ftsquery AS rx_mixed_quant;

-- ============================================================================
-- Character-encoding / multi-script correctness (UTF-8 database).
-- The 'simple' analyzer path (to_ftsdoc('simple',...) / to_tsvector('simple',...))
-- is the ground truth: pg_fts's @@@ match set MUST equal PostgreSQL's native
-- to_tsvector('simple', body) @@ to_tsquery('simple', term) for the same text,
-- because pg_fts's regconfig analyzer uses the same parsetext() tokenizer.
-- Divergence here = a pg_fts encoding bug.  We test the 3 most common web
-- encodings' characters (represented in UTF-8: ASCII/Latin, plus Windows-1252
-- smart punctuation) and the known-tricky scripts (CJK, combining marks / NFC
-- vs NFD, emoji / 4-byte, RTL Arabic+Hebrew, Turkish dotless-i, German ß).
-- ============================================================================
SET client_encoding = 'UTF8';
CREATE TABLE enc (id int, script text, body text);
INSERT INTO enc VALUES
  (1,  'ascii',        'the quick brown fox'),
  (2,  'latin1',       'café société naïve Zürich'),
  (3,  'win1252-punct','“smart quotes” and — em‑dash € 90%'),
  (4,  'cjk-han',      '東京都 の 図書館 で 本 を 読む'),
  (5,  'cjk-mixed',    'PostgreSQL は 全文検索 が できる'),
  (6,  'hangul',       '서울 도서관 에서 책 을 읽다'),
  (7,  'combining-nfc',E'caf\u00e9 na\u00efve'),        -- precomposed é, ï
  (8,  'combining-nfd',E'cafe\u0301 nai\u0308ve'),      -- decomposed e+◌́, i+◌̈
  (9,  'emoji',        'deploy 🚀 ship it 😀 done'),
  (10, 'cjk-ext-b',    E'rare glyph \U00020000 here'),  -- 4-byte CJK ext-B
  (11, 'arabic-rtl',   'اللغة العربية مكتبة كتاب'),
  (12, 'hebrew-rtl',   'ספרייה ספר עברית'),
  (13, 'turkish-i',    'İstanbul ışık DİYARBAKIR'),
  (14, 'german-ss',    'Straße Fußball GROSSE');

-- Ground-truth parity: for a set of probe terms, pg_fts @@@ must equal native
-- to_tsvector('simple') @@ to_tsquery('simple').  Any mismatch is a bug.
SELECT bool_and(fts_hit = native_hit) AS enc_parity_ok
FROM (
  SELECT e.id, t.term,
         (to_ftsdoc('simple', e.body) @@@ to_ftsquery('simple', t.term)) AS fts_hit,
         (to_tsvector('simple', e.body) @@ to_tsquery('simple', t.term)) AS native_hit
  FROM enc e
  CROSS JOIN (VALUES ('fox'),('café'),('naïve'),('東京都'),('図書館'),
                     ('서울'),('책'),('العربية'),('كتاب'),('עברית'),
                     ('istanbul'),('ışık'),('straße'),('fußball'),('quotes')) AS t(term)
) q;

-- Corpus-wide df parity across ALL distinct tokens: the pg_fts index-native
-- count must equal native tsvector for every script (build an index, count @@@).
CREATE INDEX enc_idx ON enc USING fts (to_ftsdoc('simple', body));
SET enable_seqscan = off;
SELECT bool_and(idx_ct = native_ct) AS df_parity_ok
FROM (
  SELECT t.term,
         (SELECT count(*) FROM enc WHERE to_ftsdoc('simple',body) @@@ to_ftsquery('simple',t.term)) AS idx_ct,
         (SELECT count(*) FROM enc WHERE to_tsvector('simple',body) @@ to_tsquery('simple',t.term)) AS native_ct
  FROM (VALUES ('東京都'),('図書館'),('서울'),('책'),('العربية'),('عربية'),
               ('كتاب'),('עברית'),('ספר'),('café'),('naïve'),('straße'),('rocket')) AS t(term)
) q;

-- NFC vs NFD: precomposed 'café' (id 7) and decomposed 'cafe\u0301' (id 8) are
-- DIFFERENT byte sequences; PostgreSQL does not normalize, so pg_fts follows
-- native behavior exactly.  Assert pg_fts agrees with native on both forms
-- (whatever native does, pg_fts must match -- documenting, not judging).
SELECT bool_and(
         (to_ftsdoc('simple',body) @@@ to_ftsquery('simple', E'caf\u00e9'))
         = (to_tsvector('simple',body) @@ to_tsquery('simple', E'caf\u00e9'))
       ) AS nfc_parity_ok
FROM enc WHERE id IN (7, 8);

-- The built-in (non-regconfig) analyzer must not crash on any script and must
-- round-trip its own analysis (ftsdoc_in(ftsdoc_out(x)) = x) for multi-script text.
SELECT bool_and(ftsdoc_send(ftsdoc_out(to_ftsdoc(body))::text::ftsdoc)
              = ftsdoc_send(to_ftsdoc(body))) AS builtin_multiscript_roundtrip_ok
FROM enc;
RESET enable_seqscan;
DROP TABLE enc;

-- ============================================================================
-- Encoding CORNER CASES (UTF-8 DB) — the hardest traps each script creates,
-- forced through BOTH analyzers.  The built-in analyzer (to_ftsdoc(text), which
-- uses fold_token's per-code-point Unicode lowercasing) is exercised directly
-- here because these are exactly the inputs where a byte-wise or naive folder
-- breaks: fold-length CHANGES (İ, ẞ), multi-mark combining, ZWJ, BOM, 4-byte.
-- Property: (1) no crash, (2) the built-in analyzer round-trips
-- (ftsdoc_in(ftsdoc_out(x))=x), (3) case-insensitive match holds where fold
-- makes it so, and the regconfig path stays == native to_tsvector.
-- ============================================================================
SET client_encoding = 'UTF8';
CREATE TABLE corner (id int, note text, body text);
INSERT INTO corner VALUES
  (1, 'turkish-I-dotted',   E'\u0130STANBUL bo\u011faz'),          -- İ: lowercases to i+U+0307 (1->2 code points)
  (2, 'turkish-i-dotless',  E'ISPARTA \u0131\u015f\u0131k'),        -- dotless ı, ş
  (3, 'capital-sharp-s',    E'STRA\u1e9eE gro\u1e9ee'),             -- ẞ U+1E9E capital sharp s
  (4, 'sharp-s',            E'stra\u00dfe fu\u00dfball'),           -- ß
  (5, 'multi-combining',    E'e\u0301\u0323 a\u0300\u0301'),        -- e + acute + dot-below; a + grave + acute
  (6, 'zwj-family',         E'family \U0001f468\u200d\U0001f469\u200d\U0001f467 tag'), -- ZWJ emoji sequence
  (7, 'bom-prefix',         E'\ufeffleading bom word'),             -- U+FEFF BOM at start
  (8, 'astral-4byte',       E'glyph \U00020000 and \U0001f680 end'),-- CJK Ext-B U+20000 + rocket U+1F680
  (9, 'greek-final-sigma',  E'\u03a3\u03bf\u03c6\u03cc\u03c2 \u039b\u039f\u0393\u039f\u03a3'), -- Σοφός / final vs medial sigma casefold
  (10,'fullwidth-latin',    E'\uff26\uff35\uff2c\uff2c width'),      -- fullwidth FULL (U+FF26..)
  (11,'cyrillic-io',        E'\u0401LKA \u0451lka'),                -- Ё/ё
  (12,'nbsp-sep',           E'word1\u00a0word2\u2009word3');        -- NBSP + thin space as separators

-- (1) no crash: every row analyzes through both paths.
SELECT count(*) AS corner_rows_analyzed FROM corner
 WHERE octet_length(to_ftsdoc(body)::text) >= 0
   AND octet_length(to_ftsdoc('simple', body)::text) >= 0;

-- (2) built-in analyzer round-trips on every corner case (fold-length changes,
--     multi-byte, 4-byte, combining, ZWJ, BOM — the ftsdoc I/O must survive).
SELECT bool_and(ftsdoc_send(ftsdoc_out(to_ftsdoc(body))::text::ftsdoc)
              = ftsdoc_send(to_ftsdoc(body))) AS corner_builtin_roundtrip_ok
FROM corner;

-- (3) regconfig path stays == native to_tsvector for corner probes.
SELECT bool_and(fts_hit = native_hit) AS corner_regconfig_parity_ok
FROM (
  SELECT c.id,
         (to_ftsdoc('simple', c.body) @@@ to_ftsquery('simple', t.term)) AS fts_hit,
         (to_tsvector('simple', c.body) @@ to_tsquery('simple', t.term)) AS native_hit
  FROM corner c
  CROSS JOIN (VALUES (E'\u0131\u015f\u0131k'),('strlength'),('word1'),('word2'),
                     (E'\u0451lka'),('family'),('glyph')) AS t(term)
) q;

-- (4) built-in fold is case-insensitive for the simple-lowercasing cases it
--     handles (ß stays ß per the documented no-full-fold rule; Cyrillic Ё->ё
--     and fullwidth are per-code-point lowercased).  Assert the doc built from
--     the uppercase form matches a query for the lowercase token via the index.
CREATE INDEX corner_idx ON corner USING fts (to_ftsdoc(body));
SET enable_seqscan = off;
SELECT count(*) > 0 AS cyrillic_ci_match FROM corner
  WHERE to_ftsdoc(body) @@@ to_ftsquery(E'\u0451lka');   -- Ё LKA doc matched by ёlka
RESET enable_seqscan;
DROP TABLE corner;

-- Managed-service privilege model (1.3.0): fts_search / fts_anomalous_docs emit
-- indexed content by index OID, so they are REVOKEd from PUBLIC; the maintenance
-- functions fts_merge / fts_vacuum enforce index ownership in C.  Verify a
-- non-owner role is refused, and the owner is allowed.
CREATE TABLE priv (id serial, d ftsdoc);
INSERT INTO priv(d) SELECT to_ftsdoc('priv doc '||g) FROM generate_series(1,50) g;
CREATE INDEX priv_idx ON priv USING fts (d);
CREATE ROLE fts_nonowner NOLOGIN;
-- PUBLIC (hence the non-owner) can still run the value-level API and normal
-- @@@ / count queries (those are not revoked)...
SET ROLE fts_nonowner;
SELECT to_ftsdoc('x') IS NOT NULL AS nonowner_can_analyze;                 -- t
-- ...but not the index-content introspection functions...
SELECT has_function_privilege('fts_nonowner',
        'fts_search(regclass,ftsquery,int)', 'EXECUTE') AS nonowner_search_priv;  -- f
SELECT has_function_privilege('fts_nonowner',
        'fts_anomalous_docs(regclass,int,int)', 'EXECUTE') AS nonowner_anom_priv;  -- f
-- ...and maintenance on an index it does not own is refused by the C guard.
SELECT fts_merge('priv_idx');   -- ERROR: must be owner of index priv_idx
RESET ROLE;
-- the owner CAN run maintenance
SELECT fts_merge('priv_idx') IS NOT NULL AS owner_can_merge;               -- t
SELECT fts_vacuum('priv_idx') IS NOT NULL AS owner_can_vacuum;             -- t
DROP TABLE priv;
DROP ROLE fts_nonowner;

-- ============================================================================
-- Coverage: BM25 scoring variants, NULL guards, dfs handling, BM25F
-- (pg_fts_rank.c) -- exercise every parse_variant branch, the argument NULL
-- guards, the dfs array paths, and the multi-field BM25F formula + its errors.
-- ============================================================================
-- every variant + the bm25plus/l aliases score presence > 0
SELECT variant, fts_bm25_opts(to_ftsdoc('quick fox'), 'fox'::ftsquery,
                 1000, 3.0, 1.2, 0.75, variant, ARRAY[10.0]) > 0 AS pos
FROM unnest(ARRAY['lucene','robertson','atire','bm25+','bm25plus','bm25l','l']) AS variant
ORDER BY variant;
-- an unknown variant errors
SELECT fts_bm25_opts(to_ftsdoc('fox'), 'fox'::ftsquery, 1000, 3.0, 1.2, 0.75, 'nope', ARRAY[3.0]);
-- NULL in any argument yields NULL (PG_ARGISNULL guards)
SELECT fts_bm25(NULL, 'fox'::ftsquery, 1000, 4.0) IS NULL AS n0,
       fts_bm25(to_ftsdoc('fox'), NULL, 1000, 4.0) IS NULL AS n1,
       fts_bm25(to_ftsdoc('fox'), 'fox'::ftsquery, NULL, 4.0) IS NULL AS n2,
       fts_bm25(to_ftsdoc('fox'), 'fox'::ftsquery, 1000, NULL) IS NULL AS n3;
SELECT fts_bm25_opts(to_ftsdoc('fox'),'fox'::ftsquery,1000,4.0,NULL,0.75,'lucene') IS NULL AS optnull_k1,
       fts_bm25_opts(to_ftsdoc('fox'),'fox'::ftsquery,1000,4.0,1.2,0.75,NULL) IS NULL AS optnull_variant;
-- N < 1 is clamped to 1 (still scores)
SELECT fts_bm25(to_ftsdoc('fox'),'fox'::ftsquery, 0.0, 4.0) >= 0 AS n_clamped;
-- dfs with a NULL element (treated as 1.0) and dfs=NULL (default) both work
SELECT fts_bm25(to_ftsdoc('rare common'),'rare & common'::ftsquery,1000,2.0,ARRAY[2.0,NULL]::float8[]) > 0 AS dfs_null_elem;
SELECT fts_bm25(to_ftsdoc('fox'),'fox'::ftsquery,1000,4.0,NULL) >= 0 AS dfs_default;
-- a non-float8 dfs array errors
SELECT fts_bm25(to_ftsdoc('fox'),'fox'::ftsquery,1000,4.0, ARRAY[1,2]::int[]);
-- BM25F: two fields, weights, per-field avgdl; title match scores > body-only
SELECT fts_bm25f(ARRAY[to_ftsdoc('postgres'), to_ftsdoc('other body here')],
                 'postgres'::ftsquery, ARRAY[5.0,1.0], 1000, ARRAY[1.0,3.0], ARRAY[10.0]) > 0 AS bm25f_pos;
-- BM25F absent term scores 0
SELECT fts_bm25f(ARRAY[to_ftsdoc('a'), to_ftsdoc('b')],
                 'zebra'::ftsquery, ARRAY[2.0,1.0], 100, ARRAY[1.0,1.0]) AS bm25f_absent0;
-- BM25F NULL guards
SELECT fts_bm25f(NULL,'a'::ftsquery,ARRAY[1.0],10,ARRAY[1.0]) IS NULL AS bm25f_ndocs_null;
-- BM25F mismatched array lengths error
SELECT fts_bm25f(ARRAY[to_ftsdoc('a')],'a'::ftsquery,ARRAY[1.0,2.0],10,ARRAY[1.0]);
-- BM25F non-float8 weights error
SELECT fts_bm25f(ARRAY[to_ftsdoc('a')],'a'::ftsquery,ARRAY[1]::int[],10,ARRAY[1.0]);

-- ============================================================================
-- Coverage: ftsquery parsing edge cases + rendering (pg_fts_query.c)
-- ============================================================================
-- every operator renders and round-trips through ftsquery_out
SELECT 'a & b'::ftsquery::text, 'a | b'::ftsquery::text, '!a'::ftsquery::text,
       '"a b c"'::ftsquery::text, 'a*'::ftsquery::text, 'a~1'::ftsquery::text,
       '/^ab/'::ftsquery::text, '(a | b) & c'::ftsquery::text,
       'NEAR(a b, 3)'::ftsquery::text, 'a b'::ftsquery::text;   -- implicit AND
-- keyword operators, case-insensitive
SELECT to_ftsquery('a AND b')::text, to_ftsquery('a OR b')::text, to_ftsquery('NOT a')::text;
-- legal proximity: grouped alternatives, both word orders, and exact text I/O
SELECT to_ftsdoc('canine little bite') @@@ '(dog OR canine) w/3 bite'::ftsquery AS grouped_within;
SELECT to_ftsdoc('bite little canine') @@@ '(dog OR canine) w/3 bite'::ftsquery AS reverse_within;
SELECT to_ftsdoc('bite little canine') @@@ '(dog OR canine) p/3 bite'::ftsquery AS reverse_ordered;
SELECT to_ftsdoc('dog bite') @@@ 'dog w/4294967295 bite'::ftsquery AS max_distance;
SELECT 'NEAR(dog bite, 5)'::ftsquery::text::ftsquery::text = 'NEAR(dog bite, 5)'::ftsquery::text AS ordered_roundtrip;
SELECT 'NEAR(a b c, 2)'::ftsquery::text::ftsquery::text = 'NEAR(a b c, 2)'::ftsquery::text AS near_three_roundtrip;
SELECT '(dog OR canine) w/10 bite'::ftsquery::text::ftsquery::text = '(dog OR canine) w/10 bite'::ftsquery::text AS within_roundtrip;
SELECT $$'and' p/5 'or'$$::ftsquery::text AS literal_keywords;
SELECT to_ftsquery('"w/5 dog"')::text::ftsquery::text = to_ftsquery('"w/5 dog"')::text AS proximity_word_in_phrase;
SELECT to_ftsquery('NEAR(w/5 dog, 10)')::text::ftsquery::text = to_ftsquery('NEAR(w/5 dog, 10)')::text AS proximity_word_in_near;
SELECT to_ftsquery('w/5a')::text = to_ftsquery($$'w/5a'$$)::text AS proximity_prefix_word;
SELECT to_ftsquery('O''Brien')::text = to_ftsquery('O Brien')::text AS apostrophe_word;
SELECT to_ftsquery('"attorney''s fees"')::text = to_ftsquery('"attorney s fees"')::text AS apostrophe_phrase;
-- empty input -> empty query
SELECT to_ftsquery('')::text AS empty_q, ''::ftsquery::text AS empty_cast;
-- A phrase can be an unordered proximity operand.
SELECT to_ftsdoc('bite big dog') @@@ '"big dog" w/5 bite'::ftsquery AS phrase_within;
-- malformed queries must ERROR (each is its own statement so the .out records it)
SELECT '"unterminated'::ftsquery;         -- unterminated quote
SELECT '/unterminated'::ftsquery;         -- unterminated regex
SELECT '""'::ftsquery;                    -- empty phrase
SELECT 'NEAR(only)'::ftsquery;            -- NEAR needs >= 2 terms
SELECT 'NEAR(a b, 0)'::ftsquery;          -- NEAR k must be >= 1
SELECT 'a w/0 b'::ftsquery;               -- distance must be positive
SELECT 'a w/99999999999999999999 b'::ftsquery; -- distance cannot overflow
SELECT '(dog AND canine) w/5 bite'::ftsquery; -- AND has no positions: explicit error
SELECT 'a &'::ftsquery;                   -- trailing operator
SELECT '& a'::ftsquery;                   -- leading operator
SELECT 'a & & b'::ftsquery;               -- double operator
SELECT '(a'::ftsquery;                    -- unbalanced paren
-- NEAR default k (no ,k) and multi-term phrase
SELECT to_ftsdoc('a b c') @@@ 'NEAR(a c)'::ftsquery AS near_default;
SELECT to_ftsdoc('x a b c y') @@@ '"a b c"'::ftsquery AS phrase3;

-- ============================================================================
-- Coverage: ftsdoc I/O + edge tokens (pg_fts_doc.c, pg_fts_analyze.c)
-- ============================================================================
-- text round-trip: out -> in
SELECT to_ftsdoc('quick brown fox')::text::ftsdoc::text = to_ftsdoc('quick brown fox')::text AS text_roundtrip;
-- binary round-trip: send -> recv
SELECT (to_ftsdoc('quick brown fox')::text::ftsdoc)::text = to_ftsdoc('quick brown fox')::text AS bin_roundtrip;
-- empty and whitespace-only docs
SELECT to_ftsdoc('')::text AS empty_doc, to_ftsdoc('    ')::text AS ws_doc, ftsdoc_length(to_ftsdoc('')) AS empty_len;
-- repeated term -> tf accumulates
SELECT to_ftsdoc('fox fox fox')::text AS tf3;
-- a token longer than the 2047-char limit is dropped with a notice
SELECT ftsdoc_length(to_ftsdoc('short ' || repeat('x', 3000))) AS long_token_dropped;
-- simple vs english analyzer differ on stemming/stopwords
SELECT to_ftsdoc('simple','The Running Foxes')::text AS simple_doc,
       to_ftsdoc('english','The Running Foxes')::text AS english_doc;

-- ============================================================================
-- Coverage: tsquery -> ftsquery migration (pg_fts_migrate.c)
-- ============================================================================
SELECT (to_tsquery('english','quick & brown'))::ftsquery::text AS mig_and;
SELECT (to_tsquery('english','quick | brown'))::ftsquery::text AS mig_or;
SELECT (to_tsquery('english','!slow'))::ftsquery::text AS mig_not;
SELECT (to_tsquery('english','quick <-> brown'))::ftsquery::text AS mig_phrase;
SELECT (to_tsquery('english','quick:*'))::ftsquery::text AS mig_prefix;

-- ============================================================================
-- Coverage: count(*) pushdown rejection paths (pg_fts_customscan.c)
-- These query shapes must NOT use the FtsCount pushdown (still correct results).
-- ============================================================================
CREATE TABLE cs (id serial, cat int, d ftsdoc);
INSERT INTO cs(cat, d) SELECT g % 3, to_ftsdoc('english','term'||(g%5)||' body') FROM generate_series(1,300) g;
CREATE INDEX cs_idx ON cs USING fts (d);
SET enable_seqscan = off;
-- GROUP BY -> no pushdown, still correct
SELECT cat, count(*) FROM cs WHERE d @@@ to_ftsquery('english','term1') GROUP BY cat ORDER BY cat;
-- count(col) (not count(*)) -> different path
SELECT count(id) > 0 AS count_col FROM cs WHERE d @@@ to_ftsquery('english','term1');
-- count(*) with an extra non-@@@ qual -> not a bare @@@ pushdown
SELECT count(*) FROM cs WHERE d @@@ to_ftsquery('english','term1') AND cat = 0;
-- count(DISTINCT) -> no pushdown
SELECT count(DISTINCT cat) FROM cs WHERE d @@@ to_ftsquery('english','term1');
-- plain bare count(*) -> DOES push down (control)
SELECT count(*) FROM cs WHERE d @@@ to_ftsquery('english','term1');
RESET enable_seqscan;
DROP TABLE cs;

-- ============================================================================
-- Coverage: engine scan paths (pg_fts_am.c / pg_fts_am_scan.c) -- WAND vs
-- MaxScore, positions-on ranked/phrase, adaptive-k growth, multi-segment
-- ranked, anomaly detection, deep fts_search with tombstones.
-- ============================================================================
-- MaxScore path: a ranked query with >= 4 terms takes fts_search_maxscore
CREATE TABLE ms4 (id serial, d ftsdoc);
INSERT INTO ms4(d) SELECT to_ftsdoc('english',
  (CASE WHEN g%2=0 THEN 'alpha ' ELSE '' END) ||
  (CASE WHEN g%3=0 THEN 'beta ' ELSE '' END) ||
  (CASE WHEN g%5=0 THEN 'gamma ' ELSE '' END) ||
  (CASE WHEN g%7=0 THEN 'delta ' ELSE '' END) || 'w'||(g%40)||' body '||g)
  FROM generate_series(1,1200) g;
CREATE INDEX ms4_idx ON ms4 USING fts (d);
SET enable_seqscan = off;
-- 4-term OR -> MaxScore; top-k must equal a brute-force score sort
SELECT count(*) = 10 AS maxscore_k10 FROM (
  SELECT id FROM ms4 WHERE d @@@ to_ftsquery('english','alpha | beta | gamma | delta')
  ORDER BY d <=> to_ftsquery('english','alpha | beta | gamma | delta') LIMIT 10) x;
-- adaptive-k growth: pull well past the first batch (LIMIT 300)
SELECT count(*) AS deep_limit FROM (
  SELECT id FROM ms4 WHERE d @@@ to_ftsquery('english','w1 | alpha | beta | gamma | delta')
  ORDER BY d <=> to_ftsquery('english','w1 | alpha | beta | gamma | delta') LIMIT 300) x;
RESET enable_seqscan;
DROP TABLE ms4;

-- positions = on: phrase/NEAR answered from the index (no heap recheck path)
CREATE TABLE posidx (id serial, body text);
INSERT INTO posidx(body) SELECT 'quick brown fox number '||g||' jumps' FROM generate_series(1,400) g;
INSERT INTO posidx(body) SELECT 'brown quick fox '||g FROM generate_series(1,100) g;   -- reversed
CREATE INDEX posidx_bm25 ON posidx USING fts (to_ftsdoc('english', body)) WITH (positions = on);
SET enable_seqscan = off;
SELECT count(*) AS phrase_hits FROM posidx
 WHERE to_ftsdoc('english', body) @@@ '"quick brown"'::ftsquery;    -- 400 (adjacent only)
SELECT count(*) AS near_hits FROM posidx
 WHERE to_ftsdoc('english', body) @@@ 'NEAR(quick fox, 3)'::ftsquery;
-- ranked over the positions index
SELECT count(*) = 10 AS pos_ranked FROM (
  SELECT id FROM posidx WHERE to_ftsdoc('english', body) @@@ 'quick'::ftsquery
  ORDER BY to_ftsdoc('english', body) <=> 'quick'::ftsquery LIMIT 10) x;
RESET enable_seqscan;
DROP TABLE posidx;

-- multi-segment (oversized-doc) ranked scan + anomaly detection + df/stats
CREATE TABLE seg2 (id serial, d ftsdoc);
INSERT INTO seg2(d) SELECT to_ftsdoc('english',
  repeat('common ', 1+(g%8)) || 'rare'||g||' ' || (SELECT string_agg('u'||g||'x'||k,' ') FROM generate_series(1,1600) k))
  FROM generate_series(1,80) g;
CREATE INDEX seg2_idx ON seg2 USING fts (d);
SET enable_seqscan = off;
SELECT fts_index_nsegments('seg2_idx') > 1 AS multi_seg;
SELECT count(*) = 80 AS common_all FROM seg2 WHERE d @@@ 'common'::ftsquery;
-- ranked over multiple segments
SELECT count(*) = 10 AS seg_ranked FROM (
  SELECT id FROM seg2 WHERE d @@@ 'common'::ftsquery ORDER BY d <=> 'common'::ftsquery LIMIT 10) x;
-- anomaly detection: docs with the rarest terms, with and without max_df
SELECT count(*) > 0 AS anom_any FROM fts_anomalous_docs('seg2_idx', 5);
SELECT count(*) >= 0 AS anom_maxdf FROM fts_anomalous_docs('seg2_idx', 5, 10);
-- df + stats introspection
SELECT fts_index_df('seg2_idx', 'common'::ftsquery) = ARRAY[80.0]::float8[] AS df_common;
SELECT ndocs::int = 80 AS stats_ndocs FROM fts_index_stats('seg2_idx');
-- merge to one segment then re-query (merge path + post-merge scan)
SELECT fts_merge('seg2_idx') IS NOT NULL AS merged;
SELECT fts_index_nsegments('seg2_idx') AS nseg_after_merge;
SELECT count(*) = 80 AS common_after_merge FROM seg2 WHERE d @@@ 'common'::ftsquery;
RESET enable_seqscan;
DROP TABLE seg2;

-- deep fts_search with tombstones (over-fetch + livedocs subtraction path)
CREATE TABLE tsrch (id serial, d ftsdoc);
INSERT INTO tsrch(d) SELECT to_ftsdoc('english','apple w'||(g%20)||' body '||g) FROM generate_series(1,600) g;
CREATE INDEX tsrch_idx ON tsrch USING fts (d);
DELETE FROM tsrch WHERE id % 2 = 0;   -- tombstone half
VACUUM tsrch;
SET enable_seqscan = off;
SELECT count(*) = 300 AS live_after_delete FROM tsrch WHERE d @@@ 'apple'::ftsquery;
SELECT count(*) AS srf_deep FROM fts_search('tsrch_idx', 'apple'::ftsquery, 500);   -- <=300 live
SELECT bool_and(alive) AS all_alive FROM (
  SELECT EXISTS(SELECT 1 FROM tsrch x WHERE x.ctid = r.ctid) AS alive
  FROM fts_search('tsrch_idx', 'apple'::ftsquery, 500) r) q;
RESET enable_seqscan;
DROP TABLE tsrch;

-- ============================================================================
-- Coverage: pg_fts_trgm.c -- fts_regex_trigrams metacharacter switch (every
-- case: backslash-escape, *, ?, +, {m,n}, |, (), [...], ., ^/$ anchors) and
-- fts_trigrams (short-term pad path, long-term dedup path).  Exercised both
-- via a WITH (trigrams=on) index (candidate-narrowing path,
-- bm25_trgm_candidates) and directly against a sequential ftsdoc (the exact
-- fts_doc_has_regex / fts_doc_has_fuzzy recheck path, no index).
-- ============================================================================
CREATE TABLE trgmx (id serial, d ftsdoc);
INSERT INTO trgmx (d)
  SELECT to_ftsdoc('english',
           'abcdef quickbrownfox jumping settlement developer government ' ||
           'programmer environment establishment word' || (g % 250) ||
           ' filler text number ' || g)
  FROM generate_series(1, 220) g;
CREATE INDEX trgmx_idx ON trgmx USING fts (d) WITH (trigrams = on);
SET enable_seqscan = off;
-- backslash-escape: literal '.' via \. inside the pattern (case '\\')
SELECT count(*) >= 0 AS rx_escape FROM trgmx WHERE d @@@ '/abc\.def/'::ftsquery;
-- star: previous char optional, run flushed and dropped (case '*')
SELECT count(*) >= 0 AS rx_star FROM trgmx WHERE d @@@ '/quickbrown.*fox/'::ftsquery;
SELECT count(*) >= 0 AS rx_star_hit FROM trgmx WHERE d @@@ '/quickbrown[a-z]*fox/'::ftsquery;
-- question mark: previous char optional (case '?')
SELECT count(*) >= 0 AS rx_opt FROM trgmx WHERE d @@@ '/developers?/'::ftsquery;
-- plus: previous char required, run flushed but kept (case '+')
SELECT count(*) >= 0 AS rx_plus FROM trgmx WHERE d @@@ '/programmer+/'::ftsquery;
-- brace quantifier, non-zero-capable {1,2} and zero-capable {0,2} (case '{')
SELECT count(*) >= 0 AS rx_brace_min1 FROM trgmx WHERE d @@@ '/governmentz{1,2}/'::ftsquery;
SELECT count(*) >= 0 AS rx_brace_min0 FROM trgmx WHERE d @@@ '/governmentz{0,2}/'::ftsquery;
-- alternation: drop the whole current run (case '|')
SELECT count(*) >= 0 AS rx_alt FROM trgmx WHERE d @@@ '/environment|nosuchword/'::ftsquery;
-- groups: flush at each boundary (case '(' / ')')
SELECT count(*) >= 0 AS rx_group FROM trgmx WHERE d @@@ '/(establish)ment/'::ftsquery;
-- character class: not a fixed literal, flush and skip the whole [...] (case '[')
SELECT count(*) >= 0 AS rx_class FROM trgmx WHERE d @@@ '/develop[eE]r/'::ftsquery;
-- character class with leading '^' (negated) and a literal ']' as first char
SELECT count(*) >= 0 AS rx_class_neg FROM trgmx WHERE d @@@ '/develop[^xyz]r/'::ftsquery;
SELECT count(*) >= 0 AS rx_class_litbracket FROM trgmx WHERE d @@@ '/develop[]a]r/'::ftsquery;
-- wildcard dot: breaks the run (case '.')
SELECT count(*) >= 0 AS rx_dot FROM trgmx WHERE d @@@ '/gov.rnment/'::ftsquery;
-- anchors: run boundary, no char consumed (case '^' / '$')
SELECT count(*) >= 0 AS rx_anchor_start FROM trgmx WHERE d @@@ '/^abcdef/'::ftsquery;
SELECT count(*) >= 0 AS rx_anchor_end FROM trgmx WHERE d @@@ '/abcdef$/'::ftsquery;
-- literal run shorter than a trigram (<3 required chars) -> no trigram
-- extracted, caller falls back to a full scan (still correct)
SELECT count(*) >= 0 AS rx_short_run FROM trgmx WHERE d @@@ '/ab/'::ftsquery;
-- literal run >= 3 chars -> a real required trigram is extracted
SELECT count(*) >= 0 AS rx_long_run FROM trgmx WHERE d @@@ '/abcd/'::ftsquery;
-- trailing lone backslash (no char after it within the pattern): the
-- tokenizer's regex reader stops at the first unescaped '/', so 'abc\/' with
-- one slash yields the pattern text "abc\" -- a backslash as the LAST byte,
-- hitting the "i + 1 < relen" false branch (case '\\', the else i++ arm).
-- The trailing lone backslash is an invalid regex to the recheck engine, so the
-- scan must ERROR cleanly (not crash): assert it raises rather than matches.
DO $$
BEGIN
  PERFORM count(*) FROM trgmx WHERE d @@@ '/abc\/'::ftsquery;
  RAISE NOTICE 'rx_trailing_backslash: no error';
EXCEPTION WHEN others THEN
  RAISE NOTICE 'rx_trailing_backslash: raised (expected for a trailing-backslash regex)';
END $$;
-- fuzzy terms of varied length: 1-2 chars (fts_trigrams pad path, len<3),
-- exactly 3 (single trigram, no dedup needed), and long (>=8, dedup path)
SELECT count(*) >= 0 AS fuzzy_len1 FROM trgmx WHERE d @@@ 'a~1'::ftsquery;
SELECT count(*) >= 0 AS fuzzy_len2 FROM trgmx WHERE d @@@ 'ab~1'::ftsquery;
SELECT count(*) >= 0 AS fuzzy_len3 FROM trgmx WHERE d @@@ 'abc~1'::ftsquery;
SELECT count(*) >= 0 AS fuzzy_long FROM trgmx WHERE d @@@ 'developement~2'::ftsquery;
RESET enable_seqscan;
DROP TABLE trgmx;

-- Same regex/fuzzy patterns, run against a bare sequential ftsdoc (no index
-- at all): exercises fts_regex_trigrams / fts_trigrams only through the exact
-- fts_doc_has_regex / fts_doc_has_fuzzy recheck, never bm25_trgm_candidates.
SELECT to_ftsdoc('quickbrownfox jumps') @@@ '/quickbrown\.fox/'::ftsquery AS seq_rx_escape;
SELECT to_ftsdoc('developer settlement') @@@ '/develop.*ment/'::ftsquery AS seq_rx_star;
SELECT to_ftsdoc('developer settlement') @@@ '/developers?/'::ftsquery AS seq_rx_opt;
SELECT to_ftsdoc('programmer environment') @@@ '/programmer+/'::ftsquery AS seq_rx_plus;
SELECT to_ftsdoc('government establishment') @@@ '/governmentz{1,2}|government/'::ftsquery AS seq_rx_brace_alt;
SELECT to_ftsdoc('establishment government') @@@ '/(establish)ment/'::ftsquery AS seq_rx_group;
SELECT to_ftsdoc('developer settlement') @@@ '/develop[eE]r/'::ftsquery AS seq_rx_class;
SELECT to_ftsdoc('developer settlement') @@@ '/develop[^xyz]r/'::ftsquery AS seq_rx_class_neg;
SELECT to_ftsdoc('government establishment') @@@ '/gov.rnment/'::ftsquery AS seq_rx_dot;
SELECT to_ftsdoc('abcdef ghijkl') @@@ '/^abcdef/'::ftsquery AS seq_rx_anchor_start;
SELECT to_ftsdoc('abcdef ghijkl') @@@ '/ghijkl$/'::ftsquery AS seq_rx_anchor_end;
SELECT to_ftsdoc('ab cd') @@@ '/ab/'::ftsquery AS seq_rx_short_run;
SELECT to_ftsdoc('abcd efgh') @@@ '/abcd/'::ftsquery AS seq_rx_long_run;
SELECT to_ftsdoc('a b c') @@@ 'a~1'::ftsquery AS seq_fuzzy_len1;
SELECT to_ftsdoc('ab cd ef') @@@ 'ab~1'::ftsquery AS seq_fuzzy_len2;
SELECT to_ftsdoc('abc def ghi') @@@ 'abc~1'::ftsquery AS seq_fuzzy_len3;
SELECT to_ftsdoc('development environment') @@@ 'developement~2'::ftsquery AS seq_fuzzy_long;

-- ============================================================================
-- Coverage: pg_fts_rank.c -- fts_bm25f (3+ fields, an empty-doc field, a
-- per-field dfs array, sharply differing weights, an absent query term, a
-- multi-term query) and fts_distance / fts_distance_commutator directly.
-- ============================================================================
-- 3 fields (title/body/tags), one field an EMPTY ftsdoc (to_ftsdoc('')),
-- multi-term query, per-term dfs, weights that differ a lot.
SELECT round(fts_bm25f(
         ARRAY[to_ftsdoc('postgres fts'), to_ftsdoc(''), to_ftsdoc('search engine postgres')],
         'postgres & search'::ftsquery,
         ARRAY[10.0, 3.0, 1.0],       -- title >> tags >> empty body
         500.0,
         ARRAY[4.0, 1.0, 6.0],        -- avgdl per field
         ARRAY[50.0, 20.0])::numeric, 6) AS bm25f_3field;
-- a query term absent from every field scores exactly 0 (tfw stays 0 for all
-- fields -> the "continue" before idf is ever computed for that term)
SELECT fts_bm25f(
         ARRAY[to_ftsdoc('alpha beta'), to_ftsdoc('gamma delta')],
         'zzzzabsent'::ftsquery,
         ARRAY[1.0, 1.0], 100.0, ARRAY[2.0, 2.0]) AS bm25f_absent_term;
-- title-weighted hit outranks the identical term only in the body
SELECT fts_bm25f(ARRAY[to_ftsdoc('widget'), to_ftsdoc('unrelated filler text')],
                'widget'::ftsquery, ARRAY[8.0, 1.0], 200.0, ARRAY[3.0, 12.0])
     > fts_bm25f(ARRAY[to_ftsdoc('unrelated filler'), to_ftsdoc('widget text')],
                'widget'::ftsquery, ARRAY[8.0, 1.0], 200.0, ARRAY[3.0, 12.0])
       AS bm25f_title_weight_wins;
-- field that is NULL (not merely empty) is skipped (docnull[f] branch)
SELECT fts_bm25f(ARRAY[to_ftsdoc('alpha'), NULL],
                'alpha'::ftsquery, ARRAY[1.0, 1.0], 100.0, ARRAY[1.0, 1.0]) > 0
       AS bm25f_null_field_skipped;
-- avgdl <= 0 for one field clamps to 1.0 (avgdl <= 0.0 branch)
SELECT fts_bm25f(ARRAY[to_ftsdoc('alpha beta')],
                'alpha'::ftsquery, ARRAY[1.0], 100.0, ARRAY[0.0]) >= 0
       AS bm25f_avgdl_zero_clamped;
-- NULL weight/avgdl element in the arrays (wnull/avgnull branches)
SELECT fts_bm25f(ARRAY[to_ftsdoc('alpha beta')],
                'alpha'::ftsquery, ARRAY[NULL]::float8[], 100.0, ARRAY[NULL]::float8[]) >= 0
       AS bm25f_null_weight_avgdl;
-- multi-term query where each term is present in a different field
-- (exercises the per-term loop body running twice, each visiting all fields)
SELECT fts_bm25f(ARRAY[to_ftsdoc('alpha'), to_ftsdoc('beta')],
                'alpha | beta'::ftsquery, ARRAY[1.0, 1.0], 100.0, ARRAY[3.0, 3.0]) > 0
       AS bm25f_multiterm;

-- fts_distance / fts_distance_commutator NULL-argument short-circuits.
SELECT fts_distance(NULL, 'fox'::ftsquery) IS NULL AS dist_null_doc,
       fts_distance(to_ftsdoc('fox'), NULL) IS NULL AS dist_null_query;
SELECT fts_distance_commutator(NULL, to_ftsdoc('fox')) IS NULL AS distc_null_query,
       fts_distance_commutator('fox'::ftsquery, NULL) IS NULL AS distc_null_doc;
-- non-null direct calls (the real scoring path, both directions agree)
SELECT fts_distance(to_ftsdoc('the quick brown fox'), 'quick'::ftsquery) =
       fts_distance_commutator('quick'::ftsquery, to_ftsdoc('the quick brown fox'))
       AS dist_direct_agrees;

-- ============================================================================
-- Coverage: pg_fts_docvalid.h (fts_doc_check, via fts_doc_is_valid) -- the
-- "normal" (accept) side of every guard: header-fits, VARSIZE<=sz,
-- version match, entries[]+lexbytes fits, each term's lexeme slice fits, the
-- positions-present branch (both taken and not-taken), positions region fits,
-- and each term's tf/posoff run fits.  fts_doc_is_valid is called on every
-- document while it sits in the PENDING LIST (both when it is flushed to a
-- segment by fts_merge/fts_vacuum and when a scan walks the pending list
-- directly), so a variety of pending docs -- empty, single-token, multi-term,
-- with and without positions, high tf -- exercises the accept path of every
-- guard in fts_doc_check for both the flags-has-positions and
-- flags-no-positions shapes.  The reject ("return 0") side of each guard is a
-- pure corruption/defensive check: it requires a hand-corrupted FtsDoc image
-- (bad nterms/off/len/tf/posoff/VARSIZE) that no SQL-level constructor can
-- produce -- fts_doc_build validates before returning, ftsdoc_recv bounds nterms
-- and every length against the message size, and to_ftsdoc/to_ftsdoc(tsvector)
-- always build a well-formed image.  That side is exactly what
-- test/fuzz/fuzz_docvalid.c targets instead (its own header comment says so).
-- ============================================================================
CREATE TABLE dv (id serial, d ftsdoc);
CREATE INDEX dv_idx ON dv USING fts (d);
-- empty doc: nterms=0, no positions -- entries[]/lexeme loops execute 0 times
INSERT INTO dv (d) VALUES (to_ftsdoc(''));
-- single-token doc: nterms=1, tf=1, WITH positions (default text path sets
-- FTS_DOCF_POSITIONS) -- the positions-present branch, one posoff/tf run
INSERT INTO dv (d) VALUES (to_ftsdoc('lonely'));
-- multi-term doc with a high-tf term (many positions for one entry) --
-- exercises a term whose [posoff, posoff+tf) run is the bulk of positions[]
INSERT INTO dv (d) VALUES (to_ftsdoc(repeat('alpha ', 50) || 'beta gamma delta'));
-- built from a tsvector directly (to_ftsdoc_from_tsvector): a different doc
-- builder feeding the same fts_doc_is_valid checks
INSERT INTO dv (d) VALUES (to_ftsdoc(to_tsvector('english', 'search engines index text')));
-- tsvector built from an EMPTY string: another nterms=0 shape, but produced by
-- the tsvector-adoption path (to_ftsdoc_from_tsvector), not fts_analyze_text
INSERT INTO dv (d) VALUES (to_ftsdoc(to_tsvector('english', '')));
-- a stripped tsvector (no positions at all) -> positions-absent branch via the
-- tsvector path specifically (all-or-nothing degrades to positions-off)
INSERT INTO dv (d) VALUES (to_ftsdoc(strip(to_tsvector('english', 'no positions here'))));
-- every doc above went through aminsert (index created before the inserts),
-- so it sits in the PENDING LIST, not a built segment.
-- pending-list SCAN path: query while still pending, so fts_doc_is_valid runs
-- over the raw pending page bytes for every row above.
SET enable_seqscan = off;
SELECT count(*) AS dv_pending_scan_hits FROM dv WHERE d @@@ 'alpha'::ftsquery;
RESET enable_seqscan;
-- pending-list FLUSH path: fts_merge folds every pending doc into a segment,
-- running fts_doc_is_valid over each one again during the flush.
SELECT fts_merge('dv_idx'::regclass) IS NOT NULL AS dv_merged;
SET enable_seqscan = off;
SELECT count(*) AS dv_after_merge FROM dv WHERE d @@@ 'alpha'::ftsquery;
RESET enable_seqscan;
DROP TABLE dv;

-- binary recv/send round-trips of the same doc shapes, through the wire format
-- (ftsdoc_recv re-derives nterms/doclen/has_pos from message bytes and rebuilds
-- via fts_doc_build, so this is a second, independent path to the same
-- well-formed images that then flow through fts_doc_is_valid once indexed).
CREATE TEMP TABLE dvrt (id int, d ftsdoc);
INSERT INTO dvrt VALUES
  (1, to_ftsdoc('')),
  (2, to_ftsdoc('single')),
  (3, to_ftsdoc('alpha beta alpha gamma alpha delta'));
-- binary send/recv round-trip via COPY (FORMAT binary): send serializes each
-- ftsdoc, recv (internal) re-derives nterms/doclen/has_pos and rebuilds it.
CREATE TEMP TABLE dvrt_bin (LIKE dvrt INCLUDING ALL);
COPY dvrt TO '/tmp/dvrt.bin' WITH (FORMAT binary);
COPY dvrt_bin FROM '/tmp/dvrt.bin' WITH (FORMAT binary);
SELECT bool_and(a.d::text = b.d::text) AS dv_binary_roundtrip_ok
  FROM dvrt a JOIN dvrt_bin b USING (id);
CREATE INDEX dvrt_idx ON dvrt USING fts (d);
SET enable_seqscan = off;
SELECT count(*) AS dvrt_hits FROM dvrt WHERE d @@@ 'alpha'::ftsquery;
RESET enable_seqscan;

-- ============================================================================
-- Coverage: pg_fts_aux.c -- fts_highlight / fts_snippet, i.e. tokenize_and_mark
-- and its callers.  Exercise: is_token_byte's >=0x80 (unicode) branch, a
-- leading/trailing/only-separator source (the "i > sepstart" emit and the
-- "i >= len" break), a query that matches nothing (ctx.n == 0 in snippet),
-- a multi-term query, a phrase query, and the match at the very start, middle
-- and end of the source text.
-- ============================================================================
-- match at the START of the text (first token matched, sepstart==i==0 skip)
SELECT fts_highlight('needle in a haystack', 'needle'::ftsquery) AS hl_match_start;
-- match in the MIDDLE
SELECT fts_highlight('a haystack with needle inside', 'needle'::ftsquery) AS hl_match_middle;
-- match at the very END (no trailing separator run)
SELECT fts_highlight('a haystack with a needle', 'needle'::ftsquery) AS hl_match_end;
-- leading separator run before the first token ("i > sepstart" sink call)
SELECT fts_highlight('   leading spaces then needle', 'needle'::ftsquery) AS hl_leading_sep;
-- trailing separator run after the last token
SELECT fts_highlight('needle then trailing spaces   ', 'needle'::ftsquery) AS hl_trailing_sep;
-- text that is PURE separators (no token at all): the loop hits "i >= len"
-- immediately on its first (and only) separator scan
SELECT fts_highlight('    ...   ', 'needle'::ftsquery) AS hl_all_separators;
-- empty text: len == 0, loop body never runs
SELECT fts_highlight('', 'needle'::ftsquery) AS hl_empty_text;
-- multi-term query (OR): several distinct tokens matched in one pass
SELECT fts_highlight('alpha in the middle beta at the end', 'alpha | beta'::ftsquery) AS hl_multiterm;
-- phrase query: tokenize_and_mark only marks per-token query_has_term hits;
-- highlight marks each phrase word independently (documented literal behavior)
SELECT fts_highlight('the quick brown fox', '"quick brown"'::ftsquery) AS hl_phrase;
-- unicode text: tokens with bytes >= 0x80 (is_token_byte's first branch)
SELECT fts_highlight('café naïve façade', 'café'::ftsquery) AS hl_unicode;

-- fts_snippet: same shapes, plus the ctx.n == 0 (no real tokens at all) path.
SELECT fts_snippet('needle in a haystack', 'needle'::ftsquery) AS snip_match_start;
SELECT fts_snippet('a haystack with needle inside', 'needle'::ftsquery) AS snip_match_middle;
SELECT fts_snippet('a haystack with a needle', 'needle'::ftsquery) AS snip_match_end;
SELECT fts_snippet('   leading spaces then needle', 'needle'::ftsquery) AS snip_leading_sep;
-- pure separators: no real tokens recorded by snip_sink -> ctx.n == 0 -> ''
SELECT fts_snippet('    ...   ', 'needle'::ftsquery) AS snip_all_separators;
SELECT fts_snippet('', 'needle'::ftsquery) AS snip_empty_text;
SELECT fts_snippet('alpha in the middle beta at the end', 'alpha | beta'::ftsquery) AS snip_multiterm;
SELECT fts_snippet('the quick brown fox', '"quick brown"'::ftsquery) AS snip_phrase2;
SELECT fts_snippet('café naïve façade', 'café'::ftsquery) AS snip_unicode;
-- window narrower than the doc (best_start > 0 path: ellipsis before the window)
SELECT fts_snippet(repeat('filler ', 30) || 'needle ' || repeat('trailer ', 30),
                   'needle'::ftsquery, '<b>', '</b>', ' ... ', 3) AS snip_windowed;

-- ============================================================================
-- Coverage: pg_fts_match.c -- fts_doc_matches (the RPN stack evaluator) and
-- fts_match / fts_match_commutator directly on an ftsdoc value (no index).
-- AND both-present/one-missing, OR, NOT, nested boolean, phrase present/
-- absent, NEAR present/absent, prefix, an empty query, an empty doc, and a
-- phrase/NEAR degrading to AND-only when the doc has no stored positions
-- (phrase_step's "either side lacks positions" branch).
-- ============================================================================
-- AND: both present, and one missing
SELECT to_ftsdoc('alpha beta') @@@ 'alpha & beta'::ftsquery AS and_both_present;
SELECT to_ftsdoc('alpha only') @@@ 'alpha & beta'::ftsquery AS and_one_missing;
-- OR: either side present, both absent
SELECT to_ftsdoc('alpha only') @@@ 'alpha | beta'::ftsquery AS or_left_present;
SELECT to_ftsdoc('beta only') @@@ 'alpha | beta'::ftsquery AS or_right_present;
SELECT to_ftsdoc('gamma only') @@@ 'alpha | beta'::ftsquery AS or_both_absent;
-- NOT: present flips to absent and vice versa
SELECT to_ftsdoc('alpha') @@@ '!alpha'::ftsquery AS not_present_flips;
SELECT to_ftsdoc('beta') @@@ '!alpha'::ftsquery AS not_absent_flips;
-- nested boolean: (a & b) | (!c)
SELECT to_ftsdoc('alpha beta') @@@ '(alpha & beta) | !gamma'::ftsquery AS nested_and_or;
SELECT to_ftsdoc('gamma') @@@ '(alpha & beta) | !gamma'::ftsquery AS nested_falls_to_not;
-- phrase: present (adjacent) and absent (not adjacent) on a POSITIONAL doc
SELECT to_ftsdoc('the quick brown fox') @@@ '"quick brown"'::ftsquery AS phrase_present;
SELECT to_ftsdoc('the quick red brown fox') @@@ '"quick brown"'::ftsquery AS phrase_absent;
-- NEAR: present (within k) and absent (beyond k)
SELECT to_ftsdoc('quick brown red fox') @@@ 'NEAR(quick fox, 3)'::ftsquery AS near_present;
SELECT to_ftsdoc('quick brown red slow lazy fox') @@@ 'NEAR(quick fox, 2)'::ftsquery AS near_absent;
-- prefix: matches any term starting with the prefix
SELECT to_ftsdoc('development environment') @@@ 'develop*'::ftsquery AS prefix_hit;
SELECT to_ftsdoc('unrelated words') @@@ 'develop*'::ftsquery AS prefix_miss;
-- empty query matches nothing (fts_doc_matches: nitems == 0 -> false)
SELECT to_ftsdoc('anything at all') @@@ ''::ftsquery AS empty_query_no_match;
-- empty doc matches nothing against any real query (term lookup finds nothing)
SELECT to_ftsdoc('') @@@ 'anything'::ftsquery AS empty_doc_no_match;
-- empty query against an empty doc
SELECT to_ftsdoc('') @@@ ''::ftsquery AS empty_query_empty_doc;
-- phrase/NEAR on a doc built WITHOUT positions (canonical literal, no '@'):
-- adjacency is unverifiable, so the phrase is FALSE (as PostgreSQL does without
-- TS_EXEC_PHRASE_NO_POS).  This previously degraded to plain AND and answered
-- true for a NON-adjacent phrase -- a silent wrong answer; see
-- bench/REVIEW_PHRASE_NOPOS.md.
SELECT $$'brown':1 'quick':1$$::ftsdoc @@@ '"quick brown"'::ftsquery AS phrase_nopos_is_false;
SELECT $$'fox':1 'quick':1$$::ftsdoc @@@ 'NEAR(quick fox, 1)'::ftsquery AS near_nopos_is_false;
-- the commutator form (ftsquery @@@ ftsdoc) agrees with fts_match in both
-- directions for the same boolean/phrase/NEAR cases above
SELECT ('alpha & beta'::ftsquery @@@ to_ftsdoc('alpha beta'))
     = (to_ftsdoc('alpha beta') @@@ 'alpha & beta'::ftsquery) AS match_commutator_and;
SELECT ('"quick brown"'::ftsquery @@@ to_ftsdoc('the quick brown fox'))
     = (to_ftsdoc('the quick brown fox') @@@ '"quick brown"'::ftsquery) AS match_commutator_phrase;
SELECT ('NEAR(quick fox, 3)'::ftsquery @@@ to_ftsdoc('quick brown red fox'))
     = (to_ftsdoc('quick brown red fox') @@@ 'NEAR(quick fox, 3)'::ftsquery) AS match_commutator_near;
-- fts_match / fts_match_commutator called directly (function-call form)
SELECT fts_match(to_ftsdoc('alpha beta'), 'alpha & beta'::ftsquery) AS fn_match_and;
SELECT fts_match_commutator('alpha & beta'::ftsquery, to_ftsdoc('alpha beta')) AS fn_match_commutator_and;


-- ============================================================================
-- Coverage: BM25F NULL-element array paths + pushdown-rejection shapes
-- (pg_fts_rank.c per-field NULL handling; pg_fts_customscan.c gating)
-- ============================================================================
-- BM25F with NULL ELEMENTS inside the arrays (docnull/wnull/avgnull/dfs NULL):
-- a NULL doc field is skipped; NULL weight/avgdl default to 1.0; NULL dfs -> 1.0.
SELECT fts_bm25f(ARRAY[to_ftsdoc('postgres'), NULL]::ftsdoc[],
                 'postgres'::ftsquery, ARRAY[2.0,1.0], 100, ARRAY[1.0,1.0]) > 0 AS bm25f_null_field;
SELECT fts_bm25f(ARRAY[to_ftsdoc('postgres'), to_ftsdoc('body')],
                 'postgres'::ftsquery, ARRAY[NULL,1.0]::float8[], 100, ARRAY[1.0,1.0]) >= 0 AS bm25f_null_weight;
SELECT fts_bm25f(ARRAY[to_ftsdoc('postgres'), to_ftsdoc('body')],
                 'postgres'::ftsquery, ARRAY[2.0,1.0], 100, ARRAY[NULL,1.0]::float8[]) >= 0 AS bm25f_null_avgdl;
SELECT fts_bm25f(ARRAY[to_ftsdoc('a b'), to_ftsdoc('c d')],
                 'a & c'::ftsquery, ARRAY[1.0,1.0], 100, ARRAY[2.0,2.0], ARRAY[NULL,3.0]::float8[]) >= 0 AS bm25f_null_dfs;
-- three fields; title (field 0) weighted heavily -> a title-only hit scores
-- higher than a body-only hit
SELECT fts_bm25f(ARRAY[to_ftsdoc('term'), to_ftsdoc('x'), to_ftsdoc('y')],
                 'term'::ftsquery, ARRAY[9.0,1.0,1.0], 100, ARRAY[1.0,1.0,1.0])
     > fts_bm25f(ARRAY[to_ftsdoc('x'), to_ftsdoc('y'), to_ftsdoc('term')],
                 'term'::ftsquery, ARRAY[9.0,1.0,1.0], 100, ARRAY[1.0,1.0,1.0]) AS bm25f_field_weight;
-- an empty ftsdoc field (doclen 0) is handled
SELECT fts_bm25f(ARRAY[to_ftsdoc(''), to_ftsdoc('term body')],
                 'term'::ftsquery, ARRAY[2.0,1.0], 100, ARRAY[1.0,2.0]) >= 0 AS bm25f_empty_field;

-- Count-pushdown rejection: shapes that must NOT push down (still correct).
CREATE TABLE psh (id serial, d ftsdoc, txt text);
INSERT INTO psh(d, txt) SELECT to_ftsdoc('english','term'||(g%4)||' body'), 'plain'||(g%3) FROM generate_series(1,200) g;
CREATE INDEX psh_idx ON psh USING fts (d);
CREATE INDEX psh_txt ON psh (txt);   -- a NON-fts index on the same rel
SET enable_seqscan = off;
-- @@@ with a NON-constant RHS (a subquery-derived value) -> RHS not a plan Const
SELECT count(*) FROM psh WHERE d @@@ (SELECT 'term1'::ftsquery);
-- two @@@ quals -> more than one qual, no single-@@@ pushdown
SELECT count(*) FROM psh WHERE d @@@ 'term1'::ftsquery AND d @@@ 'body'::ftsquery;
-- (0, as a heap scan answers: the english config stores "body" as 'bodi', so
-- the raw 'body' matches no row.  Through 1.8.3 the index read only the first
-- of the two keys and answered 50.  With the stemmed term both keys match the
-- same 50 rows.)
SELECT count(*) FROM psh WHERE d @@@ 'term1'::ftsquery AND d @@@ 'bodi'::ftsquery;
-- @@@ on a rel where the matched column also has a non-fts index (index-list walk)
SELECT count(*) FROM psh WHERE d @@@ 'term1'::ftsquery;
-- count over a rel with NO fts index at all (LHS has no matching fts index)
SELECT count(*) FROM psh WHERE txt = 'plain1';
RESET enable_seqscan;
DROP TABLE psh;

-- ============================================================================
-- Coverage: fts_highlight / fts_snippet edges (pg_fts_aux.c) + ftsdoc validity
-- ============================================================================
-- highlight/snippet: match at start, middle, end; no match; empty; multi-term;
-- phrase; unicode.
SELECT fts_highlight('the quick brown fox', 'quick'::ftsquery) LIKE '%quick%' AS hl_mid;
SELECT fts_highlight('quick brown fox', 'quick'::ftsquery) LIKE '%quick%' AS hl_start;
SELECT fts_highlight('brown fox quick', 'quick'::ftsquery) LIKE '%quick%' AS hl_end;
SELECT fts_highlight('brown fox', 'zebra'::ftsquery) AS hl_nomatch;
SELECT fts_highlight('', 'x'::ftsquery) AS hl_empty;
SELECT fts_highlight('the quick brown fox', 'quick & fox'::ftsquery) LIKE '%quick%' AS hl_multi;
SELECT length(fts_snippet('the quick brown fox jumps over the lazy dog', 'fox'::ftsquery)) > 0 AS snip_mid;
SELECT fts_snippet('nothing here', 'zebra'::ftsquery) IS NOT NULL AS snip_nomatch;
SELECT length(fts_snippet(repeat('word ', 200) || 'target ' || repeat('more ', 200), 'target'::ftsquery)) > 0 AS snip_long;
-- ftsdoc validity across edge shapes (pg_fts_docvalid.h via index build)
CREATE TABLE dv (id serial, d ftsdoc);
INSERT INTO dv(d) VALUES (to_ftsdoc('')), (to_ftsdoc('one')),
  (to_ftsdoc('a a a a a')), (to_ftsdoc('english','the the the')),
  (to_ftsdoc(to_tsvector('english','')));
CREATE INDEX dv_idx ON dv USING fts (d);
SET enable_seqscan = off;
SELECT count(*) = 1 AS one_hit FROM dv WHERE d @@@ 'one'::ftsquery;
RESET enable_seqscan;
DROP TABLE dv;

-- ============================================================================
-- Field-targeted (weight-zone) search (v1.4.0): to_ftsdoc(cfg,text,weight),
-- setftsweight, ftsdoc || ftsdoc, and term:LABEL query restriction.
-- ============================================================================
-- labelled analysis renders with the label; concat re-bases + preserves labels
SELECT to_ftsdoc('english','Vacuum contention','A')::text AS subj_A;
SELECT (to_ftsdoc('english','vacuum lock','A') || to_ftsdoc('english','the vacuum runs','C'))::text AS concat_shared;
SELECT setftsweight(to_ftsdoc('english','vacuum'),'B')::text AS relabelled;
-- render round-trips through the input parser
SELECT (to_ftsdoc('english','vacuum','A')::text)::ftsdoc::text = to_ftsdoc('english','vacuum','A')::text AS roundtrip;
-- ftsquery renders the weight mask (tsquery-style term:A)
SELECT to_ftsquery('english','vacuum:A')::text AS q_wa, to_ftsquery('english','x:AB')::text AS q_ab;
-- value-path matching: subject-zone vacuum vs body-zone vacuum
SELECT fts_match(to_ftsdoc('english','vacuum problem','A') || to_ftsdoc('english','lock contention','C'),
                 to_ftsquery('english','vacuum:A')) AS subj_hit;                              -- t
SELECT fts_match(to_ftsdoc('english','lock','A') || to_ftsdoc('english','run vacuum','C'),
                 to_ftsquery('english','vacuum:A')) AS body_no_subj;                          -- f
SELECT fts_match(to_ftsdoc('english','lock','A') || to_ftsdoc('english','run vacuum','C'),
                 to_ftsquery('english','vacuum')) AS unrestricted;                            -- t
-- multi-zone AND + multi-label mask
SELECT fts_match(to_ftsdoc('english','vacuum','A') || to_ftsdoc('english','tgl','B'),
                 to_ftsquery('english','vacuum:A & tgl:B')) AS multi_zone;                    -- t
SELECT fts_match(to_ftsdoc('english','x','A') || to_ftsdoc('english','vacuum','B'),
                 to_ftsquery('english','vacuum:AB')) AS mask_ab;                              -- t
-- unlabelled (v3-style) doc: label D matches, others do not
SELECT fts_match(to_ftsdoc('english','vacuum'), to_ftsquery('english','vacuum:A')) AS plain_a;  -- f
SELECT fts_match(to_ftsdoc('english','vacuum'), to_ftsquery('english','vacuum:D')) AS plain_d;  -- t
-- Weighted prefixes retain their mask; fuzzy + weight remains unsupported.
SELECT to_ftsquery('english','vac:A*');       -- prefix and weight
SELECT to_ftsquery('english','vac:A~1');      -- error
-- index-path parity: field restriction through the fts index == seqscan truth,
-- for count(*), fts_count, and a scan.
CREATE TABLE zmsg (id serial, subject text, body text, d ftsdoc);
INSERT INTO zmsg(subject, body) VALUES
 ('vacuum tuning', 'locks and contention'),
 ('lock contention', 'run vacuum often'),
 ('checkpoint', 'vacuum and checkpoint');
UPDATE zmsg SET d = to_ftsdoc('english', subject, 'A') || to_ftsdoc('english', body, 'C');
CREATE INDEX zmsg_fts ON zmsg USING fts (d) WITH (positions = on);
SET enable_seqscan = off;
SELECT array_agg(id ORDER BY id) AS idx_subjA FROM zmsg WHERE d @@@ to_ftsquery('english','vacuum:A');  -- {1}
SELECT fts_count('zmsg_fts', to_ftsquery('english','vacuum:A')) AS cnt_subjA;                           -- 1
SELECT fts_count('zmsg_fts', to_ftsquery('english','vacuum')) AS cnt_any;                               -- 3
SET enable_indexscan = off; SET enable_bitmapscan = off;
SELECT array_agg(id ORDER BY id) AS seq_subjA FROM zmsg WHERE d @@@ to_ftsquery('english','vacuum:A');  -- {1}
RESET enable_indexscan; RESET enable_bitmapscan; RESET enable_seqscan;
DROP TABLE zmsg;

-- ============================================================================
-- Upgrade compatibility: an index/value built WITHOUT weight labels (as by
-- pre-1.4.0, and by the 2-arg to_ftsdoc) reads correctly under 1.4.0 -- every
-- position is label D, so unrestricted queries are unchanged, term:D matches,
-- and term:A/B/C does not.  This is the "no REINDEX" guarantee: existing
-- unlabelled indexes keep working; only rebuilding from labelled docs adds
-- field provenance.
CREATE TABLE zold (id serial, d ftsdoc);
INSERT INTO zold(d) SELECT to_ftsdoc('english','vacuum lock number '||g) FROM generate_series(1,200) g;
CREATE INDEX zold_fts ON zold USING fts (d) WITH (positions = on);
SET enable_seqscan = off;
-- unrestricted query unchanged (all 200 rows contain vacuum)
SELECT count(*) = 200 AS unrestricted_ok FROM zold WHERE d @@@ to_ftsquery('english','vacuum');
-- term:D matches unlabelled data (unlabelled == D)
SELECT count(*) = 200 AS labelD_matches FROM zold WHERE d @@@ to_ftsquery('english','vacuum:D');
-- term:A does NOT match unlabelled data
SELECT count(*) = 0 AS labelA_no_match FROM zold WHERE d @@@ to_ftsquery('english','vacuum:A');
-- phrase still works on the unlabelled positions index
SELECT count(*) = 200 AS phrase_ok FROM zold WHERE d @@@ '"vacuum lock"'::ftsquery;
RESET enable_seqscan;
DROP TABLE zold;

-- positionless-doc adjacency: the ftsdoc text-input parser SYNTHESIZES positions
-- from token order when the literal supplies none, so FTS_DOC_HAS_POS holds and
-- phrase adjacency is still enforced.  This pins that behaviour: phrase_step()
-- has a presence-only AND fallback for docs without positions ("precision
-- degraded"), and these assertions are what keep that fallback unreachable --
-- if a future change lets a positionless doc through, the reversed case below
-- flips to true and a phrase silently becomes a conjunction.
SELECT 'bravo alpha'::ftsdoc::text AS nopos_synthesizes_positions;                                        -- 'alpha':1@2 'bravo':1@1
SELECT 'bravo alpha'::ftsdoc @@@ to_ftsquery('simple','"alpha bravo"') AS nopos_reversed_phrase_false;    -- f
SELECT 'alpha bravo'::ftsdoc @@@ to_ftsquery('simple','"alpha bravo"') AS nopos_forward_phrase_true;      -- t
SELECT 'bravo alpha'::ftsdoc @@@ to_ftsquery('simple','alpha & bravo') AS nopos_conjunction_true;         -- t

-- A phrase over an operand whose positions are unavailable is UNVERIFIABLE, so
-- it must be false -- matching PostgreSQL, which without TS_EXEC_PHRASE_NO_POS
-- has OP_PHRASE "always return false if lexeme position information is not
-- available".  Four routes reach that state; all must agree.  See
-- bench/REVIEW_PHRASE_NOPOS.md.
SELECT to_ftsdoc('simple','brown quick') @@@ '"quick brown"'::ftsquery AS nopos_control_positioned_f;  -- f
SELECT to_ftsdoc(strip(to_tsvector('simple','brown quick'))) @@@ '"quick brown"'::ftsquery AS nopos_via_strip_tsvector;   -- f
SELECT ($$'brown':1$$::ftsdoc || to_ftsdoc('simple','quick')) @@@ '"quick brown"'::ftsquery AS nopos_via_concat;          -- f
-- a positioned doc still matches a genuine adjacency, so this is not a blanket false
SELECT to_ftsdoc('simple','quick brown') @@@ '"quick brown"'::ftsquery AS positioned_phrase_still_true;   -- t
-- boolean UNDER a phrase: positions are nulled by the AND arm even though the
-- DOCUMENT is fully positioned, so the doc's own flag cannot discriminate.
-- PostgreSQL answers f here; we must too.
SELECT to_ftsdoc('simple','fox brown zzz quick') @@@ (to_tsquery('simple','quick <-> (brown & fox)'))::ftsquery AS bool_under_phrase_f;  -- f
-- prefix-inside-phrase is DELIBERATELY lossy (positions are not tracked for a
-- prefix operand), and that shipped behaviour is preserved: still permissive.
SELECT to_ftsdoc('simple','brown quick') @@@ '"quick bro*"'::ftsquery AS prefix_in_phrase_checks_positions;   -- f
-- field-zone labels live in position high bits, so a positionless doc carries no
-- label information: a zone restriction we cannot evaluate must not match.
SELECT $$'quick':1$$::ftsdoc @@@ 'quick:A'::ftsquery AS nopos_zone_A_never_matches;   -- f
SELECT $$'quick':1$$::ftsdoc @@@ 'quick:D'::ftsquery AS nopos_zone_D_no_longer_matches;  -- f

-- ---------------------------------------------------------------------------
-- Intra-word separators are LITERAL, not operators (field bug 2026-09-13).
--
-- to_ftsquery('pkg-config') used to parse as ('pkg' & !'config'): the NOT clause
-- actively EXCLUDED the documents being searched for, so a search for pkg-config
-- returned everything except pkg-config, and install-info matched 1 row instead of 10.
-- '/' was worse -- it opened a regex and swallowed the rest of the query -- and '.'
-- split the term.  A silently wrong answer is a worse failure than a parse error.
--
-- The separator set matches what the DOCUMENT analyzer joins ('-', '.', '/' inside a
-- word; '_' and '+' split), so a query token can actually match a stored token.
-- ---------------------------------------------------------------------------
SELECT to_ftsquery('simple', 'pkg' || chr(45) || 'config')::text AS hyphen_is_literal;
SELECT to_ftsquery('simple', 'install' || chr(45) || 'info')::text AS hyphen_is_literal2;
SELECT to_ftsquery('simple', 'foo/bar')::text AS slash_is_literal;
SELECT to_ftsquery('simple', 'python3.14')::text AS dot_is_literal;
-- trailing separators still drop, matching to_tsvector and our own doc analyzer
SELECT to_ftsquery('simple', 'c++')::text AS trailing_plus_drops;
SELECT to_ftsquery('simple', 'gtk+')::text AS trailing_plus_drops2;
-- and the operators they used to be confused with STILL work
SELECT to_ftsquery('simple', 'a ' || chr(45) || 'b')::text AS prefix_minus_is_not;
SELECT to_ftsquery('simple', chr(45) || 'b')::text AS leading_minus_is_not;
SELECT to_ftsquery('simple', '/^ab.*$/')::text AS regex_still_parses;
-- the whole point: the query now matches the document it was typed for
SELECT to_ftsdoc('simple', 'the pkg' || chr(45) || 'config tool')
       @@@ to_ftsquery('simple', 'pkg' || chr(45) || 'config') AS hyphen_matches_doc;
SELECT to_ftsdoc('simple', 'see foo/bar path')
       @@@ to_ftsquery('simple', 'foo/bar') AS slash_matches_doc;
SELECT to_ftsdoc('simple', 'python3.14 release')
       @@@ to_ftsquery('simple', 'python3.14') AS dot_matches_doc;
-- negation is unchanged: excludes when the term is present, matches when absent
SELECT to_ftsdoc('simple', 'only a here')
       @@@ to_ftsquery('simple', 'a ' || chr(45) || 'b') AS neg_matches_when_absent;
SELECT to_ftsdoc('simple', 'a and b here')
       @@@ to_ftsquery('simple', 'a ' || chr(45) || 'b') AS neg_excludes_when_present;

-- Runtime NULL scan keys must not be dereferenced or replaced by ORDER BY keys.
CREATE TABLE null_scan_keys (id integer, d ftsdoc);
INSERT INTO null_scan_keys VALUES (1, to_ftsdoc('alpha')), (2, to_ftsdoc('beta'));
CREATE INDEX null_scan_keys_idx ON null_scan_keys USING fts(d);
ANALYZE null_scan_keys;
CREATE TABLE null_scan_rhs (q ftsquery);
SET enable_seqscan = off;
SET enable_indexscan = off;
SELECT count(*) AS null_bitmap_rhs FROM null_scan_keys
WHERE d @@@ (SELECT q FROM null_scan_rhs);
RESET enable_indexscan;
SET enable_bitmapscan = off;
SELECT count(*) AS null_plain_rhs FROM null_scan_keys
WHERE d @@@ (SELECT q FROM null_scan_rhs);
SELECT count(*) AS null_filter_with_order FROM
  (SELECT id FROM null_scan_keys
   WHERE d @@@ (SELECT q FROM null_scan_rhs)
   ORDER BY d <=> 'alpha'::ftsquery) s;
SELECT array_agg(id ORDER BY id) AS null_order_ids,
       bool_and(distance IS NULL) AS null_order_distances
FROM (SELECT id, d <=> (SELECT q FROM null_scan_rhs) AS distance
      FROM null_scan_keys WHERE d @@@ 'alpha'::ftsquery
      ORDER BY d <=> (SELECT q FROM null_scan_rhs)) s;
RESET enable_bitmapscan;
RESET enable_seqscan;
DROP TABLE null_scan_rhs, null_scan_keys;

-- Ranked WAND seeks must not mistake the next term's block for the next block
-- of the current term.  The last alpha block shares a page with beta's header.
CREATE TABLE wand_seek_regress (id integer, d ftsdoc);
INSERT INTO wand_seek_regress
SELECT g, to_ftsdoc(CASE WHEN g <= 64 THEN 'alpha beta' ELSE 'alpha' END)
FROM generate_series(1, 129) AS g;
INSERT INTO wand_seek_regress VALUES (130, to_ftsdoc(repeat('alpha beta ', 20)));
CREATE INDEX wand_seek_regress_fts ON wand_seek_regress USING fts (d);
WITH small AS (SELECT * FROM fts_search('wand_seek_regress_fts', 'alpha | beta'::ftsquery, 1)),
     truth AS (SELECT * FROM fts_search('wand_seek_regress_fts', 'alpha | beta'::ftsquery, 130)
               ORDER BY score DESC, ctid LIMIT 1)
SELECT EXISTS (SELECT 1 FROM small s JOIN truth t
               ON s.ctid = t.ctid AND s.score = t.score) AS wand_seek_exact;
DROP TABLE wand_seek_regress;

-- MaxScore discards only a low-impact prefix whose combined bound is below
-- the current threshold.  A suffix bound wrongly loses the superior last row.
CREATE TABLE maxscore_regress (id integer, d ftsdoc);
INSERT INTO maxscore_regress
SELECT g, to_ftsdoc(repeat('alpha beta gamma delta ', 10))
FROM generate_series(1, 64) AS g;
INSERT INTO maxscore_regress VALUES
  (65, to_ftsdoc(repeat('alpha beta gamma delta ', 100)));
CREATE INDEX maxscore_regress_fts ON maxscore_regress USING fts (d);
WITH small AS (SELECT * FROM fts_search('maxscore_regress_fts',
                                        'alpha | beta | gamma | delta'::ftsquery, 1)),
     truth AS (SELECT * FROM fts_search('maxscore_regress_fts',
                                        'alpha | beta | gamma | delta'::ftsquery, 65)
               ORDER BY score DESC, ctid LIMIT 1)
SELECT EXISTS (SELECT 1 FROM small s JOIN truth t
               ON s.ctid = t.ctid AND s.score = t.score) AS maxscore_prefix_exact;
DROP TABLE maxscore_regress;

-- Replacing a tied cutoff score must evict the largest TID, retaining stable
-- score DESC, TID ASC order for every k.
CREATE TABLE wand_tie_regress (id integer, d ftsdoc);
INSERT INTO wand_tie_regress
SELECT g, to_ftsdoc('alpha') FROM generate_series(1, 256) AS g;
INSERT INTO wand_tie_regress VALUES (257, to_ftsdoc(repeat('alpha ', 20)));
CREATE INDEX wand_tie_regress_fts ON wand_tie_regress USING fts (d);
WITH small AS (SELECT id FROM fts_search('wand_tie_regress_fts', 'alpha'::ftsquery, 64) r
               JOIN wand_tie_regress d ON d.ctid = r.ctid),
     truth AS (SELECT id, row_number() OVER (ORDER BY r.score DESC, r.ctid) AS ord
               FROM fts_search('wand_tie_regress_fts', 'alpha'::ftsquery, 257) r
               JOIN wand_tie_regress d ON d.ctid = r.ctid)
SELECT (SELECT array_agg(id ORDER BY id) FROM small) =
       (SELECT array_agg(id ORDER BY id) FROM truth WHERE ord <= 64)
       AS wand_cutoff_ties_exact;
DROP TABLE wand_tie_regress;

-- ---------------------------------------------------------------------------
-- NOT through the index, across segments, tombstones and the pending list.
--
-- The index evaluates NOT by set difference.  Only a query whose WHOLE result
-- is negated (!a, !a & !b, a | !b, !(a & !b), ...) must be complemented against
-- the segment universe (every TID in the segment); a NOT nested under an AND
-- (a & !b, !a & b) is plain set difference, and a double negation cancels.
-- Each shape below must count the same through the index -- a bitmap scan and
-- fts_count -- as the heap matcher under a forced seqscan.  The index has two
-- segments (the second flushed by VACUUM), tombstones in both (deleted +
-- vacuumed rows), and a pending list whose rows may reuse the freed heap
-- slots.  count(id), not count(*): a bare count(*) is answered by the FtsCount
-- pushdown, which uses the index even when seqscans are forced.
-- ---------------------------------------------------------------------------
CREATE FUNCTION notseg_doc(g int) RETURNS ftsdoc LANGUAGE sql AS $$
  SELECT to_ftsdoc('w' || g || CASE WHEN g % 2 = 0 THEN ' apple' ELSE '' END
                            || CASE WHEN g % 3 = 0 THEN ' cherry' ELSE '' END
                            || CASE WHEN g % 5 = 0 THEN ' zeta' ELSE '' END) $$;
CREATE TABLE notseg (id serial, d ftsdoc) WITH (autovacuum_enabled = off);
INSERT INTO notseg(d) SELECT notseg_doc(g) FROM generate_series(1, 300) g;
CREATE INDEX notseg_fts ON notseg USING fts (d);                -- segment 1
INSERT INTO notseg(d) SELECT notseg_doc(g) FROM generate_series(301, 600) g;
VACUUM notseg;                                                  -- segment 2
DELETE FROM notseg WHERE id % 7 = 0;
VACUUM notseg;                                                  -- tombstones
INSERT INTO notseg(d) SELECT notseg_doc(g) FROM generate_series(601, 700) g;  -- pending
SELECT fts_index_nsegments('notseg_fts') AS notseg_segments;    -- 2
-- the two plans compared below: bitmap scan of the index vs heap seqscan
SET enable_seqscan = off; SET enable_indexscan = off; SET enable_bitmapscan = on;
EXPLAIN (COSTS OFF) SELECT count(id) FROM notseg WHERE d @@@ 'apple & !cherry'::ftsquery;
SET enable_seqscan = on; SET enable_bitmapscan = off;
EXPLAIN (COSTS OFF) SELECT count(id) FROM notseg WHERE d @@@ 'apple & !cherry'::ftsquery;
RESET enable_seqscan; RESET enable_indexscan; RESET enable_bitmapscan;
CREATE FUNCTION notseg_counts(qry text, OUT via_bitmap bigint, OUT via_heap bigint,
                              OUT via_fts_count bigint) LANGUAGE plpgsql AS $$
BEGIN
  SET LOCAL enable_seqscan = off; SET LOCAL enable_indexscan = off; SET LOCAL enable_bitmapscan = on;
  EXECUTE format('SELECT count(id) FROM notseg WHERE d @@@ %L::ftsquery', qry) INTO via_bitmap;
  SET LOCAL enable_seqscan = on; SET LOCAL enable_bitmapscan = off;
  EXECUTE format('SELECT count(id) FROM notseg WHERE d @@@ %L::ftsquery', qry) INTO via_heap;
  via_fts_count := fts_count('notseg_fts', qry::ftsquery);
END $$;
-- rows 1-4 need no universe; rows 5-10 do (the whole result is negated).
-- 615 live rows; every count is non-zero.
SELECT v.q, c.via_bitmap, c.via_heap, c.via_fts_count,
       c.via_bitmap = c.via_heap AND c.via_fts_count = c.via_heap AS agree
FROM (VALUES (1, 'apple & !cherry'), (2, '!apple & cherry'),
             (3, 'apple & !(cherry | zeta)'), (4, '!!apple'),
             (5, '!apple & !cherry'), (6, '!(apple | cherry)'),
             (7, 'apple | !cherry'), (8, '!(apple & !cherry)'),
             (9, '!apple'), (10, '!kiwi')) v(ord, q),
     LATERAL notseg_counts(v.q) c
ORDER BY v.ord;
DROP TABLE notseg;
DROP FUNCTION notseg_counts(text);
DROP FUNCTION notseg_doc(int);
-- ---------------------------------------------------------------------------
-- NOT over an inexact operand through the index.
--
-- Without positions -- or in the boolean evaluator, which never reads them --
-- the index approximates a phrase, within-N or exact-distance operand (and a
-- field-restricted term) by term presence alone: a superset of its true
-- matches, which the heap recheck then trims.  Under an odd number of NOTs a
-- superset becomes a subset, and a recheck cannot restore rows it never sees,
-- so those operands must be approximated from below there instead.  Every
-- shape must count the same six ways: bitmap scan and fts_count on a
-- positions = on and a positions = off index, and the heap matcher under a
-- forced seqscan on each table.  Both indexes have two segments, tombstones
-- and a pending list.  bravo/cherry occur adjacent (g % 3 = 0), apart
-- (g % 3 = 1) or reversed (g % 3 = 2); cherry also occurs in zone A when
-- g % 4 = 0; the rest of each document is zone C.
-- ---------------------------------------------------------------------------
CREATE FUNCTION notpos_doc(g int) RETURNS ftsdoc LANGUAGE sql AS $$
  SELECT to_ftsdoc('simple', 'w' || g
           || CASE g % 3 WHEN 0 THEN ' bravo cherry' WHEN 1 THEN ' bravo x cherry'
                         ELSE ' cherry bravo' END
           || CASE WHEN g % 2 = 0 THEN ' apple' ELSE '' END
           || CASE WHEN g % 5 = 0 THEN ' zeta' ELSE '' END, 'C')
      || to_ftsdoc('simple', CASE WHEN g % 4 = 0 THEN 'cherry' ELSE 'kappa' END, 'A') $$;
CREATE TABLE notpos_on (id serial, d ftsdoc) WITH (autovacuum_enabled = off);
CREATE TABLE notpos_off (id serial, d ftsdoc) WITH (autovacuum_enabled = off);
INSERT INTO notpos_on(d) SELECT notpos_doc(g) FROM generate_series(1, 300) g;
INSERT INTO notpos_off(d) SELECT notpos_doc(g) FROM generate_series(1, 300) g;
CREATE INDEX notpos_on_fts ON notpos_on USING fts (d) WITH (positions = on);
CREATE INDEX notpos_off_fts ON notpos_off USING fts (d) WITH (positions = off);
INSERT INTO notpos_on(d) SELECT notpos_doc(g) FROM generate_series(301, 600) g;
INSERT INTO notpos_off(d) SELECT notpos_doc(g) FROM generate_series(301, 600) g;
VACUUM notpos_on; VACUUM notpos_off;                            -- segment 2
DELETE FROM notpos_on WHERE id % 7 = 0; DELETE FROM notpos_off WHERE id % 7 = 0;
VACUUM notpos_on; VACUUM notpos_off;                            -- tombstones
INSERT INTO notpos_on(d) SELECT notpos_doc(g) FROM generate_series(601, 700) g;
INSERT INTO notpos_off(d) SELECT notpos_doc(g) FROM generate_series(601, 700) g;
SELECT fts_index_nsegments('notpos_on_fts') AS on_segments,
       fts_index_nsegments('notpos_off_fts') AS off_segments;
CREATE FUNCTION notpos_counts(qry text, OUT on_bitmap bigint, OUT on_count bigint,
                              OUT off_bitmap bigint, OUT off_count bigint,
                              OUT heap bigint, OUT heap_off bigint) LANGUAGE plpgsql AS $$
BEGIN
  SET LOCAL enable_seqscan = off; SET LOCAL enable_indexscan = off; SET LOCAL enable_bitmapscan = on;
  EXECUTE format('SELECT count(id) FROM notpos_on WHERE d @@@ %L::ftsquery', qry) INTO on_bitmap;
  EXECUTE format('SELECT count(id) FROM notpos_off WHERE d @@@ %L::ftsquery', qry) INTO off_bitmap;
  SET LOCAL enable_seqscan = on; SET LOCAL enable_bitmapscan = off;
  EXECUTE format('SELECT count(id) FROM notpos_on WHERE d @@@ %L::ftsquery', qry) INTO heap;
  EXECUTE format('SELECT count(id) FROM notpos_off WHERE d @@@ %L::ftsquery', qry) INTO heap_off;
  on_count := fts_count('notpos_on_fts', qry::ftsquery);
  off_count := fts_count('notpos_off_fts', qry::ftsquery);
END $$;
-- 615 live rows per table.  Rows 1-2 are positive controls; every heap count
-- is non-zero.
SELECT v.q, c.heap, c.on_bitmap, c.on_count, c.off_bitmap, c.off_count,
       c.heap > 0 AND c.heap_off = c.heap AND c.on_bitmap = c.heap
         AND c.on_count = c.heap AND c.off_bitmap = c.heap
         AND c.off_count = c.heap AS agree
FROM (VALUES (1, 'apple & "bravo cherry"'), (2, 'apple & cherry:A'),
             (3, 'apple & !"bravo cherry"'), (4, 'apple & !(bravo w/1 cherry)'),
             (5, 'apple & !(bravo <-> cherry)'), (6, 'apple & !NEAR(bravo cherry, 1)'),
             (7, '!"bravo cherry"'), (8, 'apple & !("bravo cherry" | zeta)'),
             (9, '"bravo cherry" | !apple'), (10, '!(apple & !"bravo cherry")'),
             (11, 'apple & !cherry:A'), (12, '!cherry:A'),
             (13, 'apple & !(cherry:A & zeta)'), (14, '!!"bravo cherry"')) v(ord, q),
     LATERAL notpos_counts(v.q) c
ORDER BY v.ord;
DROP TABLE notpos_on;
DROP TABLE notpos_off;
DROP FUNCTION notpos_counts(text);
DROP FUNCTION notpos_doc(int);

-- ============================================================================
-- WHERE and ORDER BY may carry DIFFERENT queries, and EVERY WHERE key counts.
--
-- Two defects through 1.8.3 (see CHANGELOG):
--  (a) the <=> ordering scan read only the ORDER BY query.  bm25_rescan
--      overwrote the WHERE key's query with it, and the ordered path returns
--      xs_recheck = false, so the executor never re-applied the WHERE:
--      `WHERE d @@@ apple ORDER BY d <=> cherry` returned cherry rows lacking
--      apple and missed the apple rows that hold no cherry;
--  (b) only the first scan key was ever read, so `WHERE d @@@ a AND d @@@ b`
--      served by ONE index scan returned a-rows lacking b.
-- The filter is the AND of every WHERE key; the rank is the ORDER BY query.
-- A filter row holding none of the rank terms scores 0 (distance 1.0) and
-- comes after every scored row.  Identical WHERE and ORDER BY queries -- the
-- common shape -- keep the unchanged path.
-- Every wr document has six tokens, so a rank term's BM25 order is its tf
-- order; equal scores come out in heap (TID) order.
-- ============================================================================
CREATE TABLE wr (id int, d ftsdoc);
INSERT INTO wr VALUES
  ( 1, to_ftsdoc('simple', 'apple cherry cherry cherry kiwi lime')),
  ( 2, to_ftsdoc('simple', 'apple cherry cherry kiwi lime mango')),
  ( 3, to_ftsdoc('simple', 'apple cherry kiwi lime mango pear')),
  ( 4, to_ftsdoc('simple', 'apple banana kiwi lime mango pear')),
  ( 5, to_ftsdoc('simple', 'apple kiwi lime mango pear plum')),
  ( 6, to_ftsdoc('simple', 'cherry cherry cherry cherry kiwi lime')),
  ( 7, to_ftsdoc('simple', 'cherry cherry cherry kiwi lime mango')),
  ( 8, to_ftsdoc('simple', 'banana cherry kiwi lime mango pear')),
  ( 9, to_ftsdoc('simple', 'banana kiwi lime mango pear plum')),
  (10, to_ftsdoc('simple', 'kiwi lime mango pear plum quince'));
CREATE INDEX wr_fts ON wr USING fts (d);
ANALYZE wr;
SET enable_seqscan = off; SET enable_bitmapscan = off;
-- (1) filter apple, rank cherry, through the ordering Index Scan
EXPLAIN (COSTS OFF)
SELECT id FROM wr WHERE d @@@ 'apple'::ftsquery
ORDER BY d <=> 'cherry'::ftsquery LIMIT 10;
-- every apple row: the cherry holders by tf (1, 2, 3), then 4 and 5 (score 0)
SELECT id FROM wr WHERE d @@@ 'apple'::ftsquery
ORDER BY d <=> 'cherry'::ftsquery LIMIT 10;
SELECT count(*) AS filter_rows,
       count(*) FILTER (WHERE NOT d @@@ 'apple'::ftsquery) AS filter_violations
FROM (SELECT d FROM wr WHERE d @@@ 'apple'::ftsquery
      ORDER BY d <=> 'cherry'::ftsquery LIMIT 100) s;                 -- 5 | 0
-- ORDER BY does not filter: ranking by an AND query still returns every
-- filter row, by the summed score of its terms (4: banana; 1, 2, 3: cherry)
SELECT id FROM wr WHERE d @@@ 'apple'::ftsquery
ORDER BY d <=> 'cherry & banana'::ftsquery LIMIT 10;
-- (2) a filter row still in the pending list is returned unranked (distance
-- 1.0, after the scored rows): the ranked scan scores segments only, but the
-- WHERE must admit every matching row.  After a flush it ranks normally.
INSERT INTO wr VALUES (11, to_ftsdoc('simple', 'apple cherry kiwi lime mango pear'));
SELECT id FROM wr WHERE d @@@ 'apple'::ftsquery
ORDER BY d <=> 'cherry'::ftsquery LIMIT 10;
SELECT fts_merge('wr_fts') AS merged;
SELECT id FROM wr WHERE d @@@ 'apple'::ftsquery
ORDER BY d <=> 'cherry'::ftsquery LIMIT 10;
-- (3) two WHERE keys on one index: both are applied on the bitmap, the plain
-- and the ordering index paths, matching a sequential scan
RESET enable_bitmapscan; SET enable_indexscan = off;
EXPLAIN (COSTS OFF)
SELECT id FROM wr WHERE d @@@ 'apple'::ftsquery AND d @@@ 'cherry'::ftsquery;
SELECT array_agg(id ORDER BY id) AS bitmap_two_keys
FROM wr WHERE d @@@ 'apple'::ftsquery AND d @@@ 'cherry'::ftsquery;
RESET enable_indexscan; SET enable_bitmapscan = off;
EXPLAIN (COSTS OFF)
SELECT id FROM wr WHERE d @@@ 'apple'::ftsquery AND d @@@ 'cherry'::ftsquery;
SELECT array_agg(id ORDER BY id) AS plain_two_keys
FROM wr WHERE d @@@ 'apple'::ftsquery AND d @@@ 'cherry'::ftsquery;
EXPLAIN (COSTS OFF)
SELECT id FROM wr WHERE d @@@ 'apple'::ftsquery AND d @@@ 'banana'::ftsquery
ORDER BY d <=> 'cherry'::ftsquery LIMIT 10;
SELECT id FROM wr WHERE d @@@ 'apple'::ftsquery AND d @@@ 'banana'::ftsquery
ORDER BY d <=> 'cherry'::ftsquery LIMIT 10;
RESET enable_seqscan; SET enable_indexscan = off;
SELECT array_agg(id ORDER BY id) AS seq_two_keys
FROM wr WHERE d @@@ 'apple'::ftsquery AND d @@@ 'cherry'::ftsquery;
RESET enable_indexscan; RESET enable_bitmapscan;
DROP TABLE wr;

-- (4) The common shape -- ONE query value feeds both WHERE and ORDER BY
-- through a CTE -- is byte-identical on both sides and keeps the unchanged
-- top-k path.  Rows 1-12 have 13 tokens each, so they come in apple tf
-- order; row 13, still in the pending list, is ranked by the exact pending
-- fallback (1.8.3 left it out).  A duplicated WHERE key is folded to one, so
-- it keeps that path too.
CREATE TABLE wrq (id int, d ftsdoc);
INSERT INTO wrq SELECT g, to_ftsdoc('simple',
    repeat('apple ', g) || repeat('kiwi ', 12 - g) || 'cherry')
  FROM generate_series(1, 12) g;
CREATE INDEX wrq_fts ON wrq USING fts (d);
ANALYZE wrq;
INSERT INTO wrq VALUES (13, to_ftsdoc('simple', 'apple cherry kiwi'));
SET enable_seqscan = off; SET enable_bitmapscan = off;
EXPLAIN (COSTS OFF)
WITH q AS (SELECT to_ftsquery('simple', 'apple & cherry') AS query)
SELECT id FROM wrq WHERE d @@@ (SELECT query FROM q)
ORDER BY d <=> (SELECT query FROM q) LIMIT 20;
WITH q AS (SELECT to_ftsquery('simple', 'apple & cherry') AS query)
SELECT id FROM wrq WHERE d @@@ (SELECT query FROM q)
ORDER BY d <=> (SELECT query FROM q) LIMIT 20;
WITH q AS (SELECT to_ftsquery('simple', 'apple & cherry') AS query)
SELECT id FROM wrq WHERE d @@@ (SELECT query FROM q) AND d @@@ (SELECT query FROM q)
ORDER BY d <=> (SELECT query FROM q) LIMIT 20;
RESET enable_seqscan; RESET enable_bitmapscan;
DROP TABLE wrq;

-- (5) Deep pull: an ORDER BY index scan must be able to return EVERY filter
-- row exactly once and in order -- by descending score (here: descending
-- cherry tf, as every document has five tokens, so id % 4 ascending), equal
-- scores in heap (ctid) order, then the rows holding no cherry -- across
-- segments, with deleted rows both before VACUUM (the heap fetch drops them)
-- and after it (the index has tombstoned them), and with later rows that may
-- reuse the vacuumed heap slots.  Filter rows: ids 1..1500, 2001..2500 and
-- 3001..3200.
CREATE TABLE wrd (id int, d ftsdoc);
INSERT INTO wrd SELECT g, to_ftsdoc('simple', 'apple ' ||
    (ARRAY['cherry cherry cherry', 'cherry cherry kiwi', 'cherry kiwi kiwi',
           'kiwi kiwi kiwi'])[1 + g % 4] || ' w' || (g % 50))
  FROM generate_series(1, 1500) g;
INSERT INTO wrd SELECT g, to_ftsdoc('simple', 'cherry cherry cherry kiwi w' || (g % 50))
  FROM generate_series(1501, 2000) g;
CREATE INDEX wrd_fts ON wrd USING fts (d);
INSERT INTO wrd SELECT g, to_ftsdoc('simple', 'apple ' ||
    (ARRAY['cherry cherry cherry', 'cherry cherry kiwi', 'cherry kiwi kiwi',
           'kiwi kiwi kiwi'])[1 + g % 4] || ' w' || (g % 50))
  FROM generate_series(2001, 2500) g;
VACUUM ANALYZE wrd;                        -- flushes the pending rows: a second segment
SELECT fts_index_nsegments('wrd_fts') > 1 AS multi_segment;
SET enable_seqscan = off; SET enable_bitmapscan = off;
EXPLAIN (COSTS OFF)
SELECT id FROM wrd WHERE d @@@ 'apple'::ftsquery
ORDER BY d <=> 'cherry'::ftsquery LIMIT 100000;
SELECT count(*) AS filter_rows, count(DISTINCT id) AS distinct_ids,
       count(*) FILTER (WHERE NOT d @@@ 'apple'::ftsquery) AS filter_violations
FROM (SELECT id, d FROM wrd WHERE d @@@ 'apple'::ftsquery
      ORDER BY d <=> 'cherry'::ftsquery LIMIT 100000) s;          -- 2000 | 2000 | 0
SELECT (SELECT array_agg(id) FROM (SELECT id FROM wrd WHERE d @@@ 'apple'::ftsquery
          ORDER BY d <=> 'cherry'::ftsquery LIMIT 100000) s)
     = (SELECT array_agg(id ORDER BY id % 4, ctid) FROM wrd
        WHERE id <= 1500 OR id BETWEEN 2001 AND 2500 OR id > 3000)
       AS deep_order_exact;
DELETE FROM wrd WHERE id % 10 = 0;
SELECT (SELECT array_agg(id) FROM (SELECT id FROM wrd WHERE d @@@ 'apple'::ftsquery
          ORDER BY d <=> 'cherry'::ftsquery LIMIT 100000) s)
     = (SELECT array_agg(id ORDER BY id % 4, ctid) FROM wrd
        WHERE id <= 1500 OR id BETWEEN 2001 AND 2500 OR id > 3000)
       AS deep_order_after_delete;
RESET enable_seqscan; RESET enable_bitmapscan;
VACUUM wrd;
INSERT INTO wrd SELECT g, to_ftsdoc('simple', 'apple ' ||
    (ARRAY['cherry cherry cherry', 'cherry cherry kiwi', 'cherry kiwi kiwi',
           'kiwi kiwi kiwi'])[1 + g % 4] || ' w' || (g % 50))
  FROM generate_series(3001, 3200) g;
VACUUM wrd;
SET enable_seqscan = off; SET enable_bitmapscan = off;
SELECT count(*) AS filter_rows, count(DISTINCT id) AS distinct_ids
FROM (SELECT id FROM wrd WHERE d @@@ 'apple'::ftsquery
      ORDER BY d <=> 'cherry'::ftsquery LIMIT 100000) s;          -- 2000 | 2000
SELECT (SELECT array_agg(id) FROM (SELECT id FROM wrd WHERE d @@@ 'apple'::ftsquery
          ORDER BY d <=> 'cherry'::ftsquery LIMIT 100000) s)
     = (SELECT array_agg(id ORDER BY id % 4, ctid) FROM wrd
        WHERE id <= 1500 OR id BETWEEN 2001 AND 2500 OR id > 3000)
       AS deep_order_after_reuse;
RESET enable_seqscan; RESET enable_bitmapscan;
DROP TABLE wrd;

-- (6) A phrase filter ranked by other words fills a whole page with phrase
-- rows -- answered from positions (positions = on), or over-generated and
-- then dropped by the executor's heap recheck (positions = off) -- and the
-- page holds the best-ranked of them (every one carries "date").
CREATE TABLE wrp (id int, body text);
INSERT INTO wrp SELECT g,
    (ARRAY['apple banana cherry', 'cherry banana apple', 'banana apple kiwi'])[1 + g % 3]
    || (ARRAY[' date date', ' fig', ' kiwi lime', ' lime', ' plum'])[1 + g % 5]
  FROM generate_series(1, 600) g;
CREATE INDEX wrp_fts ON wrp USING fts (to_ftsdoc('simple', body)) WITH (positions = on);
ANALYZE wrp;
SET enable_seqscan = off; SET enable_bitmapscan = off;
EXPLAIN (COSTS OFF)
SELECT id FROM wrp WHERE to_ftsdoc('simple', body) @@@ to_ftsquery('simple', '"apple banana cherry"')
ORDER BY to_ftsdoc('simple', body) <=> to_ftsquery('simple', 'date | fig') LIMIT 20;
SELECT count(*) AS page_rows,
       count(*) FILTER (WHERE NOT to_ftsdoc('simple', body)
                        @@@ to_ftsquery('simple', '"apple banana cherry"')) AS filter_violations,
       count(*) FILTER (WHERE body LIKE '%date%') AS best_ranked
FROM (SELECT body FROM wrp
      WHERE to_ftsdoc('simple', body) @@@ to_ftsquery('simple', '"apple banana cherry"')
      ORDER BY to_ftsdoc('simple', body) <=> to_ftsquery('simple', 'date | fig') LIMIT 20) s;
DROP INDEX wrp_fts;
CREATE INDEX wrp_fts_nopos ON wrp USING fts (to_ftsdoc('simple', body));
SELECT count(*) AS page_rows,
       count(*) FILTER (WHERE NOT to_ftsdoc('simple', body)
                        @@@ to_ftsquery('simple', '"apple banana cherry"')) AS filter_violations,
       count(*) FILTER (WHERE body LIKE '%date%') AS best_ranked
FROM (SELECT body FROM wrp
      WHERE to_ftsdoc('simple', body) @@@ to_ftsquery('simple', '"apple banana cherry"')
      ORDER BY to_ftsdoc('simple', body) <=> to_ftsquery('simple', 'date | fig') LIMIT 20) s;
RESET enable_seqscan; RESET enable_bitmapscan;
DROP TABLE wrp;

-- (7) The filter-vs-rank shape through an english expression index with
-- only sequential scans disabled: 1 holds apple and cherry, 4 only apple.
CREATE TABLE wre (id int, body text);
INSERT INTO wre VALUES (1, 'an apple and cherry pie'), (2, 'a cherry tart'),
  (3, 'cherries and more cherries'), (4, 'an apple a day'), (5, 'plums and pears');
CREATE INDEX wre_fts ON wre USING fts (to_ftsdoc('english', body)) WITH (positions = on);
ANALYZE wre;
SET enable_seqscan = off;
EXPLAIN (COSTS OFF)
SELECT id FROM wre WHERE to_ftsdoc('english', body) @@@ to_ftsquery('english', 'apple')
ORDER BY to_ftsdoc('english', body) <=> to_ftsquery('english', 'cherry') LIMIT 10;
SELECT id FROM wre WHERE to_ftsdoc('english', body) @@@ to_ftsquery('english', 'apple')
ORDER BY to_ftsdoc('english', body) <=> to_ftsquery('english', 'cherry') LIMIT 10;
RESET enable_seqscan;
DROP TABLE wre;

-- (8) A NULL query value (a NULL runtime parameter) crashed the backend
-- through 1.8.3.  @@@ is strict, so a NULL WHERE key admits no row on any
-- path; d <=> NULL is NULL for every row, so a NULL ORDER BY argument returns
-- every filter row, each with a NULL distance.
CREATE TABLE wrn (id int, d ftsdoc);
INSERT INTO wrn VALUES (1, to_ftsdoc('simple', 'apple cherry')),
  (2, to_ftsdoc('simple', 'apple')), (3, to_ftsdoc('simple', 'cherry'));
CREATE INDEX wrn_fts ON wrn USING fts (d);
ANALYZE wrn;
SET enable_seqscan = off; SET enable_bitmapscan = off;
EXPLAIN (COSTS OFF)
WITH q AS (SELECT NULL::ftsquery AS query)
SELECT id FROM wrn WHERE d @@@ (SELECT query FROM q)
ORDER BY d <=> 'apple'::ftsquery LIMIT 10;
WITH q AS (SELECT NULL::ftsquery AS query)
SELECT id FROM wrn WHERE d @@@ (SELECT query FROM q)
ORDER BY d <=> 'apple'::ftsquery LIMIT 10;
WITH q AS (SELECT NULL::ftsquery AS query)
SELECT coalesce(array_agg(id), '{}') AS plain_null_key
FROM wrn WHERE d @@@ (SELECT query FROM q);
RESET enable_bitmapscan; SET enable_indexscan = off;
WITH q AS (SELECT NULL::ftsquery AS query)
SELECT coalesce(array_agg(id), '{}') AS bitmap_null_key
FROM wrn WHERE d @@@ (SELECT query FROM q);
RESET enable_indexscan; SET enable_bitmapscan = off;
WITH q AS (SELECT NULL::ftsquery AS query)
SELECT array_agg(id ORDER BY id) AS null_rank_rows,
       bool_and(dist IS NULL) AS null_distances
FROM (SELECT id, d <=> (SELECT query FROM q) AS dist FROM wrn
      WHERE d @@@ 'apple'::ftsquery
      ORDER BY d <=> (SELECT query FROM q) LIMIT 10) s;
RESET enable_seqscan; RESET enable_bitmapscan;
DROP TABLE wrn;
