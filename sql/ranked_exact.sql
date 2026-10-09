-- ranked_exact: every ranked traversal must return the same top-k.
--
-- References: single-term queries are checked against exhaustive scoring
-- (fts_search_dense1 via pg_fts.dense_score_min_df = 1), which scores every
-- posting; multi-term queries are checked against the same query evaluated as
-- an exhaustive sum of single-term score lists (the dense reference per term,
-- summed in SQL), which is how BM25 combines terms.  The heap-side fts_bm25 is
-- not a reference here: it uses each document's exact length, while the index
-- scores with the length quantization its on-disk format stores.
--
-- 1.11.0 fixed MaxScore (four or more terms), which could return none of the
-- true top-k: the corpus below makes a 4-term OR's best documents score mostly
-- on the LOW-impact terms, the shape the old essential/non-essential split
-- missed.  Also covered: best-first single-term top-k (1.11.0) and the
-- block-max WAND skip.
SET client_min_messages = warning;
SET enable_seqscan = off;
SET enable_bitmapscan = off;
-- single-term scores of every matching row, exhaustively (dense path).  The
-- settings are the function's own SET clause, restored on return: a SET LOCAL
-- in the body would last to the end of the CALLER's transaction and silently
-- turn best-first off for the index query being checked.
CREATE FUNCTION rx_term(t text, idx text DEFAULT 'rx_fts') RETURNS TABLE (tid tid, s float8)
LANGUAGE sql SET pg_fts.bestfirst = off SET pg_fts.dense_score_min_df = 1 AS $$
  SELECT f.ctid, f.score FROM fts_search(idx::regclass, to_ftsquery('simple', t), 100000) f $$;

CREATE TABLE rx (id int PRIMARY KEY, d ftsdoc);
INSERT INTO rx SELECT g, to_ftsdoc('simple',
  CASE WHEN g <= 60 THEN repeat('a ', 20 + g % 7) || repeat('b ', 15 + g % 5)
       WHEN g <= 120 THEN 'c d ' || repeat('x ', g % 9)
       ELSE (CASE WHEN g % 2 = 0 THEN 'a ' ELSE '' END) ||
            (CASE WHEN g % 3 = 0 THEN 'b ' ELSE '' END) ||
            (CASE WHEN g % 97 = 0 THEN 'c ' ELSE '' END) ||
            (CASE WHEN g % 89 = 0 THEN 'd ' ELSE '' END) ||
            repeat('f' || (g % 11) || ' ', 1 + g % 13) END)
FROM generate_series(1, 6000) g;
-- plus the 1.10.0 MaxScore failure shape.  The old split ended the scan as soon
-- as the top-k threshold exceeded the sum of every term's maximum contribution
-- except the lowest one's.  Long background documents (y x 300) push avgdl up,
-- so short early documents holding p q r s nine times each score close to the
-- maximum and lift the threshold past that sum; later documents with tf 20
-- score higher still and are the true top-k, which the old code never reached.
-- 250 of each: the ranked scan over-fetches 4k candidates, so the shape must
-- survive k = 50 -> 200.
INSERT INTO rx SELECT 10000 + g, to_ftsdoc('simple', repeat('p q r s ', 9))
FROM generate_series(1, 250) g;
INSERT INTO rx SELECT 11000 + g, to_ftsdoc('simple',
  (CASE WHEN g % 2 = 0 THEN 'p ' ELSE '' END) || (CASE WHEN g % 3 = 0 THEN 'q ' ELSE '' END) ||
  (CASE WHEN g % 2 = 1 THEN 'r ' ELSE '' END) || (CASE WHEN g % 3 = 1 THEN 's ' ELSE '' END) ||
  repeat('y ', 300))
FROM generate_series(1, 3000) g;
INSERT INTO rx SELECT 20000 + g, to_ftsdoc('simple', repeat('p q r s ', 20))
FROM generate_series(1, 250) g;
-- plus a conjunctive shape for 'm & n' on a fresh table (rxc), so docids
-- follow insert order.  m (df 256) is the rarer term and drives the walk: two
-- posting blocks, rows 1-128 and 129-256.  n (df 472) has one block spanning
-- both (odd rows 1-253, then row 300) and more blocks after.  The second m
-- block has the higher bound (m x3) and is visited first, leaving n's cursor
-- inside its first block but past m block 1's range; m block 1 holds the rest
-- of the top-72, which a cursor that is not rewound never sees.
CREATE TABLE rxc (id int PRIMARY KEY, d ftsdoc);
INSERT INTO rxc SELECT i, to_ftsdoc('simple',
  CASE WHEN i <= 128 THEN 'm' WHEN i <= 256 THEN 'm m m' ELSE 'z' END ||
  CASE WHEN (i <= 253 AND i % 2 = 1) OR i = 300 OR i > 300 THEN ' n' ELSE '' END)
FROM generate_series(1, 644) i;
CREATE INDEX rxc_fts ON rxc USING fts (d);
VACUUM ANALYZE rxc;
SELECT fts_index_df('rxc_fts', to_ftsquery('simple', 'm & n')) AS rxc_df;
CREATE TEMP TABLE rxc_ref AS
  SELECT x.tid, sum(x.s) s FROM unnest(ARRAY['m','n']) t, LATERAL rx_term(t, 'rxc_fts') x
  WHERE x.tid IN (SELECT ctid FROM rxc WHERE d @@@ to_ftsquery('simple', 'm & n'))
  GROUP BY x.tid;
SELECT k, (SELECT array_agg(s ORDER BY s DESC) FROM (SELECT round(s::numeric, 9) s FROM rxc_ref ORDER BY s DESC LIMIT k) r)
        = (SELECT array_agg(round(sc::numeric, 9) ORDER BY n) FROM
             (SELECT row_number() OVER () n, x.score sc
              FROM fts_search('rxc_fts', to_ftsquery('simple', 'm & n'), k) x) i) AS m_and_n_exact
FROM unnest(ARRAY[1, 8, 63, 72, 100]) k ORDER BY k;
DROP TABLE rxc_ref;
DROP TABLE rxc;

-- the overlap bound: in rxo, m (df 256, every 10th row of 2560) drives; n
-- (every even row, ten blocks) has its highest-tf documents (n x3, rows
-- 770-1024) in its FOURTH block, inside the first m block's docid range, while
-- that range's first n block holds long documents (low bound).  The first m
-- block's bound must take the maximum over every n block it overlaps; using
-- only the first one ranks it below the second m block, whose best document
-- then sets a threshold that wrongly prunes the true top documents.
CREATE TABLE rxo (id int PRIMARY KEY, d ftsdoc);
INSERT INTO rxo SELECT i, to_ftsdoc('simple', concat_ws(' ',
  CASE WHEN i % 10 = 0 THEN 'm' END,
  CASE WHEN i % 2 = 0 THEN repeat('n ', CASE WHEN i BETWEEN 770 AND 1024 THEN 3 WHEN i > 1280 THEN 2 ELSE 1 END) END,
  CASE WHEN i <= 256 AND i % 2 = 0 THEN repeat('z ', 10) WHEN i % 2 = 1 AND i % 10 <> 0 THEN 'z' END))
FROM generate_series(1, 2560) i;
CREATE INDEX rxo_fts ON rxo USING fts (d);
VACUUM ANALYZE rxo;
SELECT fts_index_df('rxo_fts', to_ftsquery('simple', 'm & n')) AS rxo_df;
CREATE TEMP TABLE rxo_ref AS
  SELECT x.tid, sum(x.s) s FROM unnest(ARRAY['m','n']) t, LATERAL rx_term(t, 'rxo_fts') x
  WHERE x.tid IN (SELECT ctid FROM rxo WHERE d @@@ to_ftsquery('simple', 'm & n'))
  GROUP BY x.tid;
SELECT k, (SELECT array_agg(s ORDER BY s DESC) FROM (SELECT round(s::numeric, 9) s FROM rxo_ref ORDER BY s DESC LIMIT k) r)
        = (SELECT array_agg(round(sc::numeric, 9) ORDER BY n) FROM
             (SELECT row_number() OVER () n, x.score sc
              FROM fts_search('rxo_fts', to_ftsquery('simple', 'm & n'), k) x) i) AS overlap_exact
FROM unnest(ARRAY[1, 5, 26]) k ORDER BY k;
DROP TABLE rxo_ref;
DROP TABLE rxo;
CREATE INDEX rx_fts ON rx USING fts (d);
VACUUM ANALYZE rx;

-- reference top-k for an OR of terms: sum of per-term exhaustive scores,
-- ties by TID (the order every ranked path uses)
CREATE FUNCTION rx_ref(terms text[], k int) RETURNS TABLE (n bigint, tid tid, s float8) LANGUAGE sql AS $$
  SELECT row_number() OVER (ORDER BY s DESC, tid), tid, s
  FROM (SELECT tid, sum(s) s FROM unnest(terms) t, LATERAL rx_term(t)
        GROUP BY tid ORDER BY sum(s) DESC, tid LIMIT k) x $$;
CREATE FUNCTION rx_idx(qs text, k int) RETURNS TABLE (n bigint, tid tid) LANGUAGE sql AS $$
  SELECT row_number() OVER (), ctid
  FROM (SELECT ctid FROM rx WHERE d @@@ to_ftsquery('simple', qs)
        ORDER BY d <=> to_ftsquery('simple', qs) LIMIT k) x $$;
-- the index's k rows must match the reference rank by rank: the same TID, or
-- a TID whose reference score equals the reference score at that rank within
-- 1e-9 (an equal-score reorder: float sums depend on addition order)
CREATE FUNCTION rx_same(terms text[]) RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE k int; nbad int; nidx int; nref int;
BEGIN
  FOREACH k IN ARRAY ARRAY[1, 3, 10, 50] LOOP
    CREATE TEMP TABLE all_s AS
      SELECT tid, sum(s) s FROM unnest(terms) t, LATERAL rx_term(t) GROUP BY tid;
    SELECT count(*) INTO nidx FROM rx_idx(array_to_string(terms, ' | '), k);
    SELECT count(*) INTO nref FROM rx_ref(terms, k);
    SELECT count(*) INTO nbad
    FROM rx_idx(array_to_string(terms, ' | '), k) i
    JOIN rx_ref(terms, k) r USING (n)
    LEFT JOIN all_s a ON a.tid = i.tid
    WHERE i.tid <> r.tid AND (a.s IS NULL OR abs(a.s - r.s) > 1e-9);
    DROP TABLE all_s;
    IF nidx = 0 OR nidx <> nref OR nbad > 0 THEN
      RETURN false;
    END IF;
  END LOOP;
  RETURN true;
END $$;

SELECT array_to_string(terms, ' | ') AS q, rx_same(terms) AS exact
FROM (VALUES (ARRAY['a']), (ARRAY['c']), (ARRAY['f3']), (ARRAY['a','c']), (ARRAY['a','b']),
             (ARRAY['c','d']), (ARRAY['a','b','c']), (ARRAY['a','b','c','d']),
             (ARRAY['f1','f2','f3','f4','f5']), (ARRAY['a','b','c','d','f1','f2']),
             (ARRAY['p','q','r','s']), (ARRAY['p','q','r']), (ARRAY['p','q','r','s','a'])) v(terms)
ORDER BY 1;

-- the reference must not leak its settings into the query under test
SELECT count(*) > 0 AS ref_ran, current_setting('pg_fts.bestfirst') AS bestfirst_after,
       current_setting('pg_fts.dense_score_min_df') AS dense_after
FROM rx_term('a');

-- single term through each route: best-first, docid-order WAND, dense
SELECT rx_same(ARRAY['a']) AS a_bestfirst_eq_dense;
SET pg_fts.bestfirst = off;
SET pg_fts.dense_score_min_df = 0;
SELECT rx_same(ARRAY['a']) AS a_wand_eq_dense;
RESET pg_fts.dense_score_min_df;
RESET pg_fts.bestfirst;

-- conjunctive best-first (AND, phrase): the reference is the exhaustive sum
-- over the documents @@@ admits, scored per term like rx_ref
CREATE FUNCTION rx_and_same(qs text, terms text[]) RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE k int; nbad int; nidx int; nref int;
BEGIN
  CREATE TEMP TABLE all_s AS
    SELECT x.tid, sum(x.s) s FROM unnest(terms) t, LATERAL rx_term(t) x
    WHERE x.tid IN (SELECT ctid FROM rx WHERE d @@@ to_ftsquery('simple', qs))
    GROUP BY x.tid;
  FOREACH k IN ARRAY ARRAY[1, 3, 10, 50] LOOP
    SELECT count(*) INTO nidx FROM rx_idx(qs, k);
    SELECT count(*) INTO nref FROM (SELECT 1 FROM all_s LIMIT k) z;
    SELECT count(*) INTO nbad
    FROM rx_idx(qs, k) i
    JOIN (SELECT row_number() OVER (ORDER BY s DESC, tid) n, tid, s FROM all_s) r USING (n)
    LEFT JOIN all_s a ON a.tid = i.tid
    WHERE i.tid <> r.tid AND (a.s IS NULL OR abs(a.s - r.s) > 1e-9);
    IF nidx = 0 OR nidx <> nref OR nbad > 0 THEN
      DROP TABLE all_s;
      RETURN false;
    END IF;
  END LOOP;
  DROP TABLE all_s;
  RETURN true;
END $$;
SELECT qs, rx_and_same(qs, terms) AS exact_and
FROM (VALUES ('a & b', ARRAY['a','b']), ('a & c', ARRAY['a','c']), ('c & d', ARRAY['c','d']),
             ('p & q & r & s', ARRAY['p','q','r','s']), ('a & b & f3', ARRAY['a','b','f3']),
             ('p & q & r', ARRAY['p','q','r'])) v(qs, terms)
ORDER BY qs;

-- term:LABEL is a zone restriction the index cannot see: the ranked path must
-- return only matching rows (before 1.11.0 it returned every row holding the
-- term, labelled or not)
CREATE TABLE rxw (id int, d ftsdoc);
INSERT INTO rxw SELECT g, CASE WHEN g % 2 = 0
   THEN to_ftsdoc('simple', 'alpha', 'A') || to_ftsdoc('simple', 'beta gamma', 'C')
   ELSE to_ftsdoc('simple', 'alpha beta', 'C') END FROM generate_series(1, 200) g;
CREATE INDEX rxw_fts ON rxw USING fts (d) WITH (positions = on);
VACUUM rxw;
SELECT q, (SELECT count(*) FROM rxw WHERE d @@@ to_ftsquery('simple', q)) AS matches,
       (SELECT count(*) FROM (SELECT id FROM rxw WHERE d @@@ to_ftsquery('simple', q)
                              ORDER BY d <=> to_ftsquery('simple', q) LIMIT 150) s) AS ranked,
       (SELECT count(*) FROM (SELECT d FROM rxw WHERE d @@@ to_ftsquery('simple', q)
                              ORDER BY d <=> to_ftsquery('simple', q) LIMIT 150) s
        WHERE NOT fts_match(d, to_ftsquery('simple', q))) AS ranked_nonmatching
FROM unnest(ARRAY['alpha:A', 'alpha:A & beta', 'alpha:A | zzz', 'alpha:C']) q
ORDER BY q;

-- phrase on the conjunctive walk: rows holding both words in the wrong order
-- score HIGHER (repeated terms, short) than the true phrase matches, so a walk
-- that skipped the adjacency check would return them
CREATE TABLE rxp (id int PRIMARY KEY, d ftsdoc);
INSERT INTO rxp SELECT i, to_ftsdoc('simple', CASE
    WHEN i % 3 = 0 THEN 'hot dog stand ' || repeat('x ', 1 + i % 7)
    WHEN i % 3 = 1 THEN 'dog dog hot hot'
    ELSE 'cat ' || repeat('y ', i % 5) END)
FROM generate_series(1, 900) i;
CREATE INDEX rxp_fts ON rxp USING fts (d) WITH (positions = on);
VACUUM ANALYZE rxp;
SELECT k,
  (SELECT count(*) FROM (SELECT d FROM rxp WHERE d @@@ to_ftsquery('simple', '"hot dog"')
                         ORDER BY d <=> to_ftsquery('simple', '"hot dog"') LIMIT k) s
   WHERE NOT fts_match(d, to_ftsquery('simple', '"hot dog"'))) AS phrase_nonmatching,
  (SELECT count(*) FROM (SELECT d FROM rxp WHERE d @@@ to_ftsquery('simple', '"hot dog"')
                         ORDER BY d <=> to_ftsquery('simple', '"hot dog"') LIMIT k) s) AS phrase_rows
FROM unnest(ARRAY[1, 10, 300]) k ORDER BY k;
DROP TABLE rxp;
DROP TABLE rxw;

-- after deletes (tombstones) and a second segment
DELETE FROM rx WHERE id % 7 = 0;
VACUUM rx;
INSERT INTO rx SELECT g, to_ftsdoc('simple', 'c ' || repeat('a ', g % 30)) FROM generate_series(6001, 6600) g;
VACUUM rx;
SELECT fts_index_nsegments('rx_fts') AS nsegments;
SELECT array_to_string(terms, ' | ') AS q, rx_same(terms) AS exact_after_churn
FROM (VALUES (ARRAY['a']), (ARRAY['c']), (ARRAY['a','c']), (ARRAY['a','b','c','d'])) v(terms)
ORDER BY 1;
SELECT qs, rx_and_same(qs, terms) AS exact_and_after_churn
FROM (VALUES ('a & c', ARRAY['a','c']), ('c & d', ARRAY['c','d'])) v(qs, terms)
ORDER BY qs;

DROP FUNCTION rx_and_same(text, text[]);
DROP FUNCTION rx_same(text[]);
DROP FUNCTION rx_idx(text, int);
DROP FUNCTION rx_ref(text[], int);
DROP FUNCTION rx_term(text, text);
DROP TABLE rx;
