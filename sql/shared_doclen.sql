-- shared_doclen: the server-wide shared copy of a segment's document-length
-- array (1.10.0) must give scores identical to the per-backend copy and to the
-- page-directory cursor, for every document, across deletes, new segments,
-- merges, REINDEX and transactions that see different directories; and every
-- reference a scan takes must be released when it ends.
SET client_min_messages = warning;
SET enable_seqscan = off;
SET enable_bitmapscan = off;
CREATE TABLE sd (id int PRIMARY KEY, d ftsdoc);
INSERT INTO sd SELECT g, to_ftsdoc('simple', 'alpha ' || repeat('w' || (g % 13) || ' ', 1 + (g % 97)) ||
                                   CASE WHEN g % 3 = 0 THEN 'beta' ELSE 'gamma' END)
FROM generate_series(1, 4000) g;
CREATE INDEX sd_fts ON sd USING fts (d);
VACUUM ANALYZE sd;

-- scores for every matching doc, through the ordering scan, under a setting
CREATE FUNCTION sd_scores(q text, shared bool, mb int) RETURNS text LANGUAGE plpgsql AS $$
DECLARE r text;
BEGIN
  EXECUTE format('SET LOCAL pg_fts.shared_doclen = %s', shared);
  EXECUTE format('SET LOCAL pg_fts.doclen_cache_mb = %s', mb);
  EXECUTE format('SELECT string_agg(id::text || '':'' || round((1/(d <=> to_ftsquery(''simple'',%L)) - 1)::numeric, 12), '','')
                  FROM (SELECT id, d FROM sd WHERE d @@@ to_ftsquery(''simple'',%L)
                        ORDER BY d <=> to_ftsquery(''simple'',%L) LIMIT 5000) s', q, q, q) INTO r;
  RETURN r;
END $$;
CREATE FUNCTION sd_same(q text) RETURNS boolean LANGUAGE sql AS $$
  SELECT sd_scores(q, true, 64) = sd_scores(q, false, 64)
     AND sd_scores(q, true, 64) = sd_scores(q, false, 0)
     AND length(sd_scores(q, true, 64)) > 0 $$;
-- this database's index's published copies (relfilenumber changes on REINDEX)
CREATE FUNCTION sd_copies(OUT ready int, OUT held int, OUT retired int) LANGUAGE sql AS $$
  SELECT count(*) FILTER (WHERE state = 'ready')::int,
         coalesce(sum(refcnt), 0)::int,
         count(*) FILTER (WHERE s.retired)::int
  FROM fts_shared_doclen_stats() s
  WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
    AND relfilenumber = pg_relation_filenode('sd_fts') $$;

-- one segment: shared == private == cursor; a copy is published and, once the
-- statement is over, nobody holds it
SELECT sd_same('alpha') AS one_seg, sd_same('beta | w5') AS one_seg_or;
SELECT ready, held FROM sd_copies();

-- deletes: tombstones mask docs; the shared array is unchanged and still exact
DELETE FROM sd WHERE id % 7 = 0;
VACUUM sd;
SELECT sd_same('alpha') AS after_delete;

-- a second segment (VACUUM flushes the pending rows into a new segment): two
-- copies, both exact
INSERT INTO sd SELECT g, to_ftsdoc('simple', 'alpha delta ' || repeat('z ', g % 50)) FROM generate_series(4001, 6000) g;
VACUUM sd;
SELECT fts_index_nsegments('sd_fts') AS nsegments;
SELECT sd_same('alpha') AS two_segments, sd_same('delta') AS new_docs;
SELECT ready >= 2 AS copy_per_segment, held FROM sd_copies();

-- a reference lives as long as the SCAN (its portal), not the transaction: a
-- finished statement inside an open transaction holds nothing.  (Scans that
-- outlive a merge are covered by the open-cursor case below and by t/011.)
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT count(*) AS rr_before FROM (SELECT id FROM sd WHERE d @@@ to_ftsquery('simple','alpha')
  ORDER BY d <=> to_ftsquery('simple','alpha') LIMIT 10) s;
SELECT held AS held_after_statement FROM sd_copies();
COMMIT;
SELECT fts_merge('sd_fts') IS NOT NULL AS merged;
SELECT fts_index_nsegments('sd_fts') AS nsegments_after_merge;
SELECT sd_same('alpha') AS after_merge, sd_same('delta') AS after_merge_new;
-- the merged-away segments' copies are retired and freed; only live ones remain
SELECT ready AS ready_after_merge, held, retired FROM sd_copies();

-- an ERROR inside a scan still releases its reference
DO $$ BEGIN
  PERFORM count(*) FROM (SELECT id FROM sd WHERE d @@@ to_ftsquery('simple','alpha')
    ORDER BY d <=> to_ftsquery('simple','alpha') LIMIT 10) s WHERE 1/(id - id) = 0;
EXCEPTION WHEN division_by_zero THEN NULL; END $$;
SELECT held AS held_after_error FROM sd_copies();

-- a cursor left open holds its copies until it is closed
BEGIN;
DECLARE c CURSOR FOR SELECT id FROM sd WHERE d @@@ to_ftsquery('simple','alpha')
  ORDER BY d <=> to_ftsquery('simple','alpha');
FETCH 3 FROM c;
SELECT held > 0 AS held_by_open_cursor FROM sd_copies();
CLOSE c;
COMMIT;
SELECT held AS held_after_close FROM sd_copies();

-- REINDEX: new relfilenumber, new copies, same scores
REINDEX INDEX sd_fts;
SELECT sd_same('alpha') AS after_reindex;
SELECT ready >= 1 AS copies_for_new_relfilenode, held FROM sd_copies();

-- shared off: no shared copies taken, still exact
SET pg_fts.shared_doclen = off;
SELECT sd_scores('gamma', false, 64) = sd_scores('gamma', false, 0) AS shared_off_same;
RESET pg_fts.shared_doclen;

DROP FUNCTION sd_scores(text, bool, int);
DROP FUNCTION sd_same(text);
DROP FUNCTION sd_copies();
DROP TABLE sd;
