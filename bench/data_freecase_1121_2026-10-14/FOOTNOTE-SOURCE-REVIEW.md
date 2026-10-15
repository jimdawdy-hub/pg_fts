# FOOTNOTE-SOURCE-REVIEW — pg_fts 1.12.1 integration (2026-10-14)

Companion to `MAC-SOURCE-REVIEW.md` (mac-claude, same date, sealed read-only — left
untouched). Written independently before reading mac-claude's review; reconciliation at
the end. Scope: files only — `/home/jim/Projects/pg_fts-merge-1121` working tree and
`/data/pgfts-1121-validation-20261014/` evidence. No builds, tests, queries, or VM actions.

**Convergent verdict: PASS with one required item before VM801 install — post-fix
regression re-run (my Gap 1 = mac-claude's Q1).**

## Independent checks performed

- **Base fidelity.** Working tree vs upstream tag `v1.12.1`: 33 files, +6,546/−1,196 —
  exactly the Freecase surface (wide-position analyzer `vendor/ts_parse_wide.c` +486 and
  `pg_fts_tsanalyze.c`, `pg_fts_am_scan.c` +2,365 scan supersession, `pg_fts_query.c`
  +557 / `pg_fts_match.c` +413 legal-query semantics, `sql/legal_proximity.sql` +
  `configured_positions.sql` + `bmw_block_end.sql` + `ranked_route.sql` + expected
  outputs + `test/query_binary.py`). Nothing unexpected.
- **Version plumbing.** `pg_fts.control` `default_version = '1.12.1'`, `META.json`
  1.12.1, full upgrade chain present (`pg_fts--1.11.0--1.12.0.sql`,
  `pg_fts--1.12.0--1.12.1.sql`, base `pg_fts--1.12.1.sql`) — working
  `ALTER EXTENSION UPDATE` from installed 1.11.0-freecase. Format 4 / no-REINDEX
  established in the earlier v1.12.1 addendum review (`pg_fts_am.h` byte-identity).
- **Cache-construction leak fix (`pg_fts_am.c`).** Reviewed line by line: attempt-owned
  `AllocSetContextCreate("pg_fts cache build")`, all interruptible work inside `PG_TRY`,
  single offset-based chunk copied to `CacheMemoryContext` only on success, `PG_CATCH`
  deletes the build context and re-throws, `rd_amcache` published after the last
  interruptible step. Correct switch-out-before-delete ordering. Design assumption
  (appenders fold into the single `dc->used` chunk so the memcpy is relocation-safe) is
  confirmed by mac-claude's line-level check; Q1/Q2 close it empirically.
- **Probe methodology.** SQLSTATE 57014 injected **after allocations, before publish**
  (the construction window), 30 cycles, one persistent backend,
  `pg_backend_memory_contexts` before/after: control **+343,824 B** vs fixed
  **−11,856 B**, 0 unfinished build contexts. Matches the corrected leak semantics
  (construction-window only; routine settled-cache timeouts do not leak) — this probe IS
  the qualification design's deliberate construction-window test, already done well.
- **Tests (pre-fix).** `regress-initial.log` 18/18 regress + 2/2 isolation + tap PASS;
  suite maps to the preserved fixes (`wand_last_block`, `scan_keys`, `legal_proximity`,
  `configured_positions`, `score_reuse`, `dict_dir`, `doclen_slots`, `shared_doclen`,
  `ranked_exact`, `ranked_route`, `phrase_gate`).

## Additions beyond MAC-SOURCE-REVIEW

1. **Shipping source is unhooked — verified.** The integration tree's `pg_fts_am.c` has
   **zero** `PG_FTS_TEST_HOOKS` occurrences; the 57014 abort hook exists only in the
   private probe copies (`hook-leak-source` / `hook-fixed-source`). Nothing to strip at
   release; Debian/Ubuntu finals build unhooked.
2. **Leak-trigger scope, restated for the record.** The leak needs ERROR/cancel *inside
   cache construction* (first ranked use, directory invalidation, `doclen_cache_mb`
   budget rebuild). Do not bill routine 5 s/20 s statement-timeout cancels on settled
   caches to this bug; the historical comparison's cancels mostly hit settled state and
   are not retroactively tainted.

## Gap 1 (required before VM801 install)

The 18+2 suite (14:32) predates the cache fix (14:34+); `build-final.log` runs no tests;
no post-fix regression evidence is retained. Re-run at minimum `dict_dir`, `doclen_slots`,
`score_reuse`, `shared_doclen` (the fixed code path + self-containment assumption),
ideally the full 18+2, against the exact source the shipping `.so` builds from. Plus
mac-claude's Q2: a second identical ranked query must not rebuild (stable
`CacheMemoryContext` used_bytes across repeats after the first query).

## Qualification items carried forward (design only — none authorized or run)

1. Same-q captured-shape harness (75-cell historical comparison) as regression control.
2. Explicit `q1≠q2` engine-API controls for the rewritten 1.12.1 different-query path
   (exhaustive WHERE-match ranking, cost ∝ match set) — the captured app SQL threads one
   `q.query` into both `@@@` and `<=>` and does not exercise it.
3. Cache-probe pattern as the memory-test template (deliberate construction-window
   cancel; settled-memory growth bounds).

## Reconciliation with MAC-SOURCE-REVIEW

Concur on verdict and Q1. Their D1 (unfiltered `ORDER BY <=> NULL`: fork errors cleanly,
upstream intends NULL distances — record the choice in CHANGELOG), N1 (~2× chunk transient
during build; ~130 MB/backend at a 64 MB budget — relevant to VM101 sizing), N2, and V1
(`extversion` reads `1.12.1` identical to upstream — label CHANGELOG `1.12.1-freecase` and
record the shipping `.so` sha256 in every receipt) are sound; V1 is the one to action
before install. Their I7 merge analysis (fork-only `bm25_topk_exact` /
`bm25_count_dictdf_fastpath` not using the cached directory — correct but not accelerated)
adds an optional optimization I'd leave optional until measured.

## Not covered

Runtime behavior of the combined build; Debian/Ubuntu final logs after 14:41; equivalence
of probe `.so` hashes (`7e97ad2a…` leak, `4e4d6f65…` fixed) to the forthcoming shipping
`.so` — record the shipping hash in the qualification receipts as usual.
