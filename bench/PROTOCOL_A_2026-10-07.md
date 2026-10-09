# Approach A benchmark protocol (aarch64 Debian, 2026-10-07)

Written BEFORE the run, so the method cannot be fitted to the results.  It is the 1.10.0
protocol (`bench/PROTOCOL_110_2026-10-07.md`) unchanged, plus four additions listed under
"Changes from the 1.10.0 protocol".  Every rule there applies here.

## Questions

1. What did the Approach A work (branch `approach-a`: best-first single-term and
   conjunctive top-k, tighter block bounds, MaxScore and term:LABEL fixes, build/merge
   rework, maintenance buffer ring, prefetch) change against pg_fts 1.10.0 on the same
   host, index and queries?
2. Where does it leave pg_fts against pg_textsearch 1.5.1, pg_search 0.26.0 and
   VectorChord-bm25 0.3.0, re-measured on fresh hosts under the same protocol?

## Setup

Exactly the 1.10.0 protocol: EC2 r7gd.4xlarge (Graviton3), Debian 13 arm64, PG 17.10 from
source with identical flags on every host, `shared_buffers=32GB`, `work_mem=256MB`,
`maintenance_work_mem=8GB`, `jit=off`, `autovacuum=off` during measurement,
`max_connections=200`; the same 2,188,038-article Wikipedia corpus (TSV md5 checked);
each engine's documented English-stemmed setup; one host per engine.

## Changes from the 1.10.0 protocol

1. **Build time is measured as an expression index as well as on a stored column.**
   1.10.0 timed `CREATE INDEX ... USING fts (d)` on a pre-filled `ftsdoc` column; the fill
   (`UPDATE ... SET d = to_ftsdoc(...)`) was not counted, while the other engines analyse
   text inside their build.  This run also times `CREATE INDEX ... USING fts
   (to_ftsdoc('english', content))` on the raw table, which does the analysis inside the
   build like the others.  Both are reported; the comparison column uses the expression
   index.  Also reported: whether `fts_vacuum` is still needed after a plain build (size
   before and after it).
2. **pg_fts A/B on one host.**  The 1.10.0 release binary and the approach-a binary run
   against the SAME index files on the same host, alternating, 3 passes each per band,
   after a correctness gate (identical ids, and scores within 1e-9, for every ranked band).
   Same-arm passes are reported so between-arm differences can be read against the
   same-arm spread.
3. **Additional ranked bands** that A targets, for all engines that can express them:
   `united & states` (AND, both terms common), `world & war`, and the positional phrase
   `"world war"` (positions index for pg_fts, as for `"united states"`), plus a 4-term OR
   `film | music | album | band` (MaxScore path).
4. **A cold-cache band**: PostgreSQL stopped, `sync; echo 3 > /proc/sys/vm/drop_caches`,
   started, one query, `EXPLAIN (ANALYZE, BUFFERS)` execution time; 5 repetitions, median.
   `pg_prewarm.autoprewarm` is OFF for the cold band (its block-list reload otherwise reads
   tens of thousands of TOAST pages into the "cold" cache).  Default
   `effective_io_concurrency` (1) as shipped, and 16 for pg_fts as a second row.  Bands:
   rare k10, common k10, AND k10.

## Correctness gate (before any timing is believed)

As 1.10.0, plus: pg_fts ranked results for every band (both binaries) are checked against
an exhaustive reference computed from the stored ftsdoc with the index's own statistics and
length quantization (`bench/data_A_2026-10-07/mt_oracle.py`, `and_oracle.py`); a band whose
reference check fails is not timed.

## What is NOT claimed

As 1.10.0.  In addition: the cold band is local NVMe; nothing is claimed for network
storage.  Unreleased code: these are numbers for branch `approach-a` at a recorded commit,
not for a release.
