CREATE EXTENSION IF NOT EXISTS pg_fts;
DROP TABLE IF EXISTS wt;
CREATE TABLE wt (id int, d ftsdoc);
INSERT INTO wt SELECT g, CASE WHEN g % 2 = 0
   THEN to_ftsdoc('simple', 'alpha', 'A') || to_ftsdoc('simple', 'beta gamma', 'C')
   ELSE to_ftsdoc('simple', 'alpha beta', 'C') END FROM generate_series(1, 200) g;
CREATE INDEX wt_fts ON wt USING fts (d) WITH (positions = on);
VACUUM wt;
SET enable_seqscan = off; SET enable_bitmapscan = off;
SELECT 'match count', count(*) FROM wt WHERE d @@@ to_ftsquery('simple', 'alpha:A & beta');
SELECT 'ranked rows', count(*), count(*) FILTER (WHERE id % 2 = 1) AS wrong FROM (SELECT id FROM wt WHERE d @@@ to_ftsquery('simple', 'alpha:A & beta') ORDER BY d <=> to_ftsquery('simple', 'alpha:A & beta') LIMIT 150) s;
SET pg_fts.bestfirst = off;
SELECT 'ranked rows bf=off', count(*), count(*) FILTER (WHERE id % 2 = 1) AS wrong FROM (SELECT id FROM wt WHERE d @@@ to_ftsquery('simple', 'alpha:A & beta') ORDER BY d <=> to_ftsquery('simple', 'alpha:A & beta') LIMIT 150) s;
