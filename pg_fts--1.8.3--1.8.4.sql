/* pg_fts 1.8.3 -> 1.8.4
 *
 * No SQL-visible changes.  C-level only:
 *   - vendored sparsemap 5.5.1 -> 5.6.0 (security-hardening release)
 *   - a corrupt tombstone or trigram bitmap now raises ERRCODE_DATA_CORRUPTED
 *     instead of being silently treated as empty
 *
 * No on-disk format change (BM25_VERSION unchanged; sparsemap wire format
 * unchanged at version 2): no REINDEX required.
 */
