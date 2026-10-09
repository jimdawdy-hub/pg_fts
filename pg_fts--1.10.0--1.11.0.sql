/* pg_fts 1.10.0 -> 1.11.0
 *
 * No SQL-visible changes.  C-level only: best-first single-term and
 * conjunctive (AND, phrase) ranked top-k with exact block bounds (new GUC
 * pg_fts.bestfirst, default on); MaxScore (4+ terms) and ranked term:LABEL
 * wrong-result fixes; VACUUM folds the pending list before its dead-row pass
 * (a row inserted and deleted between VACUUMs stayed in the index); four
 * concurrency fixes (pending-list flush lost concurrent inserts; free-tail
 * truncation now requires AccessExclusiveLock; a freed page keeps its chain
 * link, its recycle XID moves to pd_prune_xid; idempotent tombstone free on
 * the scan retry path); faster
 * merge with identical output and compaction inside a plain CREATE INDEX /
 * REINDEX; a buffer ring for maintenance I/O; prefetch.
 *
 * No on-disk format change (BM25_VERSION unchanged): no REINDEX required.  The
 * tighter block bound uses the existing min_doclen header field; segments
 * written by older versions keep their looser (still sound) bound until a
 * merge rewrites them.
 */
