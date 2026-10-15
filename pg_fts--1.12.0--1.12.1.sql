/* pg_fts 1.12.0 -> 1.12.1
 *
 * No SQL-visible changes.  C-level correctness fixes in the index scan: NULL
 * scan arguments, a second WHERE key, WHERE queries that differ from the ORDER
 * BY query, and NOT / fuzzy operands that the boolean evaluator under-counted
 * (GitHub #8, #9, #10).
 *
 * No on-disk format change (BM25_VERSION unchanged): no REINDEX required.
 */
