-- wand_last_block: a WAND/BMW seek must never prove-skip a term's LAST posting
-- block by reading the header that follows it -- on a shared page that header
-- belongs to the NEXT term, and its first_docid says nothing about this one
-- (1.9.0).  The bug dropped the final postings of a term from ranked results
-- once the threshold was high enough to seek (small k).  Assert, for many
-- (query, k), that the scores of the top-k equal the first k scores of the SAME
-- engine's full ranking (k = every match, where nothing is skipped).  Using the
-- engine's own scores keeps the check exact under doclen quantization, which an
-- external fts_bm25 reference is not (it uses the unquantized length).
SET client_min_messages = warning;
SET enable_bitmapscan = off;
CREATE TABLE wl (id int PRIMARY KEY, d ftsdoc);
-- 'w3' has ~2 blocks; its tail block's docids lie ABOVE the first docid of the
-- term after it on the page ('w4'), which is what the bad skip compared against
INSERT INTO wl SELECT g, to_ftsdoc('simple', 'alpha ' || repeat('w' || (g % 9) || ' ', 1 + g % 41) ||
                                   CASE WHEN g % 4 = 0 THEN 'beta' ELSE '' END)
FROM generate_series(1, 2000) g;
CREATE INDEX wl_fts ON wl USING fts (d);
VACUUM ANALYZE wl;

CREATE FUNCTION wl_ok(q text, k int) RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE got float8[]; want float8[]; nall int;
BEGIN
  EXECUTE format('SELECT count(*) FROM wl WHERE d @@@ to_ftsquery(''simple'',%L)', q) INTO nall;
  EXECUTE format('SELECT array_agg(score ORDER BY score DESC) FROM fts_search(''wl_fts'', to_ftsquery(''simple'',%L), %s)', q, k) INTO got;
  EXECUTE format('SELECT (array_agg(score ORDER BY score DESC))[1:%s] FROM fts_search(''wl_fts'', to_ftsquery(''simple'',%L), %s)', k, q, nall) INTO want;
  RETURN nall >= k AND got = want;
END $$;

SELECT q, bool_and(wl_ok(q, k)) AS exact_topk
FROM (VALUES ('w3 | beta'), ('beta | w3'), ('w3 | w5'), ('w1 | w7 | beta'), ('w3'), ('beta')) qs(q),
     (VALUES (1), (2), (3), (5), (10), (25)) ks(k)
GROUP BY q ORDER BY q;

DROP FUNCTION wl_ok(text, int);
DROP TABLE wl;
