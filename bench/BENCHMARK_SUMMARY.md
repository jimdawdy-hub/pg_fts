# pg_fts benchmark summary — methodology and results (as of v1.11.0, 2026-10-08)

Consolidated view of the current measurements. Every number here is traceable to a
run recorded under `bench/`; nothing is estimated. Where a figure was previously
published wrong, the correction is stated rather than quietly replaced.

---

## 1. Methodology

### Rig
**Current (1.10.0):** EC2 **r7gd.4xlarge** (AWS Graviton3 / Neoverse-V1, 16 vCPU, 128 GiB,
32 MB L3, local NVMe instance store), Debian 13 arm64, PostgreSQL **17.10** built from
source, `shared_buffers = 32GB`; full protocol in `bench/PROTOCOL_110_2026-10-07.md`.
Earlier sections were measured on EC2 **r6id.4xlarge** (Xeon 8375C @ 2.90 GHz, 16 vCPU,
128 GB RAM, 884 GB local NVMe), Amazon Linux 2023 or Debian 13 x86-64,
`shared_buffers = 64GB`; numbers from the two rigs are not compared column by column.
**One dedicated instance per engine** for comparative runs — no engine shares a host
with another.

Benchmarks run on **local NVMe, never tmpfs**, so I/O behaviour is real.

### Corpus
2,188,038 Wikipedia articles, pre-joined to exactly **two columns**
(`id bigint`, `content text`, where content = title + ' ' + body). Every engine
loads the identical file and indexes **`content` and nothing else**. Row count is
verified on every host before measuring.

This "identical single column" discipline exists because an earlier run compared
engines on *different* column sets and produced a false apples-to-apples claim
(§7).

### Timing protocol
**8 runs per query, median of the last 5.** The first 1–3 runs are discarded as
warm-up.

This is not arbitrary. An earlier protocol dropped only one cold run, which was
insufficient for two engines: pg_search reported 6.86 ms for a query whose steady
state is **2.13 ms** — a 3× error, in the direction that flattered pg_fts. The
8-run rule was adopted after that, and every arm is now re-measured by hand rather
than trusted from a subagent's summary.

### Correctness gate
`bench/parity_check.sh` compares index-returned top-k against an exact `fts_bm25`
sort over the heap, for five query shapes (single-term, AND, OR) at k=10 and
k=100. **A benchmark result is not reported unless parity passes.** This has caught
real bugs mid-optimisation, including a page-directory cursor that looked 2× faster
while returning garbage.

Match counts are cross-checked against **regex ground truth** on the raw text
(`\myear\M` etc.), not merely against the other engines.

### Profiling
`perf record -F 1999 -g` attached to the backend running a tight query loop, then
`perf report --no-children`. Where cost attribution mattered, it was confirmed with
**explicit counters compiled into the extension**, not inferred from the profile
alone.

---

## 2. Comparative latency

### 2a''''. Current: pg_fts 1.11.0 vs 1.10.0 and the field (2026-10-07/08, aarch64)

`bench/RESULTS_A_2026-10-07.md` (protocol `bench/PROTOCOL_A_2026-10-07.md`, written before
the run; raw data `bench/data_A_2026-10-07/run/`).  Same rig and corpus as 1.10.0; pg_fts
1.10.0 and 1.11.0 measured on one host, against the same index files,
after a correctness gate (identical results, and an exhaustive reference on every band).
Measured at commit 39b6a42; the 1.11.0 release adds, after that commit, the VACUUM pending-delete fix and the four
concurrency fixes (CHANGELOG 1.11.0), which change the write, flush, free and truncate paths
and not the query traversals.  Timings were not re-run on the release binary (unmeasured); on a
600k-row index built locally, 39b6a42 and the release give identical sizes after build, VACUUM
and merge, and identical counts and top-20 on five bands
(`data_A_2026-10-07/release/size_results_39b6a42_vs_release.txt`).

| ms, single client | pg_fts 1.11.0 | pg_fts 1.10.0 | pg_textsearch | pg_search | VectorChord |
|---|---|---|---|---|---|
| rare / mid top-10 | **0.64 / 0.43** | 1.07 / 0.83 | 0.99 / 1.21 | 2.66 / 2.27 | 20.4 / 36.8 |
| common top-10 / top-100 | **0.81 / 1.30** | 8.48 / 8.77 | 10.71 / 13.06 | 2.63 / 5.51 | 84.5 / 86.8 |
| AND / OR top-10 (rare) | **1.38 / 1.84** | 2.15 / 2.11 | >300 s (seq scan) | 3.45 / 3.75 | n/a / 12.6 |
| AND `united & states` / `world & war` | **2.71** / 5.98 | 23.89 / 19.12 | >300 s | 11.97 / **5.73** | n/a |
| 4-term OR | 13.99 | wrong result | 14.98 | **13.92** | 50.9 |
| phrase `"united states"` / `"world war"` | **3.55 / 6.84** | 24.95 / 19.79 | >300 s | 12.08 / 11.95 | n/a |
| exact count | **0.19** | 0.21 | n/a | 10.56 | n/a |

| tps at 16 / 32 / 64 clients | pg_fts 1.11.0 | pg_fts 1.10.0 | pg_textsearch | pg_search | VectorChord |
|---|---|---|---|---|---|
| rare top-10 | **26,750 / 26,341 / 26,338** | 17,496 / 17,328 / 17,274 | 13,355 / 12,165 / 12,157 | 5,147 / 5,360 / 5,998 | 334 / 593 / 667 |
| mid top-10 | **35,304 / 34,407 / 34,328** | 20,414 / 20,142 / 20,146 | 10,811 / 9,976 / 9,904 | 5,987 / 6,439 / 6,789 | 175 / 323 / 359 |
| common top-10 | **22,369 / 21,984 / 21,590** | 1,911 / 1,883 / 1,875 | 1,176 / 1,232 / 1,236 | 5,241 / 5,379 / 5,951 | 59 / 102 / 119 |
| exact count | **75,381 / 70,724 / 69,584** | 66,912 / 63,164 / 61,214 | n/a | 773 / 2,004 / 2,547 | n/a |

pg_fts throughput: two settled runs per arm (order 110, dev, dev, 110), median of 4 passes;
same-arm runs within 4%.  Others: the in-run measurement (in 1.10.0 in-run and settled
agreed within 8% for each).  Cold cache (local NVMe, median of 5): dev 41-64 ms against
1.10.0's 49-90 ms on the same three bands (`RESULTS_A`, cold table).

### 2a'''. 1.10.0 release: pg_fts 1.10.0 vs pg_textsearch 1.5.1, pg_search 0.26.0, VectorChord-bm25 0.3.0 (2026-10-07, aarch64)

`bench/RESULTS_110_2026-10-07.md` (method, raw data, install logs). One r7gd.4xlarge
per engine, latest release of each, documented English-stemmed index and query form.

| ms, single client | pg_fts | pg_textsearch | pg_search | VectorChord |
|---|---|---|---|---|
| rare / mid top-10 | 1.16 / **1.05** | **1.00** / 1.22 | 2.35 / 2.02 | 20.4 / 36.9 |
| common top-10 / top-100 | 8.50 / 8.77 | 10.71 / 13.06 | **2.44 / 5.31** | 82.8 / 86.2 |
| AND / OR top-10 | **2.16 / 2.10** | >300 s / >300 s (seq scan) | 3.12 / 3.22 | n/a / 12.45 |
| phrase top-10 | 36.85 | >300 s | **11.26** | n/a |
| exact count | **0.21** | n/a | 9.88 | n/a |

| tps at 16 / 32 / 64 clients | pg_fts | pg_textsearch | pg_search | VectorChord |
|---|---|---|---|---|
| rare top-10 | **17,051 / 16,852 / 16,841** | 14,131 / 13,145 / 12,397 | 5,373 / 5,834 / 6,227 | 346 / 615 / 671 |
| mid top-10 | **17,447 / 17,297 / 17,217** | 11,427 / 10,709 / 10,236 | 6,133 / 7,002 / 6,595 | 222 / 334 / 360 |
| common top-10 | 1,907 / 1,879 / 1,863 | 1,218 / 1,256 / 1,256 | **4,783 / 4,950 / 5,487** | 65 / 118 / 128 |
| exact count | **66,150 / 62,707 / 61,597** | n/a | 750 / 1,961 / 2,492 | n/a |

Index: pg_fts 1,421 MiB, pg_textsearch 1,887, pg_search 3,396, VectorChord 42,434 (its
corpus-trained vocabulary; see the results file before reading anything into it).
The I6 fix in isolation (same host and binary, shared copy on vs off): rare-term tps at
64 clients 16,654 vs 13,283 (+25%), mid-term +21-25% at every client count, common +1-3%.

### 2a''. Historical: pg_fts 1.9.1 vs pg_textsearch 1.4.0 (2026-10-06, Debian 13 x86-64, same-day control)

`bench/RESULTS_191_2026-10-06.md`. ms: rare **0.68** vs 0.85, mid **0.78** vs 1.07, common
k10 **7.0** vs 11.5, common k100 **7.2** vs 13.9, count **0.18** vs seqscan, AND **1.47**
vs 41.1, OR2 **1.48** vs 26.4, OR3 **2.76** vs 32.1, prefix **5.82** vs 10.5, phrase
(`positions=on`) **34.8** vs 43.0. tps at 16 clients: rare **12,696** vs 8,142, common
**944** vs 646. Rare-term tps falls to 8,757-8,931 at 64 clients (pg_textsearch 8,202):
known issue, cause measured (ROADMAP I6). Index 1,421 MB vs 1,978 MB.

### 2a'. Historical: pg_fts 1.9.0 vs pg_textsearch 1.4.0 (2026-10-01, Debian 13)

`bench/RESULTS_190_2026-10-01.md`. ms: rare **0.67** vs 0.84, mid **0.79** vs 1.07, common
k10 **7.19** vs 11.40, common k100 **7.37** vs 13.87, count **0.19** vs seqscan, AND **1.51**
vs 25.0, OR2 **1.46** vs 24.9, OR3 **2.79** vs 32.2, prefix **6.21** vs 10.5, phrase 138 vs
**42.9**. tps at 16 clients: rare **12,412** vs 8,115, common **968** vs 650, count 45,694.
Rare-term tps falls to 8,590 at 64 clients (pg_textsearch 8,209): known issue.

### 2a. Historical: pg_fts 1.8.6 vs pg_textsearch 1.4.0 (2026-09-30)

Same rig, corpus (md5-identical TSV on every host) and 8-run protocol, plus 3 independent
passes per band. Both engines use `ORDER BY` query forms. `bench/RESULTS_PGTS_2026-09-30.md`.

| query | pg_fts 1.8.6 | pg_textsearch 1.4.0 |
|---|---|---|
| rare k10 | 10.21 | **0.92** |
| mid k10 | 15.99 | **1.17** |
| common k10 | 49.16 | **11.41** |
| common k100 | 50.14 | **13.75** |
| exact `count(*)` common | **2.50** | 251 s (seqscan) |
| AND 2-term k10 | **9.03** | 37.69 |
| OR 2-term / 3-term k10 | **10.69 / 15.40** | 36.94 / 31.79 |
| prefix k10 | 18.38 | **13.41** |
| phrase k10 | 239 (`positions=on`) | **41.8** |

At 16/32/64 clients both engines saturate the 8-core host (flat tps). Rare k10 is
1,050 vs **8,130** tps, common k10 205 vs **640**, and exact count **2,645** tps vs none.
Match counts identical on both engines (10,875 / 24,097 / 734,896); pg_fts parity 10/10.
pg_textsearch got 8x faster on rare since September; pg_fts is unchanged since 1.6.1.

### 2b. Historical: 4 engines, identical corpus (2026-09-06)

> **Query-form caveat (CHANGELOG 1.8.6, Retracted):** the pg_fts column below was
> measured with `fts_search()`, the competitors with `ORDER BY` forms. On the same
> `ORDER BY ... LIMIT` form pg_fts is ~10.2 / 16.0 / 48 ms (rare / mid / common k10), not
> 5.89 / 10.64 / 36.16. Measured on 1.6.1 and 1.8.6 alike (`data_pgts_2026-09-30/form_*`).

Median ms, warm. pg_fts figures are **v1.6.0**; the three competitors were measured
in the 5-way run (`bench/RESULTS_5WAY_159b_2026-09-06.md`) and are unchanged since,
as neither 1.5.10 nor 1.6.0 touched their hosts.

| query | **pg_fts 1.6.0** | pg_textsearch | pg_search | vchord |
|---|---|---|---|---|
| rare k10 (`slovakia`, df 10,875) | **5.89** | 7.36 | 2.13 | 2.48 |
| mid k10 (`hungary`, df 24,097) | 10.64 | **7.96** | 2.04 | 2.40 |
| common k10 (`year`, df 734,896) | 36.16 | 20.71 | **2.12** | 3.49 |
| common k100 | 46.01 | 50.71 | **3.72** | 24.52 |
| exact `count(*)` common | **2.20** | N/A | 13.63 | N/A |
| AND 2-term | 4.38 | N/A | **3.17** | N/A |
| OR 2-term | 4.12 | N/A | 3.35 | N/A |
| OR 3-term | 6.80 | N/A | **4.35** | N/A |
| prefix | 5.27 | N/A | **2.05** | N/A |
| phrase (`positions=on`) | 229 | N/A | **22.9** | N/A |

Common k10/k100 improved 1.56×/1.52× in 1.5.10; rare, mid and OR were flat. 1.6.0
is correctness-only and changed no latency.

### Index size and build

| | **pg_fts** | pg_textsearch | pg_search | vchord |
|---|---|---|---|---|
| index size | **1,421 MB** | 1,887 MB | 2,734 MB | 2,902 MB |
| build time | 381 s | 496 s | **127 s** | **56 s** |

pg_fts has the **smallest index in the field** — 25% under the next best, 2.0×
smaller than vchord. It is also the slowest to build of the three that stem.

### Match-count agreement (the fairness check)

| term | pg_fts | vchord | pg_textsearch | pg_search |
|---|---|---|---|---|
| slovakia | 10,875 | 10,875 | 10,875 | 10,853 |
| hungary | 24,097 | 24,097 | 24,097 | 23,990 |
| **year** | **734,896** | **734,896** | **734,896** | **495,580** |

**Three of four engines agree byte-for-byte.** pg_search is 33% low on `year`
because **Tantivy's default tokenizer does not stem** (0.26.0 with `stemmer=english`
counts 735,955 -- see §2a'''); regex ground truth confirms `\myears?\M` =
733,960, i.e. ours is the correct English set. So pg_fts scans ~48% more postings
than pg_search on that query *and* returns the right answer — worth holding in mind
when reading the common-term row.

---

## 3. Where the time goes — profile of the shipped build

`perf` on v1.6.0 (`bench/RESULTS_GATING_2026-09-09.md`):

| band | doclen (`load_page` + `lookup`) | `topk_candidates_range` | `wand_load_block` |
|---|---|---|---|
| rare | **68.9%** (64.4 + 4.5) | 6.8% | — |
| mid | **71.6%** (65.8 + 5.8) | 6.0% | — |
| common | **45.2%** (28.3 + 16.9) | 37.2% | 6.4% |

**The doclen sidecar path dominates every band.** This corrected a split previously
quoted ("39% candidates / 43% doclen") that had never been captured from a real run
on the shipped build.

What remains in `load_page` is the **gap-decode prefix**: sidecar docids are
delta-encoded, so reaching an arbitrary offset means walking from entry 0 —
measured at **60–82 entries per probe**. That is a property of the format, not an
inefficiency, which is why the cheaper fixes were tried and rejected (§6).

Ceiling if a format change allowed a mid-block start (halving the prefix): rare
5.89 → ~3.99 ms, mid 10.64 → ~7.14 ms ≈ **1.5×** on the two bands the field
actually queries.

---

## 4. Phrase queries — a 36× configuration cliff

`bench/NOTE_PHRASE_PROFILE_2026-09-06.md`. `WITH (positions = on)` defaults to
**off**; without it a phrase cannot be verified from the index and the scan falls
back to AND + a heap recheck of every candidate.

| query | `positions=off` (default) | `positions=on` | speedup |
|---|---|---|---|
| ranked top-10 `"united states"` (361,465 matches) | **8,385 ms** | **229 ms** | **36.6×** |
| ranked `"new york"` | 4,853 ms | 129 ms | 37.7× |
| ranked `"world war"` | 4,347 ms | 119 ms | 36.5× |
| exact phrase `count(*)` | 7,170 ms | **132 ms** | **54.3×** |
| index size | 1,421 MB | 2,626 MB (1.85×) | — |

Profiling the tuned path shows the adjacency test itself is only **4.3%** of the
query; 21% is materialising the full match set before ranking. A lazy phrase gate
was designed and **declined**: ceiling ~1.5× (229 → ~150 ms), which does not close
the gap to pg_search's 22.9 ms, in exchange for changes to a hot scan path that has
already produced three crash-fix releases.

Note also that phrase syntax needs **double** quotes; single quotes yield a plain
conjunction. That mistake produced a wrong published number (§7).

---

## 5. Build and maintenance measurements

### `maintenance_work_mem` decides whether you pay for a merge at all
(`bench/RESULTS_GATING_2026-09-09.md`)

| `maintenance_work_mem` | build | segments after build | follow-up merge | final index |
|---|---|---|---|---|
| 64MB (PostgreSQL default) | 475 s | 8 | 216 s | 8,613 MB |
| 256MB | 367 s | 6 | 223 s | 5,793 MB |
| **1GB** | 523 s | **1** | **none needed** | 4,605 MB |
| **2GB** | 527 s | **1** | **none needed** | 4,323 MB |

At ≥1GB this corpus builds straight to one segment and the merge disappears. At the
64MB default it needs 8 segments plus a 216 s merge and lands **twice as large**.

### Parallel merge is a regression
(`bench/RESULTS_PARALLEL_MERGE_2026-09-08.md`)

| configuration | merge time | resulting index |
|---|---|---|
| serial (2 runs) | **230.6 s** | 8,606 MB |
| parallel W=3 / W=1 (3 runs) | **333.5 s** | 10,229 MB |

**1.45× slower and 19% larger**, with W=1 costing the same as W=3 — a fixed penalty
for taking the path, not a scaling curve. Correctness unaffected (all runs converged
to one segment with identical match counts).

A trap found while measuring: at `max_parallel_maintenance_workers = 8` the workers
register, start and **exit within ~2 ms**, so the merge silently runs *serially* —
confirmed with postmaster `DEBUG1`. Those runs looked fast because they were the
serial path.

### Parallel build: faster, and NOT durably larger (corrected 2026-09-09)

An earlier sweep reported parallel builds as ~17% larger. **That was measured before
`fts_vacuum` and is wrong as a durable claim.** Re-measured with the vacuum step, in
an isolated database, at `maintenance_work_mem=1GB`
(`bench/data_gating_2026-09-09/vacuum_comparison.log`):

| workers | pre-vacuum | **post-vacuum** | segments | `year` count |
|---|---|---|---|---|
| 0 (serial) | 4,605 MB | **1,420 MB** | 1 | 734,896 |
| 4 | 5,365 MB | **1,420 MB** | 1 | 734,896 |

**Post-vacuum sizes are identical.** A parallel build is faster (464 s vs 523 s at
1GB) and leaves *more reclaimable residue*, not a bigger index. Both converge to the
same 1,420 MB floor with identical match counts.

Why the residue exists at all, and why it is not a bug: merge output is allocated
**extend-only** on purpose (`pg_fts_am.c:4665-4672`) so that a committed merge's
freed input pages cannot be recycled as the next merge's output while in-flight read
chains still thread through them -- the comment is explicit that the alternative is
"a wrong read or a SIGBUS". `bm25_truncate_free_tail` then reclaims only a
*contiguous* free tail (`:4446-4449`, it breaks at the first live block from EOF), so
freed pages buried under the final output survive until a compaction pass relocates
live data downward. Measured on a serial build: 4,406 MB file, 173,529 live pages
(1,355 MB), 390,483 freed pages -- and live pages **98.8% full**, with 173,521 of
173,529 above 90%.

**So the original "per-worker partial pages" hypothesis is disproven twice over** --
empirically (pages are ~99% full) and arithmetically (a segment writes at most ~4
chain-tail partial pages, bounding total slack at ~4 MB against measured deltas of
781-1,623 MB). See `bench/DIAG_WORKER_FRAGMENTATION.md` and
`bench/REVIEW_WORKER_FRAGMENTATION.md`.

**Operational rule: run `fts_vacuum` once after a large build, and do not judge
index size before you do.**

### Sparsemap tombstone filter (partial)
At zero tombstone density, three separately compiled arms (stock / batched
`sm_contains_many` / resume cursor) merge in 231.6 / 233.7 / 233.2 s with a
**byte-identical** output index — 0.9% spread, so the batched filter is not a
regression. **The delete-heavy half is unmeasured**: the rig's suppression control
turned out not to exist in our source.
`bench/RESULTS_SPARSEMAP_2026-09-08.md`.

### Delete-heavy VACUUM, sparsemap 5.7.0 vs 5.8.0 (1.8.5 vs 1.8.6)
On 5M rows, VACUUM after the second and third large delete rounds takes 33.1-33.3 s ->
21.5-23.1 s (~30%), and after the first round 151 s -> 138 s (8.5%). Build time is
unchanged (382-389 s on both). Two runs per arm, same-arm spread under 1%; counts match
seqscan and each other at every step; final index byte-identical in size.
`bench/RESULTS_SPARSEMAP58_2026-09-30.md`.

---

## 6. Hypotheses tested and rejected

Recorded so they are not retried. Each was disproven by measurement, not opinion.

| idea | why rejected |
|---|---|
| Precomputed per-block max score | Measured true block max **equals** the existing `impact(max_tf, min_dl)` bound to 4 decimals — gains nothing |
| Finer (16-posting) block granularity | Lowers the max only 3.7–4.6%, still above threshold |
| Tune k to improve pruning | Pruning identical at k=1/10/100 |
| df-threshold bulk doclen load | Cost is ~linear in df with **no fixed floor**; the smallest term is already at the plain `@@@` floor |
| Lazy/partial per-entry block decode | Made rare **worse** (5.83 → 7.74 ms). `bm25_for_get` was bit-at-a-time, and the "71× amplification" that motivated it was an arithmetic artifact of ours — the sidecar is keyed by *all* docids, so ~64–82 entries per probe are unavoidable prefix, not waste |
| LRU of decoded doclen blocks | WAND ascends monotonically, so a cursor never revisits a block. Reframed into the per-segment sharing that shipped in 1.5.9 (1.4–1.6× on multi-term) |
| Parallel ranked scan | Built, verified byte-exact, **reverted**: ~30% Amdahl ceiling and workers refused to launch inside `ExecCustomScan`. Re-analysed post-1.5.10: best case ~8.3 ms vs pg_search 2.12 |
| Impact-ordered postings | Breaks the docid ordering `count(*)`/AND/phrase/prefix depend on; implies a second posting layout, spending our size lead |
| Heap-side `positions=off` | Saves exactly `4 × doclen` (~16% of a short doc), and `ftsdoc` is `STORAGE = extended`, so the real delta is the compressed one |
| Lazy phrase gate | Ceiling ~1.5×; the adjacency test is only 4.3% of the query |

---

## 7. Published corrections

Kept because the corrections are part of the result.

1. **Indexed columns were not uniform** in an early 5-way. Corrected, then re-run on
   an identical single column.
2. **"pg_fts scans 48% more postings"** was first attributed to that column
   mismatch; the identical-column run disproved it and found the real cause
   (Tantivy not stemming).
3. **Phrase "90.70 ms" was not a phrase** — written with single quotes, it parsed to
   a plain conjunction. Real numbers in §4.
4. **pg_search's medians were 3× too slow** in one run (insufficient warm-up),
   flattering pg_fts. Fixed by the 8-run protocol.
5. **"39% candidates / 43% doclen"** was never measured on the shipped build; the
   real split is §3.
6. **"rare/mid at their floor"** understated the remaining opportunity — reasoned
   from the common profile where `load_page` is 28%, not the ~65% it is on rare/mid.

---

7. **"pg_search is 3.5x faster on common-term ranking, and the gap is architectural
   (scalar postings vs bitmap + SIMD)"** (1.10.0 and earlier).  The gap was pg_fts's
   traversal: best-first block order with exact block bounds makes the common-term
   top-10 0.81 ms against pg_search's 2.63 on the same rig (2a'''').  Retracted in the
   CHANGELOG (1.11.0).
8. **The 1.10.0 build time (298 s + 200 s `fts_vacuum`)** timed a build on a pre-filled
   column (the 995 s fill was not counted); the comparable expression-index figure is
   412 s + 198 s.

---

## 7a. Coverage gaps — what this document does not measure

Measured as of 1.10.0: single-client latency, **concurrent throughput** (16/32/64
clients, all four engines), index size, build time, and match-count correctness.
Still unmeasured: **ingest/update throughput**, **cold-cache (disk-bound) latency**,
and **ranking quality (NDCG) vs rivals**. All four engines put 6-10 of the same
documents in each top-10, so relevance differences are about near-ties, but that is
not a quality measurement.

## 8. Honest summary (1.11.0, aarch64, 2026-10-08)

**Strengths.** Lowest ranked latency and highest throughput of the four at every term
frequency: rare 0.64 ms / 26.8k tps, common 0.81 ms / 22.4k tps (pg_search 2.63 ms /
5.2k).  Conjunctive queries and phrases walk the rarest term best-first: `united & states`
2.71 ms, `"united states"` 3.55 ms (pg_search 11.97 / 12.08).  Index-native exact count,
smallest index, PostgreSQL's own stemming, widest query language.  A plain build needs
no `fts_vacuum` (257 s as an expression index, 1.6x faster than 1.10.0's 412 s, which
also needed 198 s of `fts_vacuum`).

**Weaknesses.** pg_search builds 3.6x faster (71 s).  On `world & war` (both terms
frequent, with good documents in many blocks) and on a 4-term OR, pg_search is within 5%.
Phrase still needs `positions = on` (an 85% larger index).  Not measured: x86 for this
run, network storage, relevance quality.

**The 1.10.0 summary below stands for the 1.10.0 release.**

### 1.10.0 (aarch64, 2026-10-07)

**Strengths.** Fastest rare- and mid-frequency ranked retrieval under load, and the only
engine of the four whose rare-term throughput is flat from 16 to 64 clients (17.1k ->
16.8k tps; pg_textsearch 14.1k -> 12.4k, pg_search 5.4k -> 6.2k). Boolean AND/OR ranked
in the index (2.1 ms; pg_textsearch's boolean filter is a sequential scan, >300 s on
2.19M rows). Index-native exact `count(*)` (0.21 ms; pg_search 9.88 ms, the other two
cannot). Smallest index (1,421 MiB; 25% under pg_textsearch, 58% under pg_search).
Correct English stemming (PostgreSQL's own `english` config). Widest query language.

**Weaknesses.** Common-term ranked top-k: pg_search is 3.5x faster single-client and
2.5-3.0x under load (Tantivy's block-max skipping over bitmap postings vs pg_fts's
scalar postings -- architectural, ROADMAP D). Phrase: pg_search is 3.3x faster, and
pg_fts needs `positions=on` (an 85% larger index) to be usable at all. Build: pg_search
is 4x faster (71 s vs 298 s + `fts_vacuum`). pg_textsearch is 14% faster on a single
rare-term query (1.00 vs 1.16 ms) though slower under load.

**Comparator note.** pg_textsearch remains the closest comparison -- same PostgreSQL
`english` configuration, byte-identical match counts, same C-extension model. pg_search
now stems (`stemmer=english`); its counts are within 0.3% of the regex ground truth, so
the earlier "Tantivy does not stem" caveat no longer applies to 0.26 with a stemmer
configured. VectorChord-bm25 was measured with the setup its tokenizer documents for
English; its 41 GB index and ~42k buffer reads per query suggest that setup does not
suit a 2.19M-article corpus, so its numbers are reported but not used to characterize
it.
