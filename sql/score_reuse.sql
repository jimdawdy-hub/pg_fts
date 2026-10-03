-- score_reuse: the planner replaces the RESJUNK (sort-key-only) copy of an
-- ordering scan's own `d <=> q` with fts_current_distance() (1.9.0), so a ranked
-- query does not re-read and re-score every returned document.  User-visible
-- values must not change: a projected `d <=> q` keeps fts_distance().  Results
-- and their order must equal the unsubstituted plan in every shape where the
-- scan is re-driven: plain, nested-loop inner side (rescan), two ordering scans,
-- and a cursor fetched row by row.
SET client_min_messages = warning;
SET enable_seqscan = off;
SET enable_bitmapscan = off;
CREATE TABLE sr (id int PRIMARY KEY, d ftsdoc);
INSERT INTO sr SELECT g, to_ftsdoc('simple', 'alpha ' || repeat('w' || (g % 9) || ' ', 1 + g % 41) ||
                                   CASE WHEN g % 4 = 0 THEN 'beta' ELSE '' END)
FROM generate_series(1, 2000) g;
CREATE INDEX sr_fts ON sr USING fts (d);
VACUUM ANALYZE sr;

-- the sort-key copy is substituted; a projected copy is NOT
EXPLAIN (VERBOSE, COSTS OFF)
SELECT id FROM sr WHERE d @@@ to_ftsquery('simple','alpha')
ORDER BY d <=> to_ftsquery('simple','alpha') LIMIT 3;
EXPLAIN (VERBOSE, COSTS OFF)
SELECT id, d <=> to_ftsquery('simple','alpha') AS dist FROM sr WHERE d @@@ to_ftsquery('simple','alpha')
ORDER BY d <=> to_ftsquery('simple','alpha') LIMIT 3;

-- the visible value is fts_distance() exactly, row for row
SELECT count(*) FILTER (WHERE dist IS DISTINCT FROM fts_distance(d, to_ftsquery('simple','alpha'))) AS visible_value_changed
FROM (SELECT d, d <=> to_ftsquery('simple','alpha') AS dist FROM sr WHERE d @@@ to_ftsquery('simple','alpha')
      ORDER BY d <=> to_ftsquery('simple','alpha') LIMIT 500) s;

-- the substituted scan returns a correct top-k against an INDEPENDENT reference
-- (seqscan + fts_bm25 with the index's own N/avgdl/df) under parity_check.sh's
-- rule: no returned doc scores below the reference k-th score by more than the
-- 1% doclen-quantization tolerance.
CREATE FUNCTION sr_same(lim int, q text) RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE n float8; a float8; kth float8; bad int; sc text;
BEGIN
  SELECT count(*), avg(ftsdoc_length(d))::float8 INTO n, a FROM sr;
  sc := format('fts_bm25(d, to_ftsquery(''simple'',%L), %s, %s, fts_index_df(''sr_fts'', to_ftsquery(''simple'',%L)))', q, n, a, q);
  EXECUTE format('SELECT min(s) FROM (SELECT %s s FROM sr WHERE d @@@ to_ftsquery(''simple'',%L) ORDER BY 1 DESC LIMIT %s) z',
                 sc, q, lim) INTO kth;
  EXECUTE format('SELECT count(*) FROM (SELECT %s s FROM sr WHERE d @@@ to_ftsquery(''simple'',%L)
                  ORDER BY d <=> to_ftsquery(''simple'',%L) LIMIT %s) z WHERE s < %s * 0.99 - 1e-9',
                 sc, q, q, lim, kth) INTO bad;
  RETURN bad = 0 AND kth > 0;
END $$;
SELECT sr_same(1, 'alpha') AND sr_same(10, 'alpha') AND sr_same(500, 'alpha')
   AND sr_same(10, 'beta') AND sr_same(10, 'w3 | beta') AS order_matches_reference;

-- nested loop: the inner ordering scan is rescanned per outer row
SET enable_hashjoin = off; SET enable_mergejoin = off; SET enable_material = off;
SELECT count(*) AS lateral_rows,
       count(*) FILTER (WHERE x.ids IS DISTINCT FROM y.ids) AS lateral_mismatches
FROM generate_series(1, 5) o(n),
LATERAL (SELECT array_agg(id) ids FROM (SELECT id FROM sr WHERE d @@@ to_ftsquery('simple','w' || (o.n % 9))
         ORDER BY d <=> to_ftsquery('simple','w' || (o.n % 9)) LIMIT 7) i) x,
LATERAL (SELECT array_agg(id) ids FROM (SELECT id FROM (SELECT id, row_number() OVER () r FROM
           (SELECT id FROM sr WHERE d @@@ to_ftsquery('simple','w' || (o.n % 9))
            ORDER BY d <=> to_ftsquery('simple','w' || (o.n % 9))) a) b WHERE r <= 7) i) y;
RESET enable_hashjoin; RESET enable_mergejoin; RESET enable_material;

-- cursor over a substituted plan, fetched row by row
BEGIN;
DECLARE c CURSOR FOR SELECT id FROM sr WHERE d @@@ to_ftsquery('simple','alpha')
  ORDER BY d <=> to_ftsquery('simple','alpha') LIMIT 50;
CREATE TEMP TABLE sr_c (r serial, id int);
DO $$ DECLARE v int; cur refcursor := 'c'; BEGIN
  LOOP FETCH NEXT FROM cur INTO v; EXIT WHEN NOT FOUND; INSERT INTO sr_c(id) VALUES (v); END LOOP; END $$;
COMMIT;
SELECT count(*) AS cursor_rows,
       (SELECT array_agg(id ORDER BY r) FROM sr_c) =
       (SELECT array_agg(id) FROM (SELECT id FROM sr WHERE d @@@ to_ftsquery('simple','alpha')
                                   ORDER BY d <=> to_ftsquery('simple','alpha') LIMIT 50) s) AS cursor_same
FROM sr_c;

DROP FUNCTION sr_same(int, text);
DROP TABLE sr;
