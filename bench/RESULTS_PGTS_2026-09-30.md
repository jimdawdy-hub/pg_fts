# pg_fts 1.8.6 vs pg_textsearch 1.4.0 (2026-09-30)

Head-to-head re-run of the September methodology (`RESULTS_5WAY_159b_2026-09-06.md`,
`RESULTS_C1X_CROSSENGINE_2026-09-11.md`) against the current release, pg_textsearch only.
Concurrency at 16 / 32 / 64 clients instead of 1 / 8 / 16 / 32. Raw data and every harness
script are in `data_pgts_2026-09-30/`.

## Rig

Four EC2 r6id.4xlarge (16 vCPU / 8 physical cores, 123 GB, 884 GB local NVMe), one engine
per host, run in parallel: latency-pg_fts, latency-pg_textsearch, concurrency-pg_fts,
concurrency-pg_textsearch. AL2023, PostgreSQL **17.10** built from source on each host.
Latency hosts `shared_buffers=64GB`, concurrency hosts `16GB` (as in the originals);
`maintenance_work_mem=16GB`, `max_parallel_maintenance_workers=8`, `jit=off`,
`autovacuum=off`; table and index `pg_prewarm`ed before timing.

Versions: pg_fts **1.8.6**, built from the published release zip (sha256 `222ac85f...`).
pg_textsearch **v1.4.0** (`7a932505`, 2026-08-18) -- the newest tag; September measured
`f940210`.

Corpus: wikimedia/wikipedia `20231101.en`, first **2,188,038** articles, joined to
`docs(id bigint, content text)` with content = title + ' ' + body. Regenerated on each host
from the pinned dataset, and the TSV is **md5-identical on all four** (`f5939e85...`). Each
engine indexes `content` only; pg_fts indexes a stored `d = to_ftsdoc('english', content)`
column.

Timing: `\timing` inside one psql session, 8 runs per query, median of runs 4-8. Every
band was run as **3 independent passes**, and the tables give the median of the 3 pass
medians; all passes are in `latency.txt`. Every band was `EXPLAIN`ed (`explain.txt`).

Concurrency: `bench/underload.sh` unchanged, pgbench `-T 30`, `-j min(c,8)`, after a
10 s warm-up per band, **2 passes**. Query forms are the C1X forms verbatim.

Wall-clock: hosts launched 20:05 EDT, all four measurements finished by 21:06 EDT, then
torn down. A follow-up query-form check on two more hosts ran 21:35-22:43 EDT.

## Correctness

| term | pg_fts | pg_textsearch | regex on raw text |
|---|---|---|---|
| slovakia | 10,875 | 10,875 | 10,898 (`\mslovakia\M`, unstemmed) |
| hungary | 24,097 | 24,097 | 24,148 |
| year | **734,896** | **734,896** | 733,960 (`\myears?\M`) |

Both engines agree exactly on every term and match September byte for byte. pg_fts ranked
parity is **PASS 10/10** (`parity.txt`; five query shapes at k=10 and k=100, against an
exact `fts_bm25` sort over the heap). Top-10 lists differ between the engines only inside
near-tie score bands; `year` has a run of >=7 docs tied at 2.33896 (`top10.txt`). Each
engine's top-10 is identical across passes.

## Single-client latency (ms, median of 3 passes; each pass = median of runs 4-8)

| query | pg_fts 1.8.6 | pg_textsearch 1.4.0 | faster |
|---|---|---|---|
| rare k10 (`slovakia`) | 10.21 | **0.92** | pgts 11x |
| mid k10 (`hungary`) | 15.99 | **1.17** | pgts 14x |
| common k10 (`year`) | 49.16 | **11.41** | pgts 4.3x |
| common k100 | 50.14 | **13.75** | pgts 3.6x |
| exact `count(*)` common | **2.50** | (seqscan, 251 s) | pg_fts |
| AND 2-term k10 | **9.03** | 37.69 | pg_fts 4.2x |
| OR 2-term k10 | **10.69** | 36.94 | pg_fts 3.5x |
| OR 3-term k10 | **15.40** | 31.79 | pg_fts 2.1x |
| prefix k10 (`hung*`) | 18.38 | **13.41** | pgts 1.4x |
| phrase k10 (`"united states"`) | 239 (`positions=on`) | **41.8** | pgts 5.7x |

Pass-to-pass spread (max/min of the 3 pass medians) is at most 7%; pg_fts at most 5%,
pg_textsearch 7% (AND) and 6% (rare); under 2% on most rows.

Query forms:
- pg_fts: `WHERE d @@@ q ORDER BY d <=> q LIMIT k` (KNN index scan).
- pg_textsearch ranked: `ORDER BY content <@> to_bm25query('T','docs_pgts') LIMIT k`.
- pg_textsearch boolean / prefix / phrase: its 1.x `@@ to_tsquery(...)` filter plus the
  `<@>` sort, on the same BM25 index (EXPLAIN: Index Scan + Filter). Its README says
  this combination is "not yet optimized as a single index scan".

**pg_textsearch has `count` now, but not an index-backed one.** 1.x added `@@` boolean
filtering, so `SELECT count(*) WHERE content @@ to_tsquery('year')` runs. Its plan is a
**Parallel Seq Scan** at **251 s** per run, so the band was dropped after the first pass
(`latency_aborted.txt`). In concurrency it was abandoned the same way; `underload.sh`
records no number rather than a zero.

## Concurrency (tps / mean latency ms; 2 passes, shown as pass 1 / pass 2 tps)

| band | clients | pg_fts 1.8.6 | pg_textsearch 1.4.0 |
|---|---|---|---|
| rare k10 | 16 | 1,050 / 1,052 tps, 15.2 ms | **8,215 / 8,216 tps, 1.9 ms** |
| | 32 | 1,052 / 1,053, 30.4 | **8,129 / 8,139, 3.9** |
| | 64 | 1,044 / 1,049, 61.2 | **8,098 / 8,090, 7.9** |
| common k10 | 16 | 204 / 202, 78.8 | **635 / 644, 25.0** |
| | 32 | 205 / 206, 155.8 | **630 / 637, 50.5** |
| | 64 | 205 / 205, 312.1 | **648 / 644, 99.0** |
| exact count common | 16 | **2,651 / 2,650, 6.0** | seqscan, not measured |
| | 32 | **2,641 / 2,641, 12.1** | -- |
| | 64 | **2,648 / 2,644, 24.2** | -- |

Both passes agree within 1.3% on every cell. **Both engines are saturated from 16 clients
on:** tps is flat from 16 to 64 and latency doubles with each doubling of clients. mpstat
shows the pg_fts host at 99.7% CPU across the run. The pg_textsearch host averages 68.5%
because its 4-minute seqscan count probe is included; during the timed bands its tps is
also flat. On this 8-physical-core host, 16+ clients measures each engine's saturated
throughput, not its scaling.

At saturation pg_textsearch does **7.8x** pg_fts's throughput on rare and **3.1x** on
common. pg_fts's exact count sustains 2,640+ tps.

## Index size and build

| | pg_fts 1.8.6 | pg_textsearch 1.4.0 |
|---|---|---|
| index size | **1,421 MB** (1,489,600,512 B, after `fts_vacuum`) | 1,887 MB (1,978,318,848 B) |
| build (parallel, 8 workers) | 272 s + `fts_vacuum` 191 s | **260 s** (launched 5 workers) |
| prerequisite | stored `ftsdoc` column: 970 s `UPDATE` | none |
| `positions=on` index (phrase) | 2,627 MB, 326 s build | -- |

The `positions=on` index replaced the default one for the phrase row only. The default
index was rebuilt afterwards (438 s, again 1,421 MB) to run the parity gate.

pg_fts is 25% smaller -- the same 1,421 MB as September, so the format is unchanged.
Before `fts_vacuum` the freshly built index is 3,424 MB; the `fts_vacuum` step is required
to reach the compact size (an operational rule already in `BENCHMARK_SUMMARY.md`).

## What changed since September

**pg_textsearch got much faster; pg_fts did not change.**

| | Sept (pgts `f940210`) | now (pgts v1.4.0) | change |
|---|---|---|---|
| pgts rare k10 | 7.36 | 0.92 | **8.0x faster** |
| pgts mid k10 | 7.96 | 1.17 | **6.8x** |
| pgts common k10 | 20.71 | 11.41 | 1.8x |
| pgts common k100 | 50.71 | 13.75 | 3.7x |
| pgts rare @32 clients | 8,349 tps | 8,129 tps | flat |
| pgts common @32 clients | 683 tps | 630 tps | flat |

The single-client gains did not show up at saturation, where pg_textsearch's throughput is
unchanged; the gain is in per-query latency.

**pg_fts did not regress; the September headline used a different query form.** This
run's pg_fts rare k10 is 10.21 ms, against 5.85 ms published in September. To settle
which explanation is right (AGENTS.md rules 3 and 4), I ran a follow-up on two more
identical hosts: 1.6.1 (the C1X version) and 1.8.6, each timing both query forms against
the same index (`form_161/`, `form_186/`):

| query | 1.6.1 | 1.8.6 |
|---|---|---|
| `fts_search(idx, q, 10)`, rare | 5.92 | 5.83 |
| KNN `ORDER BY d <=> q LIMIT 10`, rare | 10.16 | 10.19 |
| `fts_search`, mid | 10.97 | 10.68 |
| KNN, mid | 16.08 | 15.97 |
| `fts_search`, common k10 | 37.07 | 36.78 |
| KNN, common k10 | 47.89 | 48.15 |
| count common | 2.35 | 2.49 |

1.6.1 and 1.8.6 are within noise on every row. The September 5.85 / 10.69 / 36.16 ms
match the **`fts_search()`** form; the KNN `ORDER BY` form used here -- and in C1X
concurrency, which measured 9.9 ms rare at 1 client -- costs about 4 ms more on rare/mid
and about 11 ms more on common. So **the 5-way table compared pg_fts's fast
function-call form against the competitors' `ORDER BY` forms.** This is recorded under
"Retracted" in the CHANGELOG. Even with the faster form, pg_fts trails pg_textsearch 1.4.0
by 6.3x on rare and 3.2x on common k10.

Not explained, and stated as such: count_common is 2.35 ms on 1.6.1 vs 2.49 ms on 1.8.6
(+6%), outside the ~1% pass spread. It is one host pair and has not been reproduced on a
second, so it is not claimed as a regression.

## Honest reading

As of 1.4.0, pg_textsearch beats pg_fts on every ranked single-term query, by 4-14x
single-client and 3-8x at saturation, plus prefix and phrase. pg_fts still wins:
- multi-term boolean ranked (AND 4.2x, OR 2-3.5x), where pg_textsearch filters then
  sorts;
- an index-backed exact `count(*)` (2.5 ms vs a 251 s seqscan);
- index size (25% smaller);
- the query-language surface (NEAR, fuzzy, regex, field zones; see
  `doc/COMPARISON_MATRIX.md`).

The "rare-term latency beats the like-for-like comparator" line in the September summary
is no longer true, and in the light of the query-form finding never was on equal query
forms.
