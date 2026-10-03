# Bug report: a benchmark gate premise and a harness artifact, plus one honest loss

**To:** pg_fts maintainers
**From:** pg_weave (a PostgreSQL-licensed fork of pg_fts, forked from pg_fts 1.5.8,
2026-09-05)
**Affects:** `pg_fts v1.8.3` (`166b0b0`), planning of `ORDER BY ... <=> ... LIMIT k`
with no `WHERE` clause
**Date:** 2026-09-21

This report does not assume you know pg_weave. We measured your extension, installed
alongside ours, in one database, over one shared table, and we report what we saw in
your plans and your timings. You should be able to reproduce every number below against
your own build without touching ours.

## Setup, so the numbers below are checkable

- Host: `r6id.4xlarge`, 16 vCPU, 123 GiB RAM, local NVMe, Intel Xeon Platinum 8375C @
  2.90 GHz.
- PostgreSQL 17.11 PGDG, `shared_buffers` 40% of RAM, `maintenance_work_mem` 2 GB,
  `jit=off`.
- Two scales: 1,000,000 documents / 200,000-term Zipf-ish vocabulary (table 2,357 MB),
  and 4,000,000 documents / 400,000-term vocabulary (table 9,238 MB).
- Both extensions installed in one database, over one table, differing only in the
  index and the analyzed column each one uses (both resolve
  `default_text_search_config` through the one-argument entry point, so both index the
  same tokenization of the same text).
- Method: warm = 7 repetitions in one session, first dropped, p50/p99 reported; a
  separate cold measurement = first scan in a fresh backend, median of 5.
- Correctness gated before any timing: every arm's match count checked equal to a
  seq-scan reference for four selectivity bands, at both scales.
- Harness: our `bench/lexical.sh` via `bench/aws/run.sh r6id.4xlarge lexical`, which we
  do not expect you to run — the numbers below are what it produced against your
  build, and we're reporting the measurement, not asking you to trust our script.

## (a) The bare `ORDER BY ... <=> ... LIMIT k` form still plans a sequential scan

The query shape is `SELECT ... FROM t ORDER BY ftsdoc <=> ftsquery LIMIT k` with **no**
`WHERE` clause. On our table, against your extension, this plans `Limit[NO-INDEX]` —
a Seq Scan feeding a top-N Sort that evaluates `<=>` on every row — at both scales we
measured:

| scale | your p50 (bare `ORDER BY`, rare term) | equivalent qualified-form or index-path p50 | ratio |
|---|---:|---:|---:|
| 1M docs | 148.19 ms | 0.04 ms | **3,705x** |
| 4M docs | 592.64 ms | 0.05 ms | **11,853x** |

The comparison column is our own index-ordering path on the same table at the same
scale, not a number from your extension — we are not claiming you have a 3,705x
internal regression, we are reporting that the unqualified form costs 3,705x /
11,853x more than an index-ordering path *can* cost on identical data, which is the
form of evidence that matters to a user who writes `ORDER BY embedding <=> $1 LIMIT 10`
without a `WHERE` clause — which is what pgvector taught people that syntax means, and
is very likely the first thing a new user of your extension tries. On our own copy of
this code we had the identical defect until we fixed it (our task L7): the planner
could not consider an index path with no restriction clause because the access method
declared it needed one. The mechanism is `amoptionalkey`: setting it true lets the
planner consider an index path for an ordering-only scan with no qualifying `WHERE`.
Whether that is the right fix for your AM's cost model is something only you can
determine from your own `amcostestimate`/`amoptionalkey` wiring — we are reporting the
symptom and the mechanism we used, not prescribing your patch.

**What was NOT measured:** we did not test this against any pg_fts version other than
1.8.3, and we did not test whether a `WHERE` clause of any selectivity avoids the
sequential scan (our own regression suite specifically tests both the qualified and
unqualified forms because a test that only checks the qualified form would not catch
this). We also did not measure this shape under parallelism on your extension
specifically — see the parallel note below, which is about our own comparison to GIN.

## (b) A premise this benchmark rests on, and a harness artifact worth knowing about

We are telling you both of these because if you ever compare your own release-to-release
numbers against a corpus like this one, both are the kind of thing that silently
produces a wrong number.

**The premise:** all three arms (yours, GIN, ours) in our benchmark index a **stored,
pre-analyzed column**, not an expression index. We profiled an expression-index form
first and found 40-88% of measured latency went into re-analysis happening inside the
`ORDER BY` clause itself — i.e. the benchmark would have been measuring the analyzer,
not the index, if we had used `ORDER BY to_ftsdoc(body) <=> ...` directly. If you
publish your own benchmarks against an expression index, this is worth checking on
your own analyzer before trusting a latency number from that shape.

**The harness artifact, found and corrected before any number below was accepted:**
our own benchmark measured a **seq-scan** for the bare `ORDER BY` form for six
consecutive runs while looking exactly like an index benchmark, because nothing in the
harness checked the plan shape — only the row count, which was correct either way. We
now assert the plan shape in our regression tests specifically because of this: a test
that only checks rows passes just as happily on the seq-scan path. If your own
correctness or performance tests for `<=>` do not assert `EXPLAIN` output for both the
qualified and unqualified forms, this is the failure mode that would hide from them.

## The one row where pg_fts is faster than us — reported as plainly as the losses above

Index build time, same table, same host:

| scale | our build time | your build time | ratio |
|---|---:|---:|---:|
| 1M docs | 10.9 s | 10.9 s | tie |
| 4M docs | 56.8 s | 52.7 s | **you are 1.08x faster** |

We are not aware of the mechanism behind the 4M-scale difference and did not
investigate it — we are reporting the measured ratio, not a cause.

## What this report does NOT claim

- It does not claim your `count(*)` fast path is slower than ours — at 1M and 4M
  scale, `count(*)` on a common term measured as a **tie** between the two extensions
  (0.95 ms vs 0.94 ms at 1M, 3.81 ms vs 3.81 ms at 4M), because both extensions carry
  the same O(heap-pages) visibility gate — see our separate report on that gate.
- It does not claim a win on `count(*) AND` (both trivial, and yours was measured
  faster at both scales, 2x at 1M and 1.33x at 4M, though both numbers are near the
  noise floor of the measurement) or on `count(*) prefix` (a tie at both scales).
- It does not compare either extension against pg_search, pg_textsearch, or
  VectorChord — we have not measured either against those systems on this corpus.
- It is single-stream latency only. No concurrency, no mixed read/write, no
  throughput-under-load was measured for either extension.
- It does not measure nDCG or ranking quality — only latency and plan shape on
  equality-gated correctness queries.

## What we would need from you

Nothing required. If useful: whether you consider `amoptionalkey` (or an equivalent
mechanism in your access method) the right lever for the bare-`ORDER BY` fix, and
whether a patch adding it is something you'd want submitted against your current tree.
We are a fork/importer of pg_fts and are happy to send a patch; we understand your
AM's cost-estimation code has very likely diverged from ours since the 1.5.8 fork
point, so a patch would need to be written against your current source rather than
transplanted from ours.
