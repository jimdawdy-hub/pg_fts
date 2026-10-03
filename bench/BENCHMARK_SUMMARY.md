# pg_fts benchmark summary — methodology and results (as of v1.9.0, 2026-10-01)

Consolidated view of the current measurements. Every number here is traceable to a
run recorded under `bench/`; nothing is estimated. Where a figure was previously
published wrong, the correction is stated rather than quietly replaced.

---

## 1. Methodology

### Rig
EC2 **r6id.4xlarge** (Xeon 8375C @ 2.90 GHz, 16 vCPU, 128 GB RAM, 884 GB local
NVMe instance store), Amazon Linux 2023, PostgreSQL **17.10** built from source,
`shared_buffers = 64GB`. **One dedicated instance per engine** for comparative
runs — no engine shares a host with another.

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

### 2a'. Current: pg_fts 1.9.0 vs pg_textsearch 1.4.0 (2026-10-01, Debian 13)

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
because **Tantivy does not stem**; regex ground truth confirms `\myears?\M` =
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

## 7a. Coverage gaps — what this document does not measure

See `bench/COVERAGE_AUDIT_2026-09-10.md`. In short: everything above is
**single-client latency, size and correctness**. Three standard axes are unmeasured —
**concurrent throughput** (rival data exists, our own arm's file is truncated and its
latency is 1.5.0-era), **ingest/update throughput**, and **ranking quality vs rivals**.
On the throughput axis the rivals differ sharply from each other (vchord's tps
collapses under concurrency where pg_textsearch and pg_search scale), so this is not a
formality — it could move the overall story either way, and a 2x single-client gap
would matter far less than a throughput cliff.

## 8. Honest summary

**Strengths.** Smallest index in the field (1,421 MB, 25% under next best). Fastest
exact `count(*)` (2.20 ms — 6× pg_search; pg_textsearch 1.4.0 can now count, but only by
seqscan, 251 s). Multi-term boolean ranked beats pg_textsearch 1.4.0 2-4x. Correct
English stemming, verified against regex ground truth. Widest query language by a
large margin (see `CAPABILITIES.md` and the feature matrix).

**Weaknesses.** Common-term ranked top-k (36.16 ms vs pg_search 2.12) — the largest
remaining gap, now understood as doclen gap-decode and addressable only by a sidecar
format change worth ~1.5×. Phrase needs a non-default option to be usable at scale,
and even tuned is ~10× off pg_search. Parallel merge is a regression; parallel build
trades size for speed. Big-endian is untested in CI (sparsemap 5.5.0 fixed a
corruption that reached our tombstone iteration).

**Comparator note.** `pg_textsearch` is the fairest reference point — same
PostgreSQL `english` config, byte-identical match counts, same C-extension model.
Against **v1.4.0** (2026-09-30), pg_fts is 11x slower on rare, 14x on mid and 4.3x on
common k10; 2-4x faster on AND/OR; 25% smaller; and the only one of the two with an
index-backed count, NEAR, fuzzy and regex. The September claim "faster on rare" compared
different query forms and is retracted. The larger deficits are against the two engines shipping their own
posting formats — one of which does not stem.
