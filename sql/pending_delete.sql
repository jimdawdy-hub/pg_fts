-- pending_delete: a row inserted after the build (so it sits in the pending
-- list) and deleted before the next VACUUM must leave the index.  Before
-- 1.11.0, bulkdelete tombstoned only segment postings, then the cleanup-time
-- flush wrote the deleted pending rows into a segment that pointed at freed
-- heap slots: count(*) overcounted and a bitmap scan returned whatever row
-- later reused the slot (every release).
SET client_min_messages = warning;
CREATE TABLE pd (id bigint, d ftsdoc) WITH (fillfactor = 100, autovacuum_enabled = off);
INSERT INTO pd SELECT g, to_ftsdoc('simple', 'common w' || (g % 97)) FROM generate_series(1, 2000) g;
CREATE INDEX pd_fts ON pd USING fts (d);
VACUUM ANALYZE pd;
-- pending inserts, some of them deleted before the VACUUM that flushes them
INSERT INTO pd SELECT g, to_ftsdoc('simple', 'common new ' || g) FROM generate_series(2001, 2300) g;
DELETE FROM pd WHERE id > 2000 AND id % 3 = 0;
VACUUM pd;
-- reuse the freed heap slots with rows that do NOT contain the term
INSERT INTO pd SELECT g, to_ftsdoc('simple', 'other ' || g) FROM generate_series(3001, 3300) g;
SELECT (SELECT count(*) FROM pd WHERE fts_match(d, 'common'::ftsquery)) AS truth,
       (SELECT count(*) FROM pd WHERE d @@@ 'common'::ftsquery) AS count_pushdown,
       fts_count('pd_fts', 'common'::ftsquery) AS fts_count;
SET enable_seqscan = off;
SET enable_indexscan = off;
SELECT count(*) AS bitmap_rows, count(*) FILTER (WHERE id > 3000) AS bitmap_wrong_rows
FROM (SELECT id FROM pd WHERE d @@@ 'common'::ftsquery OFFSET 0) s;
RESET enable_indexscan;
SET enable_bitmapscan = off;
SELECT count(*) AS ranked_rows, count(*) FILTER (WHERE id > 3000) AS ranked_wrong_rows
FROM (SELECT id FROM pd WHERE d @@@ 'common'::ftsquery ORDER BY d <=> 'common'::ftsquery LIMIT 5000) s;
RESET enable_bitmapscan;
RESET enable_seqscan;
-- and the same after a second VACUUM and a merge
VACUUM pd;
SELECT fts_merge('pd_fts') IS NOT NULL AS merged;
SELECT (SELECT count(*) FROM pd WHERE fts_match(d, 'common'::ftsquery)) AS truth,
       (SELECT count(*) FROM pd WHERE d @@@ 'common'::ftsquery) AS count_pushdown;
DROP TABLE pd;
