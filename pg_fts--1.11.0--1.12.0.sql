/* pg_fts 1.11.0 -> 1.12.0
 *
 * No SQL-visible changes.  C-level only: ranked queries look a term up in a
 * per-backend in-memory copy of each segment's dictionary index (ROADMAP I7)
 * instead of re-reading the index chain under buffer pins and share locks; the
 * per-backend relcache chunk is rebuilt when pg_fts.doclen_cache_mb changes.
 *
 * No on-disk format change (BM25_VERSION unchanged): no REINDEX required.
 */
