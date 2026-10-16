\set ON_ERROR_STOP on
SET jit=off;
SET statement_timeout='15s';
SET enable_indexscan=off;
SET enable_indexonlyscan=off;
SET enable_bitmapscan=off;
CREATE EXTENSION pg_fts;
\i /src/sql/subset_prototype.sql
CREATE TABLE subset_docs(id bigint PRIMARY KEY, body text, note text DEFAULT '') WITH(fillfactor=50,autovacuum_enabled=false);
INSERT INTO subset_docs(id,body)
SELECT 5000-g, repeat('apple ',1+g%7) || repeat('pear ',g%3) || repeat('filler ',8+g%130)
FROM generate_series(1,1200) g;
CREATE INDEX subset_fts ON subset_docs USING fts(to_ftsdoc('simple',body));
INSERT INTO subset_docs(id,body)
SELECT 5000-g, repeat('apple ',1+g%7) || repeat('pear ',g%3) || repeat('filler ',8+g%130)
FROM generate_series(1201,1800) g;
VACUUM ANALYZE subset_docs;
CREATE TEMP TABLE subset_roots AS SELECT id,ctid AS root_tid FROM subset_docs;
DO $$BEGIN
 IF fts_index_nsegments('subset_fts') < 2 THEN RAISE EXCEPTION 'fixture needs multiple segments'; END IF;
END$$;
CREATE FUNCTION check_subset(label text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
 query_text text; q ftsquery; wanted integer; actual_ids bigint[]; expected_ids bigint[];
 allowed tid[]; tie_keys bigint[]; debug jsonb; bad integer;
BEGIN
 FOR query_text IN SELECT unnest(ARRAY['apple','apple & pear','apple | absent','absent','apple & (pear | filler)']) LOOP
  q:=query_text::ftsquery;
  SELECT array_agg(ctid ORDER BY id),array_agg(id ORDER BY id) INTO allowed,tie_keys
  FROM subset_docs WHERE id%7=0;
  IF cardinality(allowed)<100 THEN RAISE EXCEPTION 'degenerate allowlist'; END IF;
  -- Independent heap match set, separate from the native ranked oracle.
  SELECT count(*) INTO bad FROM (
   (SELECT d.id FROM subset_docs d JOIN fts_search_subset('subset_fts',q,allowed,2500) f ON d.ctid=f.ctid
    EXCEPT SELECT id FROM subset_docs WHERE id%7=0 AND to_ftsdoc('simple',body) @@@ q)
   UNION ALL
   (SELECT id FROM subset_docs WHERE id%7=0 AND to_ftsdoc('simple',body) @@@ q
    EXCEPT SELECT d.id FROM subset_docs d JOIN fts_search_subset('subset_fts',q,allowed,2500) f ON d.ctid=f.ctid)
  ) difference;
  IF bad<>0 THEN RAISE EXCEPTION '% membership %',label,query_text; END IF;
  FOR wanted IN SELECT unnest(ARRAY[1,7,400,2500]) LOOP
   SELECT array_agg(d.id ORDER BY f.score DESC,r.root_tid) INTO actual_ids
   FROM fts_search_subset('subset_fts',q,allowed,wanted) f JOIN subset_docs d ON d.ctid=f.ctid JOIN subset_roots r USING(id);
   SELECT array_agg(id ORDER BY score DESC,root_tid) INTO expected_ids FROM (
    SELECT r.id,f.score,r.root_tid FROM fts_search('subset_fts',q,5000) f JOIN subset_roots r ON r.root_tid=f.ctid
    WHERE r.id%7=0 ORDER BY f.score DESC,r.root_tid LIMIT wanted
   ) ranked;
   IF actual_ids IS DISTINCT FROM expected_ids THEN RAISE EXCEPTION '% native order %, k%',label,query_text,wanted; END IF;
   -- Native quantized scores, not scalar approximate scores.
   SELECT count(*) INTO bad
   FROM fts_search_subset('subset_fts',q,allowed,wanted) a JOIN subset_docs d ON d.ctid=a.ctid JOIN subset_roots r USING(id)
   JOIN fts_search('subset_fts',q,5000) b ON b.ctid=r.root_tid WHERE a.score<>b.score;
   IF bad<>0 THEN RAISE EXCEPTION '% native score %',label,query_text; END IF;
   -- The fifth argument preserves the application's opinion-id cutoff order.
   SELECT array_agg(d.id ORDER BY f.score DESC,d.id) INTO actual_ids
   FROM fts_search_subset('subset_fts',q,allowed,wanted,tie_keys) f JOIN subset_docs d ON d.ctid=f.ctid;
   SELECT array_agg(id ORDER BY score DESC,id) INTO expected_ids FROM (
    SELECT r.id,f.score FROM fts_search('subset_fts',q,5000) f JOIN subset_roots r ON r.root_tid=f.ctid
    WHERE r.id%7=0 ORDER BY f.score DESC,r.id LIMIT wanted
   ) ranked;
   IF actual_ids IS DISTINCT FROM expected_ids THEN RAISE EXCEPTION '% opinion-id order %, k%',label,query_text,wanted; END IF;
  END LOOP;
 END LOOP;
 PERFORM count(*) FROM fts_search_subset('subset_fts','apple',allowed,7);
 debug:=fts_subset_prototype_stats();
 IF (debug->>'allowed')::int<>cardinality(allowed) OR (debug->>'scored')::int<>cardinality(allowed)
    OR (debug->>'contributions')::int<>cardinality(allowed) THEN RAISE EXCEPTION 'work boundary %',debug; END IF;
 -- Identical input pairs are deduplicated, not counted as extra matches.
 IF (SELECT count(*) FROM fts_search_subset('subset_fts','apple',allowed||allowed,2500))<>cardinality(allowed)
 THEN RAISE EXCEPTION 'duplicate input'; END IF;
 RAISE NOTICE 'PASS %: exact membership, native scores/ties, opinion-id cutoff, allowed-only work, duplicate input',label;
END$$;
SELECT check_subset('two segments');
-- Updating an unindexed field must move some rows within HOT chains.
UPDATE subset_docs SET note='changed' WHERE id%7=0;
DO $$BEGIN
 IF NOT EXISTS(SELECT 1 FROM subset_docs d JOIN subset_roots r USING(id) WHERE d.ctid<>r.root_tid)
 THEN RAISE EXCEPTION 'HOT control did not change visible ctid'; END IF;
END$$;
SELECT check_subset('HOT child');
VACUUM subset_docs;
SELECT check_subset('pruned HOT root');
DELETE FROM subset_docs WHERE id%11=0;
DELETE FROM subset_roots WHERE id%11=0;
VACUUM subset_docs;
SELECT check_subset('deletions');
DO $$DECLARE a tid[]; BEGIN
 SELECT array_agg(ctid) INTO a FROM subset_docs WHERE id%7=0;
 IF (SELECT count(*) FROM fts_search_subset('subset_fts','apple','{}'::tid[],7))<>0
 OR (SELECT count(*) FROM fts_search_subset('subset_fts','apple',NULL::tid[],7))<>0
 THEN RAISE EXCEPTION 'empty/NULL became unrestricted'; END IF;
 BEGIN PERFORM count(*) FROM fts_search_subset('subset_fts','apple & !pear',a,7); RAISE EXCEPTION 'NOT accepted'; EXCEPTION WHEN feature_not_supported THEN NULL; END;
 BEGIN PERFORM count(*) FROM fts_search_subset('subset_fts','"apple pear"',a,7); RAISE EXCEPTION 'phrase accepted'; EXCEPTION WHEN feature_not_supported THEN NULL; END;
 BEGIN PERFORM count(*) FROM fts_search_subset('subset_fts','app*',a,7); RAISE EXCEPTION 'prefix accepted'; EXCEPTION WHEN feature_not_supported THEN NULL; END;
 BEGIN PERFORM count(*) FROM fts_search_subset('subset_fts','apple',a,0); RAISE EXCEPTION 'k0 accepted'; EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
 BEGIN PERFORM count(*) FROM fts_search_subset('subset_fts','apple',a,1,ARRAY[1::bigint]); RAISE EXCEPTION 'key mismatch accepted'; EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
 BEGIN PERFORM count(*) FROM fts_search_subset('subset_fts','apple',ARRAY[a[1],a[1]],1,ARRAY[1::bigint,2::bigint]); RAISE EXCEPTION 'conflicting keys accepted'; EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
 RAISE NOTICE 'PASS empty, NULL, unsupported shapes, parameter guards';
END$$;
INSERT INTO subset_docs VALUES(99999,'apple pear pending','');
DO $$BEGIN
 BEGIN
  PERFORM count(*) FROM fts_search_subset('subset_fts','apple',ARRAY(SELECT ctid FROM subset_docs),7);
  RAISE EXCEPTION 'pending silently omitted';
 EXCEPTION WHEN feature_not_supported THEN NULL; END;
 RAISE NOTICE 'PASS pending refuses explicitly';
END$$;
VACUUM ANALYZE subset_docs;
INSERT INTO subset_roots SELECT id,ctid FROM subset_docs WHERE id=99999;
SELECT check_subset('post pending flush');
-- Deliberately reverse logical IDs versus physical order at an all-tied cutoff.
CREATE TABLE subset_ties(id bigint,body text);
INSERT INTO subset_ties SELECT 51-g,'apple pear' FROM generate_series(1,50) g;
CREATE INDEX subset_ties_fts ON subset_ties USING fts(to_ftsdoc('simple',body));
DO $$DECLARE a tid[]; keys bigint[]; native_ids bigint[]; keyed_ids bigint[]; BEGIN
 SELECT array_agg(ctid ORDER BY id),array_agg(id ORDER BY id) INTO a,keys FROM subset_ties;
 SELECT array_agg(t.id ORDER BY t.id) INTO native_ids
 FROM fts_search_subset('subset_ties_fts','apple',a,7) f JOIN subset_ties t ON t.ctid=f.ctid;
 SELECT array_agg(t.id ORDER BY t.id) INTO keyed_ids
 FROM fts_search_subset('subset_ties_fts','apple',a,7,keys) f JOIN subset_ties t ON t.ctid=f.ctid;
 IF native_ids<>ARRAY[44,45,46,47,48,49,50]::bigint[] OR keyed_ids<>ARRAY[1,2,3,4,5,6,7]::bigint[]
 THEN RAISE EXCEPTION 'cutoff tie contract native%, keyed%',native_ids,keyed_ids; END IF;
 RAISE NOTICE 'PASS adversarial all-tied native versus opinion-id cutoff';
END$$;
-- Actual calling role must have heap SELECT; RLS must not be bypassed.
CREATE ROLE subset_reader;
GRANT EXECUTE ON FUNCTION fts_search_subset(regclass,ftsquery,tid[],integer) TO subset_reader;
SET ROLE subset_reader;
DO $$BEGIN
 BEGIN PERFORM count(*) FROM fts_search_subset('subset_fts','apple',ARRAY['(0,1)'::tid],1); RAISE EXCEPTION 'missing heap SELECT accepted'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END$$;
RESET ROLE;
GRANT SELECT ON subset_docs TO subset_reader;
ALTER TABLE subset_docs ENABLE ROW LEVEL SECURITY;
SET ROLE subset_reader;
DO $$BEGIN
 BEGIN PERFORM count(*) FROM fts_search_subset('subset_fts','apple',ARRAY['(0,1)'::tid],1); RAISE EXCEPTION 'RLS bypassed'; EXCEPTION WHEN feature_not_supported THEN NULL; END;
END$$;
RESET ROLE;
SELECT 'PASS ACL/RLS guard; all subset prototype checks complete' AS result;
