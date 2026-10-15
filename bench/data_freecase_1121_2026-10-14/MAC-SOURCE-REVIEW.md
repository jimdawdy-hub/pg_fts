# pg_fts 1.12.1 integration: static source review (mac-claude)

- **Reviewer:** mac-claude (Claude Opus 5.5, claude-opus-5-5), 2026-10-14. Files only: no builds, database queries or VM actions.
- **Tree:** `/home/jim/Projects/pg_fts-merge-1121`, branch `upgrade/freecase-1121-20261014`. Fork 37801f3 plus upstream tag v1.12.1 (4434607), uncommitted. Merge base 93c4b5fd.
- **Evidence read:**
  - `regress-initial.log`, which covers the merge before the cache fix: 18 regression tests and 2 isolation tests passed;
  - the `cache-probe-{leak,fixed}.{json,sql}` files.

**Verdict:** I have no blocking findings. Keeping the fork's scan code is sound; it covers all five upstream 1.12.1 fixes. The cache-construction fix is correct. One step remains before installing: run the full regression suite again on the post-fix tree (Q1).

## Scan code: keep the fork's version (`pg_fts_am_scan.c`)

The merged `pg_fts_am_scan.c` differs from 37801f3 only by the I7 dictionary-directory lookups (21 lines). Each upstream 1.12.1 fix and how the fork handles it:

| Upstream 1.12.1 fix | Fork 37801f3 mechanism | Status |
|---|---|---|
| #8: NOT over phrase/NEAR under-counted | `bm25_not_parity`. Under an odd number of NOTs, an approximated operand becomes the empty set. Approximated operands are PHRASE/WITHIN/EXACT and weighted terms. Approximating from below like this is equivalent to upstream's `eval_widen`, and it also covers the fork's WITHIN, EXACT and weight operators, which upstream lacks. | Covered |
| Fuzzy/regex under NOT, or ORed with a plain term | Any fuzzy/regex query with more than one item goes through `bm25_eval_query` plus recheck. The trigram funnel only ever sees a single-leaf query, which is trivially covered. Pattern leaves (`bm25_lookup_pattern`) match exactly: they use the same `RE_compile_and_execute(REG_ADVANCED, C_COLLATION_OID)` call and the same `varstr_levenshtein_less_equal(1,1,1,k)` call as the heap matcher (`pg_fts_match.c:441-445`, `pg_fts_doc.c`). A pattern leaf is therefore never a superset that a NOT could turn into a subset. | Covered |
| #10: second `@@@` key ignored | `filtq[]` holds every key, with byte-identical keys folded. `bm25_collect_filter_split` takes the AND of the per-key sets, and a key keeps its exactness only if every key decided it. | Covered |
| #9: `WHERE q1 ORDER BY q2` filtered by q2 | `filterDiffers` routes this to `bm25_gettuple_filtered`. That path returns the full filter set, scored by the index for q2, with zero-score rows at distance 1.0 in TID order. | Covered |
| NULL WHERE / NULL ORDER BY crash | A NULL key matches nothing. A NULL ORDER BY with a filter returns `rankNull` (NULL distances). | Covered; see D1 |

**Test evidence.**
- `sql/scan_keys.sql` and `expected/scan_keys.out` are byte-identical to v1.12.1, and the test passed on the merged tree. It covers the 28 shapes × 4 paths, #9, #10 and the NULL generic plans.
- `expected/pg_fts.out` carries upstream's corrected two-qual expectation (`count = 0`, line 5799).

**D1 (low, behavioral difference).** Consider `ORDER BY d <=> NULL` with no WHERE `@@@` filter, when the planner picks the index:
- The fork raises `ERROR: pg_fts: ORDER BY distance to NULL requires a search filter` (`bm25_rescan`, `nfiltq == 0`).
- Upstream intends to return the rows with NULL distances.

Upstream's `sko3` case expects 3 rows and passed, presumably because the planner didn't use the index for that query. The result is a clean error, not a crash, and the app never sends this query shape. Keep the error or match upstream; either way, record the choice in the CHANGELOG.

## I7 dictionary-directory lookups merged into the fork's scan code

- `bm25_lookup_dict(..., dc)` uses the cached directory when `bm25_dictdir_find` matches and otherwise falls back to `bm25_dict_seek`. The page located is the same either way.
- The cache is passed in `bm25_query_maxhits` and in both `bm25_open_cursors` lookups, as upstream does.
- It is NULL, meaning the chain walk, in the fork-only `bm25_topk_exact` and `bm25_count_dictdf_fastpath`. That is correct but not accelerated. Optional follow-up: pass `dc` there too.
- The call pattern matches upstream: no `bm25_doclendir_cache` rebuild happens between fetching `doclendir` and using it, so there is no use-after-free from a rebuild in the middle of a query.

## Cache-construction cancellation fix (`pg_fts_am.c`, `bm25_doclendir_cache`)

The design is correct:

- **Relocation-safe layout.** `BM25DoclenDir.slot_base_off/slot_byte_off` and `BM25DictDir.entry_off` are byte offsets from the start of the chunk, and the structs hold no pointers. The `shared_doclen` path returns early from `add_slots` without adding arrays. So the final `memcpy` into `CacheMemoryContext` is relocation-safe.
- **Scratch contexts are cleaned up.** The `tmp` contexts in `add_slots` and `dictdir_add` are children of `CurrentMemoryContext`, which is `buildctx` during the build, so they die with it. Intermediate copies use `GetMemoryChunkContext(dc)`, which is `buildctx`, and `pfree` their input.
- **No dangling pointer.** The stale chunk is `pfree`d and `rd_amcache` set to NULL *before* the build, so an error cannot leave a pointer to freed memory.
- **Errors are caught.** An out-of-memory error in the final `MemoryContextAlloc(CacheMemoryContext, dc->used)` is caught, and `buildctx` is deleted. `parent` and `buildctx` are not modified inside `PG_TRY`, so they need no `volatile`, and `result` is used only on the normal path.
- **`rd_amcache` contract.** It stays a single chunk that is `pfree`d wholesale (`dc->used` covers the slots and dictdirs because both appenders set `used`).
- **Probe.** Over 30 cancel-before-publish cycles, the control build leaked +343,824 B and the fixed build changed by −11,856 B, with no unfinished build contexts.

Notes:

- **N1, memory.** Peak memory during a build is about twice the final chunk: the old intermediate, the new intermediate and the final copy. The chunk is sized by `pg_fts.doclen_cache_mb`, so at 64 MB expect up to about 130 MB transient per backend on the first ranked query after each generation change. This is acceptable, but it should be known when sizing `work_mem`/backends on VM101.
- **N2, simplification (optional).** The `PG_CATCH` is belt-and-braces: `buildctx` is a child of the query context, which transaction abort resets anyway. It's harmless, so keep it.

## Wide positions, format 4 and versioning

- **No on-disk changes.** `pg_fts.h` versus v1.12.1 differs only by the fork's query operators (WITHIN, EXACT) and the match-span API; no on-disk index struct changed. Upstream 1.12.0 and 1.12.1 change no on-disk format. I7 parses dictionary-index pages, which the fork did not change. The 30-bit position and `ts_parse_wide` code is fork-only and untouched by the merge.
- **Upgrade path.** `pg_fts--1.11.0--1.12.0.sql`, `pg_fts--1.12.0--1.12.1.sql` and `pg_fts--1.12.1.sql` are byte-identical to upstream, and the control file says `default_version = '1.12.1'`. That gives a working `ALTER EXTENSION UPDATE` path from the fork's 1.11.0.
- **V1 (informational).** As with 1.11.0-freecase, `extversion` will read `1.12.1`, the same as upstream. Label the CHANGELOG `1.12.1-freecase`, and record the installed `.so` sha256 in the VM801 and production receipts, because the version string alone cannot tell the two builds apart. Also note that ftsquery values using WITHIN or EXACT, if any are stored, are readable only by fork binaries.

## Before installing on VM801

- **Q1.** Run the full regression and isolation suites on the post-fix tree; the logged pass predates the cache fix. Pay particular attention to `dict_dir`, `doclen_slots` and `shared_doclen`.
- **Q2.** Add one positive check that the fix still publishes the cache: a second identical ranked query must not rebuild. For example, `CacheMemoryContext` used_bytes should be unchanged across repeats after the first query, and the `dict_dir` test should still pass against the post-fix build.

## Not reviewed

- The bench and docs portion of the 445-file staged diff.
- The upstream-identical files (`pg_fts_customscan.c` and the others with no diff against v1.12.1).
- The Debian and Ubuntu build logs.
