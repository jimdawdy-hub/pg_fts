-- Fixture registration only; not installed by the extension's base/upgrade SQL.
CREATE FUNCTION fts_search_subset(regclass, ftsquery, tid[], integer,
                                 OUT ctid tid, OUT score float8)
RETURNS SETOF record AS '$libdir/pg_fts', 'fts_search_subset'
LANGUAGE C STRICT VOLATILE PARALLEL UNSAFE;
CREATE FUNCTION fts_search_subset(regclass, ftsquery, tid[], integer, bigint[],
                                 OUT ctid tid, OUT score float8)
RETURNS SETOF record AS '$libdir/pg_fts', 'fts_search_subset'
LANGUAGE C STRICT VOLATILE PARALLEL UNSAFE;
CREATE FUNCTION fts_subset_prototype_stats() RETURNS jsonb
AS '$libdir/pg_fts', 'fts_subset_prototype_stats'
LANGUAGE C VOLATILE PARALLEL UNSAFE;
REVOKE ALL ON FUNCTION fts_search_subset(regclass, ftsquery, tid[], integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION fts_search_subset(regclass, ftsquery, tid[], integer, bigint[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION fts_subset_prototype_stats() FROM PUBLIC;
