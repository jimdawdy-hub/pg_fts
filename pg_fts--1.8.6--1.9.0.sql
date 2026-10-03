/* pg_fts 1.8.6 -> 1.9.0
 *
 * Ranked-retrieval performance release plus two exactness fixes; see CHANGELOG.
 *
 * SQL: adds the internal function fts_current_distance(), which the planner hook
 * substitutes for the sort-key copy of an ordering scan's own <=> expression.
 * Without it (an index upgraded in C but not yet ALTER EXTENSION ... UPDATE'd)
 * the hook simply skips that optimisation; nothing else depends on it.
 *
 * No on-disk format change (BM25_VERSION unchanged): no REINDEX required.  The
 * idf fix changes scores on indexes with tombstones (it makes them equal the
 * heap-side fts_bm25 scores); no stored data changes.
 */
CREATE FUNCTION fts_current_distance()
RETURNS float8
AS 'MODULE_PATHNAME', 'fts_current_distance'
LANGUAGE C VOLATILE PARALLEL RESTRICTED;
