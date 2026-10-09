/* pg_fts 1.9.0 -> 1.9.1
 *
 * No SQL-visible changes.  C-level only: the lazy phrase gate for ranked
 * phrase/NEAR queries on a positions=on index (new GUC pg_fts.lazy_phrase,
 * default on), and vendored sparsemap 5.8.0 -> 5.8.1 (sm_validate rejects a
 * sparse descriptor whose readers disagree).  Wire format unchanged.
 *
 * No on-disk format change (BM25_VERSION unchanged): no REINDEX required.
 */
