# sparsemap 5.8.0 qualification at scale (2026-09-30) -- pg_fts 1.8.5 vs 1.8.6

Post-release at-scale run for 1.8.6 (sparsemap 5.7.0 -> 5.8.0). Raw logs and the harness
are in `data_sm58_2026-09-30/`.

## Setup

EC2 r6id.4xlarge (16 vCPU, 123 GB, instance-store NVMe), AL2023, PostgreSQL 17.10 built
from source (`-O2 -g`), one build copied to two prefixes. 1.8.5 from `git archive v1.8.5`
(sm.h 5.7.0); 1.8.6 from the published PGXN/GitHub zip (sm.h 5.8.0, sha256 `222ac85f...`).
`shared_buffers=8GB`, `maintenance_work_mem=4GB`, `autovacuum=off`, serial maintenance.

Corpus: 5,000,000 synthetic rows, 30 terms each, drawn `w<floor(random()^3 * 5e6)>` with
`setseed(0.42)` -- identical on both arms. Sequence per run: build; three rounds of
`DELETE WHERE id % {7,4,3} = 0` + `VACUUM`; `fts_merge`; `fts_vacuum`. Four index
queries (df from 223k down to 139) plus one fuzzy query are checked against a seqscan
regex count after build and after every VACUUM. Peak backend RSS sampled at 1 s.

Both arms ran concurrently, and each arm was run twice (A, B).

## Correctness

Every count matches seqscan and is non-zero, at every step, in all four runs (0
MISMATCH). The two arms return the same counts as each other at every step, including
fuzzy (38,913 -> 16,734). Final index size is identical on both arms: 730,693,632 bytes.

## Timing (seconds)

| step | 1.8.5 A | 1.8.5 B | 1.8.6 A | 1.8.6 B |
|---|---|---|---|---|
| build | 382.6 | 388.2 | 388.8 | 385.1 |
| VACUUM after del%7 (714k) | 151.0 | 151.2 | 138.0 | 138.4 |
| VACUUM after del%4 (1.07M) | 33.3 | 33.1 | 22.0 | 21.5 |
| VACUUM after del%3 (1.07M) | 32.1 | 32.2 | 23.1 | 23.1 |

Same-arm spread is below 1% on every VACUUM row, and the between-arm gap is well outside
it. That clears the self-comparison rule (AGENTS.md rule 3).

- **VACUUM: 8.5% faster on the first round, ~30% faster on the two later rounds.** These
  are the rounds where bulkdelete builds a large `dead` set with `sm_add_many_grow` over
  carried-forward plus new tombstones.
- **Build: no change** (382-389 s on both arms, spread overlapping). This corpus's build
  is not dominated by the trigram `sm_add_many_grow`. The open "superlinear trigram
  build at large diverse vocabularies" item is **not shown fixed** by this run.
- Peak backend RSS: no significant difference (build 5.87 GB both; VACUUM 4.7-5.7 GB both,
  noisy at 1 s sampling).

## Standalone library microbenchmark, same host

`sm_add_many_grow` of 20M ids into an empty map, 3 runs each. Serialized bytes are
identical between versions in every case.

| input | 5.7.0 | 5.8.0 | peak RSS 5.7.0 / 5.8.0 |
|---|---|---|---|
| dense ascending (tombstone shape) | 2.32 s | 0.95 s | 382 / 382 MB |
| unsorted + duplicates (`bm25_segment_docids` shape) | 16.9 s | 3.1 s | 458 / 458 MB |
| sparse ascending (trigram shape) | 2.76 s | 2.15 s | 434 / 909 MB |

The sparse-input memory doubling is real, but it did not appear in pg_fts peak RSS on
this corpus.

## Local (8-core workstation) pre-release run

2.2M rows / 40 terms, both arms concurrent, one run each (`local_*.log`): counts match on
both arms at every step; build 1681 vs 1682 s; VACUUM 137/31/28 vs 130/24/22 s. It points
the same direction as EC2 but was a single run, and it is superseded by the table above.
