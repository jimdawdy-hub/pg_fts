# Build "non-convergence" (field attempts 15-21): RESOLVED as slow-but-linear, not a wedge

## Verdict
The field's remaining "build reads forever / nsegs frozen / no merge log for
50+ min" is **NOT a bug, NOT O(N^2), NOT a wedge**. It is an inherently slow but
strictly linear build whose cost is dominated by per-document text analysis
(tokenize + snowball stem), and whose large in-memory flush budget means many
minutes pass between segment flushes -- during which the segment count does not
change and nothing is written, looking exactly like a hang.

## How it was reproduced (EC2 r7i.8xlarge, PG18, this session)
Realistic corpus: 1.97M docs, 54GB of text, avg 28KB, max 5.9MB, real English
words (60k dict pool) + doc-unique tokens (huge vocab), heavy-tailed sizes --
matching/exceeding the field's shape (they had 19GB, avg 19.6KB, max 5.2MB).

Serial (workers=0) english-config build, instrumented (FLUSHPROBE) + gdb-sampled:
- Steady ~555 docs/s, DEAD CONSTANT (100k every ~181s), no degradation -> linear.
- gdb top-frame tally (many samples): ~33% cmp_word_idx/qsort_arg (the per-doc
  word sort in ftsdoc_from_parsed), ~28% TParserGet (tokenizer), ~25% snowball
  stemming (english_UTF_8_stem/find_among/dsnowball_lexize/LexizeExec), rest
  searchstoplist/parsetext. All inherent tsearch analysis cost.
- FLUSHPROBE: each flush had nterms~2.1M, sort_ms<1s, write_ms~2.6s. The qsort is
  NOT the bottleneck and NOT quadratic (micro-benchmarks: pg_qsort ~30xN even on
  Zipfian/shared-prefix/many-dup inputs; no quadratic path hit).
- First flush at ~524k docs / ~13 min in (2GB budget = mwm 1GB x 2). That 13-min
  gap with 0 flushes and unchanging nsegs IS the field's "frozen" window.
- Build COMPLETED in ~3601s (60 min): 4 flushes -> 1 merge "merging 4 of 4
  segments (1970000 live docs) into one" -> indisvalid=t, nsegments=1, 1850MB,
  queries correct (both @@@ and <=> ordered).

## Earlier hypotheses (this session), now discarded
- "pg_qsort in bm25_build_flush_segment is quadratic": WRONG. That qsort is <1s
  per flush; pg_qsort is ~30xN (log, not quadratic) on all tested distributions.
- "MemoryContextMemAllocated(true) is O(N) per tuple": WRONG. walk_us=0.0 always.
- The real cost is the per-document analysis (stemming), inherent to `english`.

## The genuine lever
Parallelism. The scan/analysis is embarrassingly parallel;
max_parallel_maintenance_workers reduces wall-clock ~proportionally. The field's
only parallel blocker was OOM under their 30G cgroup, addressed by
pg_fts.build_mem_ceiling_mb (1.1.5) + the (workers+1) x 2 x mwm memory formula.
The per-doc sort is ~30% of CPU and could be ~1.5x faster with glibc introsort
(qsort_r) instead of pg_qsort, but that is a portability-risky micro-opt on a
working build and was deliberately NOT taken: rewriting a sort under portability
risk for 11% on a build that already completes is not worth it.

## Shipped (1.1.7)
Build progress logging (LOG level: "~N documents analyzed" every 250k, and
"flushed segment ...; K segments so far" per flush) so a long build is
distinguishable from a stuck one; docs guidance on build throughput/parallelism.
