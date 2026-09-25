# pg_fts roadmap

The single plan file. Open work first, in priority order, each with its status and the
evidence behind it. Closed items are one line each; the full record of how they were
closed (and the wrong turns on the way) is in `bench/ROADMAP_HISTORY_2026-09-17.md` and the
files `bench/INDEX.md` lists.

Rules for this file: an item is either **open**, **blocked**, or **closed**. When it closes,
collapse it to one line here and leave the detail in the CHANGELOG. Do not create a second
plan file.

---

## Open -- repository and presentation (from `REVIEW_2026-09-17.md`)

These do not touch the index and are the cheapest, highest-leverage work in the project.

| # | item | status |
|---|---|---|
| R1 | **README comparison paragraph contradicted the project's own table** (claimed a rare-term lead; called the doclen sidecar future work). Rewritten as a wins / loses / caveat structure; every figure grep-verified against `BENCHMARK_SUMMARY.md` and `RESULTS_C1X`. The paragraph now states it is derived from the summary and that the summary wins on disagreement. Rule 27 in `AGENTS.md` and `RELEASING.md` step 1 keep it in sync. | **done 2026-09-17** |
| R2 | **Delete the 31 dead base SQL scripts** in the root. Only `pg_fts--<current>.sql` is installed; the rest were snapshots left by each rename. Verified none referenced by Makefile/meson/flake before `git rm`. `RELEASING.md` step 1 now says `git mv`, not copy. | **done 2026-09-17** |
| R3 | **`bench/INDEX.md`** naming current-truth vs dated-record files. | **done 2026-09-17** |
| R4 | **One plan file.** `HANDOFF`/`DEFERRED`/`CAPABILITIES` folded: DEFERRED (all resolved) and the old ROADMAP moved to `bench/` as history; CAPABILITIES moved to `doc/` (it is user-facing Q&A, not a plan). | **done 2026-09-17** |
| R5 | **C comments no longer cite `bench/` files** (9 sites -> 0). They cite the CHANGELOG release that closed the issue; the journal can be reorganised, the CHANGELOG cannot. | **done 2026-09-17** |
| R6 | **`t/010` in all CI matrices** -- and what verifying it uncovered. GitHub: added, and the run log confirms `t/010_vacuum_delete_heavy.pl .. ok`. Forgejo: added too, **but the Codeberg CI has never executed a single run** -- every `ci.yml` run back to v0.1.0 is `cancelled` with `started_at = None` (queued, never picked up, superseded by the next push). Cause is account-side: Codeberg Actions needs a runner enabled per repository, which is not visible or fixable from the tree. The README's *first badge* had therefore shown "waiting"/"cancelled" to every visitor since the repo existed; it now points at the GitHub CI, which is the pipeline that actually runs. **Open sub-item R8 below.** | **done (GitHub verified); Forgejo cannot run** |
| R8 | **Codeberg Actions had never run -- and PGXN was frozen at 0.2.0 because of it.** Corrected diagnosis: Actions *was* enabled (`has_actions: true`); the cause is that **Codeberg provides no shared runners**, so all 115 queued runs (ci / release / docs) from v0.1.0 to v1.8.2 sat unstarted and were cancelled by the next push. The consequence was not cosmetic: PGXN publishing and the postgresql.org announcement lived *only* in the Codeberg release workflow (the GitHub one explicitly deferred to it), so **PGXN served 0.2.0 for 45 releases** -- pre-dating every field fix -- and the README's second badge pointed at it. Also the Codeberg Pages docs link was a 404. **Resolved by deletion, not by standing up a runner:** a 24/7 self-hosted runner to duplicate a matrix GitHub already runs green is real cost for zero signal. `.forgejo/workflows/` removed; PGXN publish + announce moved into the GitHub release workflow (409 = already published, idempotent); README badges now point at GitHub CI and the real latest tag; dead Pages link removed; RELEASING.md describes the one pipeline that exists. **Both follow-ups closed the same day:** `PGXN_USER`/`PGXN_PASSWORD` were already set as GitHub secrets (since 2026-07-08, unused until now); a `workflow_dispatch` re-publish of the existing `v1.8.2` tag ran the new definition -- `PGXN upload HTTP 303`, accepted -- and `api.pgxn.org` now reports **`version: 1.8.2`**, with `0.2.0` retained in history. The GitHub release was re-targeted, not duplicated (1 asset). `PGORG_*` is unset so the announcement step skipped, as designed; set it if pgsql-announce posts are wanted. | **done -- PGXN current** |
| R7 | **Agent tooling out of the working tree's face.** `.agent/`, `.claude/`, `.kiro/`, `.mcp.json`, `.agent-steering-domains.md` are gitignored but visible. `AGENTS.md` is now tracked and is the one entry point; the rest stay local. Also found and fixed while doing this: `result-1`, a nix build-output symlink, was **tracked** (now `git rm --cached`, `result*` ignored). | **done 2026-09-17** |

## Code quality (from `REVIEW_2026-09-17.md`) -- all three resolved 2026-09-17

| # | item | outcome |
|---|---|---|
| C1 | **Allocator state passed explicitly.** The four file-scope globals (`bm25_lowfree`, `_n`, `_i`, `bm25_alloc_extend_only`) became one `BM25AllocCtx` struct reachable only through `bm25_alloc_scope_enter(index, mode)` / `bm25_alloc_scope_exit(prev)`, which nest by returning the previous context -- the hand-rolled save/restore at two sites became the mechanism. `bm25_new_buffer()` now **`elog(ERROR)`s** if it finds compaction state with no scope active: exactly the dangling-pointer failure from the 1.7.1 work that only `t/007` caught. Deliberately an `elog`, not an `Assert`: the release gate is not a cassert build, and a check that only fires in a build nobody ships is documentation. Threading a struct through all 16 `bm25_new_buffer` callers was considered and rejected -- compaction is single-writer, so the context is backend-scoped in effect either way, and the scoped-lifetime design makes the failure mode a hard error at the same cost as a comment. | **done** |
| C2 | **`bm25_collect_matches` split: 412 -> 226 lines.** The 176-line per-segment loop body became `bm25_collect_segment()` (153 lines, returns `SEG_RESTART` for the positional-phrase fallback the loop used to express as `s = -1; continue`), and the 71-line pending-list walk became `bm25_collect_pending()`. State shared with the extracted evaluator travels in a `BM25CollectCtx`. Behaviour-preserving; full gate green. While doing it, the 14 `page + pd_lower` reads in `_scan.c` and the one in `pg_fts_trgm_index.c`'s blob reader (a **9th instance** of the 1.7.0 defect class, feeding a `memcpy` length) were routed through `bm25_page_data_end()`. | **done** |
| C3 | **The 12,000-line translation unit: KEEP, and document why.** Measured the cost of splitting: 15 `am.c` statics would go extern (13 for `_scan`, 5 for `_trgm`), 1 the other way, ~10 shared struct types would move into `pg_fts_am.h` (the on-disk-format header), and the hot-path `static inline` helpers (`bm25_tid_to_docid`, `bm25_docid_to_tid`, `bm25_page_data_end`, `bm25_doclen_cursor_lookup` -- inside the 45%/37% profile) would stop inlining without LTO, which PGXS does not use. In return: three `.o` files and no behaviour change. Decision recorded at the `#include` site and in both included files' headers, with the two prerequisites (an internal header; a before/after latency measurement) if separate compilation is ever needed. | **decided: keep** |

## Open -- index behaviour

| # | item | status | evidence |
|---|---|---|---|
| I1 | **Bulk-ingest write amplification -- FIXED for row-per-transaction ingest (1.8.3).** Root cause was not the XID horizon (that binds only inside one multi-row statement) but the merge's `EXTEND_ONLY` allocation never consulting the free list. `BM25_ALLOC_SNAPSHOT` (free list gathered once at entry, never re-read) keeps the recycle-race guard by construction and reuses earlier frees. Field shape, 30k then 100k docs of row-per-txn churn, autovacuum on, nothing manual: **1,823 -> 1,823 MB** and **1,823 -> 1,875 MB with `fts_vacuum` finding nothing to reclaim**; v1.8.2 on the same harness grew 3.2 GB per 5k rows and then **deadlocked** (a pre-existing concurrent-merge deadlock, also fixed, plus a live-page handout deadlock the fix exposed -- both in the CHANGELOG). **Residual:** one very large `INSERT ... SELECT` of oversized rows still needs an `fts_vacuum` after; modelled the fewer-larger-merges alternative at ~2x, not worth its complexity. | **done; residual narrowed** | `bench/RESULTS_I1_2026-09-18.md` |
| I2 | **Common-term ranked latency -- the competitive gap.** `year` (df 734,896) top-10: **36.16 ms** vs pg_search 2.12, vchord 3.49, pg_textsearch 20.71; 20.7x under load. Profile: 45% doclen path, 37% candidate iteration -- per-posting scalar work. Only **item D** below can close it. | **open, architectural** | `bench/NOTE_PROFILE_COMMON_TERM_2026-09-06.md`, `RESULTS_C1X_CROSSENGINE_2026-09-11.md` |
| D | **Two-level page bitmaps + SIMD** (TIN-style). Format side is tractable via the 1.5.0 optional-per-segment-pointer + dual-read precedent (**no REINDEX**). Real cost: **no SIMD infrastructure exists** (no intrinsics, no runtime dispatch, no `-mavx2` plumbing) and a scalar fallback must be kept for non-AVX and ARM -- two implementations forever. Largest change the project has attempted, against a competitor that cannot be benchmarked. **Needs explicit sign-off.** Do **not** vectorize the vendored sparsemap. | **blocked on sign-off** | `bench/NOTE_TIN_FEASIBILITY_2026-09-14.md`, `NOTE_SIMD_VENUE_2026-09-14.md` |
| I3 | **Managed-service validation** on a compute/storage-separated backend (Aurora-style). GenericXLog-only WAL should be safe; unverified externally. | **open, external** | `doc/CAPABILITIES.md` |
| I4 | **Independent human review of WAL/crash/recovery paths.** Checklist exists in `RELEASING.md`; the review itself is a release-integrator step. | **open, external** | |
| I7 | **Configured analyzer loses positions after 16,383.** `to_ftsdoc('simple', repeat('filler ',17000) || 'alpha beta') @@@ '"alpha beta"'` is false, while the unconfigured analyzer returns true. PostgreSQL's configured parsing pipeline caps these positions before pg_fts receives them. Existing saved vectors cannot recover lost positions. Verify long-document analysis and stored input positions before adopting this path. | **open, inherited limitation** | README / CHANGELOG Unreleased |

## Open -- measurement debt

| # | item |
|---|---|
| M1 | **C2 cross-engine ingest.** Rivals' ingest paths differ fundamentally; needs per-engine forms chosen as carefully as C1X's. |
| M2 | **C3 NDCG vs rivals.** Matters because pg_search (Tantivy) does not stem -- its speed is partly a smaller unit of work. `bench/ndcg.py` exists. |
| M3 | ~~Longer ingest run~~ **done 2026-09-18**: 20 rounds / 100k row-per-txn docs. No decay -- throughput oscillates 33-56 rows/s with round durations at exactly 1x / 1.33x / 1.67x a 90 s floor, i.e. autovacuum cycles landing in the round or not. The absolute rate is the harness (psql building 1,660-term strings), not publishable. Appended to `RESULTS_I1_2026-09-18.md`. |
| M4 | **The published competitor set on TIN's exact rig** (i7i.8xlarge, 8 vCPU / 32 GB container, Stack Exchange corpus) plus pg_fts -- places us on their axis without asserting anything about TIN. Several EC2 hours. |

## Declined (with the measurement that declined them)

- **Impact-ordered postings** -- breaks the docid ordering that `count(*)`/AND/phrase/prefix need.
- **Early termination** -- breaks exact top-k.
- **Lazy phrase gate** -- ~1.5x ceiling; adjacency is only 4.3% of the query.
- **Heap-side `positions=off`** -- saves ~16% of a `STORAGE=extended` column; no-go.
- **Parallel ranked scan** -- built, measured, reverted (`bench/NOTE_PARALLEL_RANKED.md`).
- **Parallel merge** -- 1.45x slower and 19% larger at scale; `mpmw=8` silently serial.
- **df-threshold bulk load** -- cost ~linear in df, no fixed floor.
- **Verbatim posting copy on merge** (TIN item C) -- the merge re-encodes through the build hash table; no splice point.
- **Vectorizing sparsemap** -- never a query hotspot; the one time it was the bottleneck (P0, 99.75%) the fix was algorithmic; its compressed layout is SIMD-hostile; it is vendored byte-identical to upstream on purpose.

## Closed (one line each; detail in CHANGELOG)

- **I6, unreleased:** Chained/nested unordered proximity, phrase and OR operands, exact distances, positional evaluation, stable ranked results, and PostgreSQL 17/18 correctness checks. See CHANGELOG Unreleased.

- **1.8.1** count-path: df fast-count gate tests (10, non-vacuous); block-run VM checking measured ~1%, kept as cleanup.
- **1.8.0** intra-word `-` `.` `/` are terms, not operators (`pkg-config` no longer parses as `pkg & !config`).
- **1.7.2** insert-time merge gated on segment pressure: bulk-ingest growth -31%.
- **1.7.1** `pd_lower` guard generalised to all 8 page-read sites; "one WAL record per page" known issue **retracted** (0.005 ms/page measured).
- **1.7.0** P0: unvalidated `pd_lower` in the merge dict walk made an index permanently unvacuumable at field shape; fixed. Huge-alloc gaps in doclen/tombstone arrays fixed. Cleanup no longer grows the index (18/18/18 MB vs 35/52/69).
- **1.6.1** P0: VACUUM never completed on a delete-heavy index (4h39m -> 393 s; dense tombstone bitmap sized by `sm_maximum`). sparsemap 5.5.1.
- **1.6.0** phrase over positionless docs returns `false`, not a silent conjunction (matches `OP_PHRASE`).
- **1.5.9 / 1.5.10** non-UTF-8 case folding; common-term 1.56x via ascending-resume + word-load `bm25_for_get`.
- **1.5.0** doclen sidecar (format v3 -> v4) with dual-read, **no REINDEX** -- the precedent for all future format changes.
- **COUNT pushdown** (CustomScan), **`fts_search` under-fetch**, **reserved keywords as literals**, **sparsemap error-path leaks**, **recovery guard on `fts_merge`/`fts_vacuum`**, **privilege lockdown**, **recently-dead exclusion from corpus stats**, **parallel-build memory ceiling** -- all shipped; see history file.
