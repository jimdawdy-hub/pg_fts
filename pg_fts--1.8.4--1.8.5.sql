/* pg_fts 1.8.4 -> 1.8.5
 *
 * No SQL-visible changes.  C-level only: vendored sparsemap 5.6.0 -> 5.7.0
 * (small-set encoding for tombstone maps with few low docids; correctness fixes
 * in functions pg_fts does not call).  Wire format unchanged (version 2, mutually
 * readable with 5.6.x blobs already on disk).
 *
 * No on-disk format change (BM25_VERSION unchanged): no REINDEX required.
 */
