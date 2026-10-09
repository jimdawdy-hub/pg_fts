# bench/ -- what is current and what is record

`bench/` is a **dated lab notebook**, not documentation. It is kept because the project's
credibility rests on being able to show how every number was produced, which
optimisations were tried and rejected, and which published figures were later retracted.
But 78 files with no index is unreadable, so this file says which ones to trust today.

**Rule:** a new measurement file gets a date suffix and one line here. If it supersedes an
earlier file, say so on both lines. C comments cite the CHANGELOG entry, never a file here.

## Current truth (read these)

| file | what it is |
|---|---|
| `BENCHMARK_SUMMARY.md` | **Start here.** Current numbers vs all measured competitors, the 8-run protocol, the correctness gate, the list of optimisations rejected by measurement, and the record of numbers published wrong and corrected. |
| `../doc/COMPARISON_MATRIX.md` | Feature/perf matrix. Untested competitor capabilities are marked untested, never "No". TIN has a "not in this matrix" note, not a column. |
| `RESULTS_A_2026-10-07.md` | **Current: 1.11.0 (Approach A) vs 1.10.0 on the same host and index, and vs pg_textsearch 1.5.1, pg_search 0.26.0, VectorChord-bm25 0.3.0 on fresh hosts, aarch64.** Latency (12 bands), settled throughput, cold cache, build as an expression index. Protocol written first: `PROTOCOL_A_2026-10-07.md`. Run data in `data_A_2026-10-07/run/`; the development measurements behind each change (skippability, oracle checks, merge identity, mutants, prefetch, buffer ring) in `data_A_2026-10-07/` (`*_notes.txt`). Supersedes the scoreboard of the line below; that line stays the record of the 1.10.0 release run. |
| `data_A_2026-10-07/release/` | Current: the 1.11.0 release qualification. `gate_fixed_ada32aa.txt` and `upgrade_qual_ada32aa.txt` are the final gate and upgrade check; `concurrency/FIXED.txt` is the verification record of the four concurrency fixes (`concurrency/FINDINGS.txt` is the pre-fix finding); `size_results_39b6a42_vs_release.txt` compares the benchmarked binary with the release. `gate_aarch64_release.txt` and `gate_x86_nix_release.txt` are superseded (tree before the fixes). |
| `PROTOCOL_A_2026-10-07.md` | Current: the Approach A benchmark protocol (fixed before the run). |
| `PLAN_A_2026-10-07.md` | Record: the Approach A design (effective-length block bound, best-first, conjunctive walk, build, prefetch) and the alternatives rejected by measurement. |
| `RESULTS_110_2026-10-07.md` | **Record of the 1.10.0 release run: 1.10.0 vs pg_textsearch 1.5.1, pg_search 0.26.0, VectorChord-bm25 0.3.0, aarch64 (Graviton3), one host per engine.** Latency, 16/32/64-client throughput, size, build, match counts; the I6 shared-doclen A/B. Protocol written first: `PROTOCOL_110_2026-10-07.md`. Data in `data_110_2026-10-07/`. Supersedes the scoreboard of the line below. |
| `PROTOCOL_110_2026-10-07.md` | Current: the 1.10.0 benchmark protocol (fixed before the run). |
| `PLAN_I6_SHARED_DOCLEN_IMPL_2026-10-07.md` | Current: design of the shared doclen copies (shipped 1.10.0), including the visibility argument. |
| `RESULTS_191_2026-10-06.md` | Superseded by `RESULTS_110_2026-10-07.md` (scoreboard; x86, different rig). Record of the lazy phrase gate and the layout regression. 1.9.1 vs pg_textsearch 1.4.0 (same-day control). Leads every latency and throughput band, phrase included (34.8 vs 43.0 ms, lazy phrase gate); rare-term tps falls with client count (I6, cause measured, fix planned). Also the record of a 5% code-layout regression found and removed before release. Data in `data_191_2026-10-06/`. Supersedes the scoreboard of the line below. |
| `PLAN_PHRASE_GATE_2026-10-06.md` | Current: design of the lazy phrase gate (shipped 1.9.1). |
| `PLAN_I6_SHARED_DOCLEN_2026-10-06.md` | Current for the I6 diagnosis (evidence in `data_i6_2026-10-06/`); its design section is superseded by `PLAN_I6_SHARED_DOCLEN_IMPL_2026-10-07.md`. |
| `RESULTS_190_2026-10-01.md` | Superseded by `RESULTS_191_2026-10-06.md` (scoreboard). 1.9.0 vs pg_textsearch 1.4.0. Leads every latency and throughput band except phrase (3.2x behind); rare-term tps falls with oversubscription (known issue). Correctness and in-place-upgrade qualification. Supersedes the scoreboard of the line below. |
| `PLAN_C2_2026-10-01.md` | The C2 (dense high-df scoring) plan; shipped in 1.9.0. |
| `RESULTS_AC_PGTS_2026-10-01.md` | Superseded by `RESULTS_190_2026-10-01.md` (scoreboard); still the record of plans A + C1 and the WAND last-block bug. Plans A + C1 + follow-ups (branch `perf-a-limit-hint`, unreleased) and the head-to-head re-run on Debian 13: pg_fts now wins rare/mid/count/AND/OR/prefix and rare-term concurrency, ties common k10, loses common k100 (1.06x), common-term tps (0.85x) and phrase (3.4x). Also the WAND last-block recall bug found and fixed. Supersedes the scoreboard of the line below. Data in `data_perfA_2026-10-01/`, `data_perfC_2026-10-01/`, `data_h2h_2026-10-01/`. |
| `RESULTS_PGTS_2026-09-30.md` | **Current vs pg_textsearch.** pg_fts 1.8.6 vs pg_textsearch v1.4.0, single-client latency (3 passes) and concurrency at 16/32/64 clients, four parallel hosts. Also the query-form check that retracts September's rare-term claim. Data in `data_pgts_2026-09-30/`. Supersedes the pg_textsearch columns of the two files below. |
| `RESULTS_5WAY_159b_2026-09-06.md` | The latest 4-engine single-client latency run (pg_fts / pg_textsearch / pg_search / vchord; no GIN column despite the "5-way" name). **Its pg_fts column used `fts_search()` and the competitors `ORDER BY`** -- see CHANGELOG 1.8.6 Retracted. pg_search/vchord columns still current; pg_textsearch column superseded by `RESULTS_PGTS_2026-09-30.md`. |
| `RESULTS_C1X_CROSSENGINE_2026-09-11.md` | Concurrent throughput, 1/8/16/32 clients, cross-engine. Includes the correction of the "vchord collapses" claim. pg_textsearch rows superseded by `RESULTS_PGTS_2026-09-30.md` (16/32/64 clients). |
| `RESULTS_C2_INGEST_2026-09-11.md` | Ingest throughput and pending-list latency curve (pg_fts arm only). |
| `RESULTS_SPARSEMAP58_2026-09-30.md` | **Current.** sparsemap 5.8.0 (1.8.6) qualified at scale on EC2: 5M rows, delete+VACUUM x3, counts correct on both arms; VACUUM ~30% faster on the later rounds, build unchanged. Data in `data_sm58_2026-09-30/`. |
| `RESULTS_I1_2026-09-18.md` | **Bulk-ingest bloat: root cause found and fixed** (the merge was extend-only and never reused pages), plus two pre-existing deadlocks found and fixed on the way. Zero net growth over 30k and 100k row-per-txn docs; `fts_vacuum` finds nothing to reclaim. M3 (long ingest: no decay, only cycle noise) is appended. Supersedes the mechanism section of `RESULTS_KNOWN_ISSUES_2026-09-14.md`. |
| `RESULTS_KNOWN_ISSUES_2026-09-14.md` | The bulk-ingest bloat investigation as of 1.7.2: mechanism half-right (the XID gate binds only inside a single multi-row statement), 31% mitigation, and the retraction of the "one WAL record per page" claim. **Mechanism superseded by `RESULTS_I1_2026-09-18.md`.** |
| `RESULTS_FIELDSHAPE_2026-09-13.md` | The ~2.87M-doc / 1660-terms-per-doc field shape: the P0 that made an index permanently unvacuumable, its gdb isolation, and the fix. |
| *(vendored sparsemap)* | `vendor/sm.h` byte-identical to upstream; `vendor/sm.c` = upstream + the 9-line `SPARSEMAP_PREFIX` block. Re-vendored 5.4.0 -> 5.5.0 -> 5.5.1 -> 5.6.0 -> 5.7.0 -> 5.8.0; each time upstream's own suite is run against the vendored copy with the prefix defined empty (21/21 at 5.8.0, ASan+UBSan), and `test/fuzz/fuzz_smblob.c` round-trips our exact write/open path under ASan+UBSan. See CHANGELOG 1.6.1, 1.8.4, 1.8.5, 1.8.6. |
| `RESULTS_ABC_2026-09-17.md` | Count-path work: df fast-count tests, block-run VM checking measured at ~1% (kept as cleanup), verbatim-merge-copy withdrawn. |
| `NOTE_VS_TIN_2026-09-14.md`, `NOTE_TIN_FEASIBILITY_2026-09-14.md`, `NOTE_SIMD_VENUE_2026-09-14.md` | Competitive/architectural analysis of PlanetScale's TIN, what of it is reachable, and why SIMD does not belong in the vendored sparsemap. |
| `PLAN_ABC_2026-09-14.md` | The plan behind `RESULTS_ABC`; shows how reading the code moved all three items before implementation. |

## Design notes (still describe the shipped design)

| file | describes |
|---|---|
| `DESIGN_DOCLEN_SIDECAR.md` | The v4 per-segment doclen sidecar and the dual-read upgrade -- the precedent for every future format change. |
| `DESIGN_FIELD_ZONES_v4.md` | Field zones (`term:D` weighting). |
| `NOTE_WAND_PRUNING_2026-09-04.md` | Why WAND is exact here and what it does not prune. |
| `NOTE_RANKED_EXACTNESS_LATENT.md`, `NOTE_RANKED_RECALL.md`, `RANKED_SCAN_CORRECTNESS_INVESTIGATION.md` | The exact-top-k guarantee and its history. |
| `NOTE_PHRASE_POSITIONS.md`, `NOTE_PHRASE_POSITIONS_FIX.md`, `REVIEW_PHRASE_NOPOS.md` | Phrase semantics on positionless documents (1.6.0). |
| `NOTE_STRATEGY_TSVECTOR_HARDENING_UPSTREAM.md` | Relationship to upstream tsvector work. |

## Dated record (superseded or closed; keep for provenance)

**Investigations that are closed.** `P0_VACUUM_HANG_2026-09-10.md` (fixed 1.6.1),
`P1_VACUUM_NO_RECLAIM_2026-09-11.md` and `RESULTS_SELF_LIMITING_2026-09-12.md` (the
cleanup-growth chain, fixed across 1.6.1-1.7.1; four wrong hypotheses recorded honestly),
`RESULTS_P1_SCALE_AB_2026-09-13.md` (showed the P1 did not reproduce at 1M docs),
`DIAG_WORKER_FRAGMENTATION.md` + `REVIEW_WORKER_FRAGMENTATION.md`,
`NOTE_BUILD_FLUSH_QSORT_SPIN.md`, `RESULTS_MERGE_OOM.md`, `RESULTS_MERGE_MEMORY.md`,
`RESULTS_MERGE_VACUUM_DECODE.md`, `RESULTS_VACUUM_SCALE.md`, `RESULTS_SPARSEMAP_2026-09-08.md`,
`RESULTS_PARALLEL_MERGE_2026-09-08.md`, `RESULTS_GATING_2026-09-09.md`,
`RESULTS_ENCODING.md` + `NOTE_ENCODING_REVIEW_2026-09-06.md` (fixed 1.5.9).

**Profiles that motivated shipped changes.** `PROFILE_STEP0.md`, `NOTE_FORMAT_V3_PROFILE.md`,
`NOTE_PROFILE_COMMON_TERM_2026-09-06.md` (the 45%/37% breakdown still quoted),
`NOTE_PHRASE_PROFILE_2026-09-06.md` (the "90.70 ms phrase was not a phrase" correction),
`NOTE_RARE_MID_LATENCY_OPTIONS_2026-09-05.md`.

**Options considered and declined, with the reason.** `NOTE_IMPACT_ORDERING.md` (breaks
docid-ordered count/AND/phrase), `NOTE_META_WAH_ASSESSMENT.md`, `NOTE_PARALLEL_RANKED.md`
(built and reverted), `PLAN_HEAP_POSITIONS_OFF.md` (no-go: ~16% of a compressed column),
`PLAN_PARALLEL_SCAN.md`, `NOTE_ANOMALY_DETECTION.md`, `NOTE_SIZE_AND_SPEED.md`,
`NOTE_SIZE_SPEED_REPLAN.md`, `RESULTS_ANDOPT.md`.

**Superseded benchmark runs** (each replaced by the next; kept so the trend is auditable):
`RESULTS_V022.md`, `RESULTS_130_vs_122.md`, `RESULTS_4WAY.md`, `RESULTS_4WAY_2026-07-29.md`,
`RESULTS_VS_PGSEARCH.md`, `RESULTS_VS_PGSEARCH_WIKI.md`, `RESULTS_VS_VCHORD_PGTEXTSEARCH.md`,
`RESULTS_VS_CURRENT.md`, `RESULTS_WIKIPEDIA_2M.md`, `RESULTS_20M.md`, `RESULTS_BENCH_20M_100M.md`,
`NOTE_CORPUS_20M.md`, `RESULTS_SEGMENTED.md`, `RESULTS_P1_P4.md`, `RESULTS_HARDENING_2026-08.md`,
`RESULTS_5WAY_150_2026-08-28.md`, `RESULTS_5WAY_157_2026-09-01.md`, `RESULTS_5WAY_158_2026-09-04.md`,
`RESULTS_5WAY_159_2026-09-05.md`, `RESULTS_C1_UNDERLOAD_2026-09-11.md` (pg_fts-only precursor
to C1X), `COVERAGE_AUDIT_2026-09-10.md`.

**Historical plans.** `PLAN_4WAY_BENCHMARK.md`, `PLAN_5WAY_LOADED_2026-08.md`,
`PLAN_HARDENING_2026-08.md`, `PLAN_STORAGE_PERF_2026-08.md`, `NOTE_1_0_0_READINESS.md`,
`NOTE_COMPETITIVE_LANDSCAPE.md`.

## Data directories

`data_*` directories hold the raw logs/JSON behind a `RESULTS_*` file of the same date.
They are the evidence and are intentionally tracked. Harness scripts are `*.sh` here
(`underload.sh`, `ingest.sh`, `parity_check.sh`, `soak.sh`, `latency.sh`, `ndcg.py`).
