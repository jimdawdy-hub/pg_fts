# A + C1 vs pg_textsearch 1.4.0: the head-to-head re-run (2026-10-01)

Follow-up to `RESULTS_PGTS_2026-09-30.md`: plan A (LIMIT pushdown + exact-k WAND), C1
(resident slot-indexed doclen) and the findings along the way, then the same benchmark
re-run on Debian 13 hosts. Raw data: `data_perfA_2026-10-01/`, `data_perfC_2026-10-01/`
(dev-host A/B runs) and `data_h2h_2026-10-01/` (head-to-head hosts).

## Rig

EC2 r6id.4xlarge (16 vCPU / 8 physical cores, 123 GB, 884 GB instance-store NVMe),
**Debian 13.7**, PostgreSQL 17.10 built from source on each host. Same corpus as
2026-09-30, regenerated on every host: md5 `f5939e85...` everywhere, 2,188,038 rows. Same
GUCs, same 8-run / median-of-last-5 protocol, 3 latency passes; concurrency at 16/32/64
clients, 30 s, 2 passes. pg_textsearch v1.4.0 (`7a932505`) unchanged.

Two head-to-head runs:
- **Run 1** (4 parallel hosts, pg_fts `7ac348e`, 06:00-06:30 UTC). Both pg_textsearch
  arms are from this run.
- **Run 2** (2 hosts, pg_fts `efca0cf`, 07:50-08:30 UTC) after the fix and the score-reuse
  change below. It re-ran only the pg_fts arms; pg_textsearch did not change.

The galloping phrase probe (`22db379`) came after run 2 and is measured on the dev host
only (below).

## What changed, each measured A/B on one host and data directory, arms alternated 5x

| commit | change | effect (ms, medians) |
|---|---|---|
| `af2e7e0` A | planner hook attaches LIMIT+OFFSET to the `<=>` Const; first WAND batch = k (was a fixed 100, x4 over-fetch => top-400 for LIMIT 10); over-fetch dropped when the heap is >=99% all-visible; top-k heaps evict by (score, TID) so batches are prefixes of each other | rare 8.75->6.80, mid 14.45->11.78, common 45.0->30.5, AND 8.26->4.84, OR2 8.98->4.79, OR3 13.28->5.69 |
| `91b883d` C1 | sidecar decoded once per backend per generation into a dense per-heap-block slot array (4.8 MB, ~20 ms, GUC `pg_fts.doclen_cache_mb`); count fast path uses one `visibilitymap_count` instead of a per-block VM loop | rare 6.88->1.00, mid 11.93->1.05, common 30.8->11.7, count 2.24->0.19 |
| `7ac348e` | inlined TID sort (`sort_template.h`) in `tidset_sort_uniq` | prefix 9.52->6.49 |
| `efca0cf` | planner substitutes the resjunk `<=>` sort-key copy with `fts_current_distance()` (the scan's own exact distance) -- no heap detoast + re-score per returned row | rare 1.00->0.70, mid 1.07->0.83, AND 2.19->1.57, OR2 2.16->1.55, OR3 3.71->2.89 |
| `22db379` | galloping forward probe in the positional phrase intersection | phrase (positions=on) 183->146, 3 rounds |

Every A/B row: identical result counts on both arms, and the ranked top-k lists for 7
queries x {10,100} byte-identical to arm A.

## Correctness finding: a ranked-OR recall bug in every release (fixed in `efca0cf`)

`wand_skip_blocks()` proved a posting block entirely below a seek target by reading the
**next** block's `first_docid` on the same page. For a term's **last** block, that header
belongs to the next term in the shared posting chain. Whenever that term started at a
lower docid, the live last block was skipped and its postings never scored. Ranked OR
queries could drop true top-k documents at small k.

- 2,000-row repro: `w3 | beta` at k=3 missed the 3rd-best document. This reproduces on the
  1.8.6 release build.
- 2.19M corpus: 1.8.6 is exact on 26 of 28 (OR query, k) pairs. `war | peace` k=100 missed
  `11.016176` and returned `11.011106` instead. The fixed build is 28/28.
- The fix never prove-skips a block once `nread + count >= df` -- the end-of-term rule
  `wand_load_block` already uses.
- New regress test `wand_last_block` FAILS on 1.8.6 and on `af2e7e0`, and passes on the
  fixed build.

`parity_check.sh` did not catch it: its 1% quantization tolerance and its five default
shapes were not tight enough for small-k OR.

**Caveat on `parity_check.sh`:** it joins nothing; it re-scores with `fts_bm25`. The
`fts_search()` SRF returns a ctid per result, and 24 of 100 `war | peace` ctids do not
join to `docs` on this host, because the table was `UPDATE`d (HOT chains, `n_tup_hot_upd`
356,011) and the index holds root-line-pointer TIDs. Joining `fts_search().ctid` to the
heap is therefore not a valid check on an updated table. The `ORDER BY` path follows HOT
chains correctly.

## Scoreboard (ms; pg_fts run 2 `efca0cf`, pg_textsearch run 1)

| query | pg_fts 1.8.6 (09-30) | pg_fts `efca0cf` | pg_textsearch 1.4.0 | winner |
|---|---|---|---|---|
| rare k10 | 10.21 | **0.71** | 0.84 | pg_fts 1.19x |
| mid k10 | 15.99 | **0.85** | 1.07 | pg_fts 1.26x |
| common k10 | 49.16 | **11.37** | 11.40 | tie (1.00x) |
| common k100 | 50.14 | 14.67 | **13.87** | pg_textsearch 1.06x |
| exact count common | 2.50 | **0.18** | 251 s (seqscan) | pg_fts |
| AND 2-term k10 | 9.03 | **1.57** | 25.03 | pg_fts 15.9x |
| OR 2-term k10 | 10.69 | **1.54** | 24.88 | pg_fts 16.2x |
| OR 3-term k10 | 15.40 | **3.01** | 32.21 | pg_fts 10.7x |
| prefix k10 | 18.38 | **6.36** | 10.51 | pg_fts 1.65x |
| phrase k10 (positions=on) | 239 | 185 (146 after `22db379`, dev host) | **42.9** | pg_textsearch 4.3x (3.4x) |

All pass spreads are at most 4.5%, except pg_fts phrase at 7.5%. Parity is 10/10 on every
pg_fts host.

**Unexplained platform difference:** pg_textsearch's boolean bands are faster on Debian
than on the 09-30 Amazon Linux hosts (AND 37.7 -> 25.0 ms, OR2 36.9 -> 24.9, prefix 13.4
-> 10.5), with the same protocol (SET outside the timed loop in both). Its ranked bands are
unchanged (rare 0.92 -> 0.84, common 11.41 -> 11.40). This was not investigated. It means
pg_fts's boolean lead should be read against the Debian pg_textsearch numbers above, not
the 09-30 ones.

## Concurrency (tps, pass 1 / pass 2)

| band | clients | pg_fts `efca0cf` | pg_textsearch 1.4.0 |
|---|---|---|---|
| rare k10 | 16 | **11,895 / 11,968** | 8,115 / 8,153 |
| | 32 | **10,146 / 9,951** | 8,265 / 8,265 |
| | 64 | **8,278 / 8,379** | 8,209 / 8,202 |
| common k10 | 16 | 562 / 562 | **650 / 651** |
| | 32 | 559 / 560 | **669 / 669** |
| | 64 | 557 / 556 | **666 / 667** |
| exact count | 16 / 32 / 64 | **45,595 / 47,875 / 48,577** | seqscan, not measured |

All hosts are at 99.5-99.7% CPU: saturated from 16 clients on.

**Unexplained, not fixed:** pg_fts rare-term tps falls 30% from 16 to 64 clients
(11.9k -> 8.3k), and pg_textsearch's does not. A system-wide profile shows
`bm25_doclen_cursor_lookup` rising from 15% to 44% of CPU across that range. With the slot
array disabled, tps is 1,460 at both 16 and 64 clients. So the decline is specific to the
slot path under oversubscription. One candidate is cache pressure: each of 64 backends
holds its own 4.8 MB copy. That is a hypothesis, not a measurement. At 64 clients the two
engines are now even (8,278 vs 8,209).

## Remaining losses and what the profile says

- **Phrase (4.3x / 3.4x).** pg_fts still materializes the full 361k-doc phrase match set
  before ranking (collect + decode ~60% of the query). pg_textsearch ranks the bag of
  words and rechecks the phrase on candidates only. The lazy phrase gate in ROADMAP (needs
  positions reachable per doc from the WAND cursor) is the change that closes this. It was
  previously declined at a "1.5x ceiling", but with the rest of the query now 10x faster
  that ceiling no longer holds.
- **Common k100 (1.06x) and common-term concurrency (0.85x).** The remaining cost is
  per-posting candidate iteration inside `bm25_topk_candidates_range` (67%) and
  `wand_load_block` (15%). That is C2 (dense per-term containers / bitmap scoring), which
  was not attempted.
- **Ingest, build, NDCG:** not part of this benchmark. Build is unchanged (272 s build + 191
  s `fts_vacuum` vs pg_textsearch's 260 s). C1 adds ~20 ms per backend per
  directory-generation change; that was not measured under write load.

## Not done (in scope of the request, deliberately stopped)

- **C2** (dense per-term containers). Deferred until C1's oversubscription behaviour is
  understood. It also needs a format change (dual-read + in-place upgrade per
  RELEASING.md), and it cannot be qualified within the time available.
- **Lazy phrase gate.** See above.
- **No release cut.** These are commits on branch `perf-a-limit-hint`. `fts_current_distance()`
  is added to the base install script (`pg_fts--1.8.6.sql`) without a version bump; a
  release must move it into a new `--1.8.6--1.9.0.sql` upgrade script.
