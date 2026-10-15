# Feature comparison matrix — pg_fts vs PostgreSQL BM25 alternatives

Scope: **PostgreSQL-embedded BM25 full-text search extensions**, plus built-in
`tsvector`/GIN as the baseline everyone already has. Compiled 2026-09-09 against
pg_fts **v1.6.0**.

Competitor rows reflect **what we exercised in our own benchmark runs** (see
`bench/BENCHMARK_SUMMARY.md` and `bench/data_5way_159b/`), not vendor claims. Where
a capability was not exercised, it is marked *untested* rather than guessed.

Versions measured: pg_textsearch **v1.4.0** (head-to-head 2026-09-30, `bench/RESULTS_PGTS_2026-09-30.md`; earlier columns `f940210`); pg_search (ParadeDB) 0.25.6 /
paradedb `c807ede`; VectorChord-bm25 `14fc2a3`.

Legend: **Yes** = exercised and working · **No** = absent · *n/t* = not tested by us

## Not in this matrix: TIN (PlanetScale)

**TIN is deliberately absent from every table below, because it cannot be obtained.** It
is a closed extension available only inside PlanetScale's managed Postgres: there is no
public repository (`github.com/planetscale/tin` is 404), no source or package referenced in
its documentation, and no TIN backend even in PlanetScale's own public fork of the
benchmarker they used. Installation instructions direct you to update *your PlanetScale
cluster*.

So its capabilities cannot be exercised here and its published numbers cannot be
reproduced or contested by anyone outside PlanetScale. Adding a TIN column with vendor
figures would violate the rule this document is built on — competitor rows reflect what we
ran ourselves. An architectural comparison, based on reading their published design in
full, is in `bench/NOTE_VS_TIN_2026-09-14.md`; the short version is that TIN's headline
architectural argument (use `ctid` as the posting identifier, so merges never renumber) is
a design **pg_fts already implements**, while its two-level bitmap + AVX-512 execution
engine is a genuine advantage over our scalar delta-packed postings.

---

## Query capability

| Capability | pg_fts | pg_textsearch | pg_search | vchord | tsvector/GIN |
|---|---|---|---|---|---|
| BM25 ranked top-k | **Yes** | Yes | Yes | Yes | No (ts_rank is not BM25) |
| Boolean match predicate (AND/OR/NOT) | **Yes** | Yes (1.x: `@@ tsquery` filter, then sort) | Yes | **No** (ranking only) | Yes |
| Exact `count(*)` of a match set | **Yes** (index-native) | Yes, but seqscan (`@@`; 251 s on 2.19M rows) | Yes | **No** | Yes (heap/bitmap) |
| Phrase queries | **Yes** | Yes (1.x: `<->` filter + recheck) | Yes (`###`) | No | Yes (`<->`) |
| NEAR / proximity with distance | **Yes** | No | *n/t* | No | Yes (`<N>`) |
| Prefix terms (`term*`) | **Yes** | Yes (1.x: `:*` filter) | Yes | No | Yes |
| Fuzzy terms (Levenshtein) | **Yes** (`term~k`, DFA) | No | *n/t* | No | No |
| Regex terms | **Yes** (`/re/`) | No | *n/t* | No | No |
| BM25 variants (lucene/robertson/atire/bm25+/bm25l) | **Yes** | No | No | No | n/a |
| BM25F multi-field weighting | **Yes** | No | *n/t* | No | No |
| Field zones / weighted sections | **Yes** (`term:A`) | No | *n/t* | No | Yes (setweight) |
| Highlight / snippet | **Yes** | No | *n/t* | No | Yes (ts_headline) |
| Index-maintained corpus stats (N, avgdl, df) | **Yes** | No public API | *n/t* | No | No |
| Lexical anomaly detection | **Yes** | No | No | No | No |
| `tsquery` migration path | **Yes** (cast + helper) | n/a | No | No | n/a |

**Read:** query-language breadth is pg_fts's widest margin. pg_textsearch 1.x added
boolean/phrase/prefix as a `@@ tsquery` filter over its ranked scan (not index-native,
per its own README), and still has no NEAR, fuzzy or regex; vchord is ranking-only by design (no boolean or count support at
all); pg_search is the only competitor with comparable breadth.

## Correctness and semantics

| Property | pg_fts | pg_textsearch | pg_search | vchord |
|---|---|---|---|---|
| Uses PostgreSQL `english` text-search config | **Yes** | Yes | **No** (Tantivy) | Yes |
| English stemming applied | **Yes** | Yes | **No** | Yes |
| Match counts agree with the other stemming engines | **Yes** (byte-identical) | Yes | **No** (−33% on `year`) | Yes |
| Exact top-k (verified against a heap sort) | **Yes** (`parity_check.sh`, 10 cases) | *n/t* | *n/t* | *n/t* |
| Unverifiable phrase behaviour | **false** (matches PG `OP_PHRASE`) | n/a | *n/t* | n/a |
| MVCC-correct deletes | **Yes** (tombstones) | *n/t* | *n/t* | *n/t* |
| WAL-logged / crash-safe | **Yes** (all writes via GenericXLog) | *n/t* | *n/t* | *n/t* |
| Physical-replication safe (failover tested) | **Yes** (`t/002`) | *n/t* | *n/t* | *n/t* |

**Read:** stemming depends on configuration. pg_search's default tokenizer does not stem:
in the September measurement `year` matched 495,580 documents where the English answer is
734,896 (regex on the raw text), so part of its speed then came from a smaller unit of
work. With `stemmer=english` (0.26.0, 2026-10-07) it matches 735,955, within 0.3% of the
regex, and the current comparison below uses that configuration.

## Performance (2.19M Wikipedia articles, identical single column)

| Measure | pg_fts | pg_textsearch | pg_search | vchord |
|---|---|---|---|---|
| **Index size** | **1,421 MB** | 1,887 MB | 2,734 MB | 2,902 MB |
| Build time | 381 s | 496 s | **127 s** | **56 s** |
| rare k10 | 5.89 ms (`fts_search`) | 7.36 | 2.13 | 2.48 |
| mid k10 | 10.64 | 7.96 | 2.04 | 2.40 |
| common k10 | 36.16 | 20.71 | **2.12** | 3.49 |
| common k100 | 46.01 | 50.71 | **3.72** | 24.52 |
| exact `count(*)` | **2.20 ms** | — | 13.63 | — |
| phrase (tuned) | 229 ms | — | **22.9** | — |

**Caution: the pg_fts column above used `fts_search()`; the competitors used `ORDER BY`
forms** (see the retraction in CHANGELOG 1.8.6). pg_fts and pg_textsearch have both moved
since. Current head-to-head, 2026-10-09: all four engines at their latest release, one
AWS r7gd.4xlarge (Graviton3) per engine, Debian 13 arm64, PostgreSQL 17.10, each engine's
documented English index and query form, the same night.  pg_fts is the **1.11.0 release**
built from its PGXN zip (`bench/RESULTS_111_2026-10-09.md`; the 1.10.0 comparison:
`bench/RESULTS_A_2026-10-07.md`):

| Measure | pg_fts 1.11.0 | pg_textsearch 1.5.1 | pg_search 0.26.1 | VectorChord-bm25 0.3.0 |
|---|---|---|---|---|
| rare / mid top-10 | **0.57 / 0.42 ms** | 0.99 / 1.21 | 2.59 / 2.27 | 13.6 / 26.6 |
| common top-10 / top-100 | **0.72 / 1.15** | 10.69 / 13.01 | 2.63 / 5.46 | 72.4 / 78.0 |
| AND / OR top-10 (rare terms) | **1.16 / 1.68** | >300 s (seq scan) | 3.31 / 3.58 | n/a / 7.90 |
| AND top-10, `united & states` / `world & war` | **2.49** / 5.87 | >300 s | 11.61 / **5.75** | n/a |
| 4-term OR top-10 | 13.97 | 14.63 | **13.40** | 42.4 |
| phrase top-10 `"united states"` / `"world war"` | **2.84 / 6.45** | >300 s | 11.41 / 11.54 | n/a |
| exact `count(*)` | **0.18 ms** | n/a | 8.64 | n/a |
| tps, rare top-10, 16 / 64 clients | **24,696 / 25,431** | 14,259 / 12,595 | 5,364 / 6,291 | 366 / 875 |
| tps, common top-10, 16 / 64 clients | **19,359 / 19,507** | 1,321 / 1,267 | 5,327 / 5,959 | 73 / 138 |
| index size | **1,421 MiB** (1,369 as expression index) | 1,887 MiB | 3,395 MiB | 42,434 MiB |
| build (expression index, analysis included) | 238 s, no `fts_vacuum` | 267 s | **72 s** | 209 s (+ 3,246 s tokenize/model) |

**1.12.0** (2026-10-09, `bench/RESULTS_112_2026-10-09.md`) halves single-term ranked latency
and raises ranked throughput 42-97% over the 1.11.0 column above, with identical results;
the competitors were not re-measured against it, so the table stays the 1.11.0 run.

**Read:** 1.11.0 leads ranked latency and throughput at every term frequency, conjunctive
queries and phrases, exact counts and index size.  pg_search builds 3.3x faster and is
2% faster on `world & war` (spreads overlapping) and 4% on a 4-term OR.  pg_textsearch is
close on a single rare term, but its boolean and phrase forms scan the table.  VectorChord's
results reflect the tokenizer setup it documents for English, which built a 41 GB index
here.

## Operational surface

| Property | pg_fts | pg_textsearch | pg_search | vchord |
|---|---|---|---|---|
| Requires `shared_preload_libraries` | **No** (verified: every benchmark/test cluster ran without it, and the `FtsCount` CustomScan pushdown still fires) | **Yes** | **Yes** | **Yes** |
| Pure C (no Rust toolchain to build) | **Yes** | Yes | No (Rust/pgrx) | No (Rust/pgrx) |
| Extra build dependencies | none | none | openblas, pgvector, pgrx | pgrx |
| Incremental maintenance (no REINDEX to add rows) | **Yes** (pending list) | *n/t* | *n/t* | *n/t* |
| `CREATE INDEX CONCURRENTLY` | **Yes** (verified) | *n/t* | *n/t* | *n/t* |
| Parallel index build | **Yes** (faster; no durable size cost) | Yes (5 workers, 260 s) | *n/t* | *n/t* |
| Parallel scan | No (built, measured, reverted) | *n/t* | *n/t* | *n/t* |
| Managed-service safe (replica guard, privileges) | **Yes** | *n/t* | *n/t* | *n/t* |
| Non-UTF-8 server encodings | **Yes** (fixed 1.5.9) | *n/t* | *n/t* | *n/t* |
| Big-endian hosts | **Untested** (no CI) | *n/t* | *n/t* | *n/t* |

> **Note on parallel builds (corrected 2026-09-09):** an earlier sweep reported a
> parallel build as ~17% larger than serial. That was measured **before**
> `fts_vacuum`. Re-measured with the vacuum step, serial and 4-worker builds land at
> **identical size** (1,420 MB each) with identical match counts — a parallel build is
> faster and leaves more *reclaimable residue*, not a bigger index. Run `fts_vacuum`
> once after a large build. Details in `bench/BENCHMARK_SUMMARY.md`.

**Read:** not needing `shared_preload_libraries` is a genuine deployment
advantage — the other three all require a restart to install, and on a managed
service may require provider support. Being pure C also matters: two competitors
need a Rust toolchain, and pg_search additionally needs OpenBLAS and pgvector.

---

## Choosing between them

- **pg_fts** — you want one index that answers ranked BM25 *and* boolean, exact
  counts, phrase, prefix, fuzzy and regex, with PostgreSQL-consistent stemming, the
  smallest on-disk footprint, and no preload/Rust requirement.  pg_search builds 3.6x
  faster (1.10.0 also trailed on common-term ranking and phrase).
- **pg_search** — you want the fastest build, and can accept Tantivy's analyzer (configure `stemmer=english`;
  tokenization still differs slightly from `to_tsvector`), a 2.4× larger index,
  lower single-term throughput under load, and a Rust build (it also requires pgvector).
- **vchord** — ranking only (no boolean AND, phrase or count support); measured here
  with its documented English tokenizer setup, which produced a 41 GB index and the
  slowest queries of the four on this corpus.
- **pg_textsearch** — BM25 ranking on top of PostgreSQL's own analyzer, with flat
  throughput as clients increase. Boolean/phrase/prefix work as a filter over the
  ranked scan, and there is no index-backed count.
- **tsvector/GIN** — already in PostgreSQL, mature tooling, but no BM25 and no
  index-native top-k.

### What this matrix does NOT cover

Three dimensions normally used to judge a BM25 access method are **absent**, and their
absence is not evidence of parity (`bench/COVERAGE_AUDIT_2026-09-10.md`):

- **Concurrent throughput (QPS) — MEASURED cross-engine 2026-09-11**
  (`bench/RESULTS_C1X_CROSSENGINE_2026-09-11.md`), all four engines, one documented
  query form, same instance type. Headlines:
  **No engine collapses** — all four rise to 8 clients then plateau, host-CPU-bound on
  16 vCPU / 8 physical cores. **pg_fts has the best scaling factor** (10.7x rare /
  10.0x common, latency flat 1→8) **and the worst absolute ranked throughput**: at 32
  clients 1,076 tps rare (pg_textsearch 8,349) and 208 tps common (pg_search 4,298,
  i.e. **20.7x** — the common-term gap is *worse* under load than the 17x
  single-client figure). **`count(*)` is ours by a wide margin**: 2,923 tps / 10.9 ms at
  32 clients vs pg_search 513 tps / 62.3 ms (**5.7x**), and pg_textsearch/vchord cannot
  do it at all.
  Correction recorded there: an earlier claim that vchord *collapses* was wrong — it
  peaks at 8 clients and declines only 4.7-7.2% by 32.
- **Ingest / update throughput.** We measure bulk build only. Sustained INSERT rows/s,
  DELETE/UPDATE cost, and how latency degrades as the pending list grows between
  merges are unmeasured for every engine.
- **Ranking quality (NDCG / recall vs a reference).** We verify our own exactness
  (top-k parity against an exact sort, gated per release) but have never compared
  *relevance ordering* against a rival. This matters here because pg_search does not
  stem, so it answers a different query.

### Caveats on this matrix
Every *n/t* is a real gap in our knowledge, not an implied "No". We benchmarked the
competitors for latency, size and match counts on one corpus; we did **not** audit
their crash safety, replication behaviour, MVCC correctness or concurrency, all of
which pg_fts has been tested for at length (and had bugs found in). A fair reading
is that our own rows are better evidenced than the competitors' — including the rows
where we lose.
