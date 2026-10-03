/* pg_fts 1.8.5 -> 1.8.6
 *
 * No SQL-visible changes.  C-level only: vendored sparsemap 5.7.0 -> 5.8.0
 * (bulk sm_add_many_grow merges instead of inserting bit by bit; a
 * __sm_coalesce_map heap over-read fix).  Wire format unchanged (version 2,
 * byte-identical output to 5.7.0).
 *
 * No on-disk format change (BM25_VERSION unchanged): no REINDEX required.
 */
