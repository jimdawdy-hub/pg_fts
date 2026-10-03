# Bug report: `count(*)`'s fast-path visibility gate is O(heap pages), not O(matches)

**To:** pg_fts maintainers
**From:** pg_weave (a PostgreSQL-licensed fork of pg_fts, forked from pg_fts 1.5.8,
2026-09-05)
**Affects:** `pg_fts v1.8.3` (`166b0b0`), function `bm25_count_dictdf_fastpath()`,
`pg_fts_am_scan.c`
**Date:** 2026-09-21

This report does not assume you know pg_weave. Every claim below is checkable in your
own tree; the line numbers are from `pg_fts_am_scan.c` as it exists in your repository
today (we read it there, not in our fork).

## The claim

`bm25_count_dictdf_fastpath()` answers `count(*)` for a single plain positive term by
(1) summing the term's document frequency across segment dictionaries, then (2) proving
the *entire heap* is all-visible to the snapshot before trusting that sum as an exact
MVCC-correct count. Step (2) is implemented as one `VM_ALL_VISIBLE()` call per heap
block:

```c
heap = table_open(index->rd_index->indrelid, AccessShareLock);
nblocks = RelationGetNumberOfBlocks(heap);
for (blk = 0; blk < nblocks; blk++)
{
    if (!VM_ALL_VISIBLE(heap, blk, &vmbuf))
    {
        all_visible = false;
        break;
    }
}
```

That is at `pg_fts_am_scan.c:4402` in your tree today (the `if (!VM_ALL_VISIBLE(...))`
line inside the `for (blk = 0; blk < nblocks; blk++)` loop starting a few lines above
it, function `bm25_count_dictdf_fastpath`, comment block above it says "Gate (4)").
Please verify this yourselves — quote what is actually at that line in your checkout,
since line numbers drift across commits.

**The cost of that loop tracks the number of heap blocks, not the number of matching
documents.** A term matching zero documents pays for the same per-block scan as a term
matching every document in the corpus, because gate (4) runs regardless of the df
computed in gate (earlier), as long as the term has any pending-segment presence check
that clears.

## The measurement

Host `c7i.2xlarge`, 1M-document corpus, 87,486-page heap, harness
`/scratch/pg_weave/g38.sh` (ours, not committed to either repository), two passes
agreeing to the last digit:

| query | df | latency | notes |
|---|---:|---:|---|
| `count(*)` rare | 25 | 0.278 ms | |
| `count(*)` mid | 2,505 | 0.291 ms | |
| `count(*)` common | 196,785 | 0.278 ms | |
| `count(*)` no-match | 0 | 0.280 ms | |

Flat from df 0 to df 196,785. `EXPLAIN (ANALYZE, BUFFERS)` reported `shared hit=8` on
every one of these runs — so the ~0.28 ms was never I/O. It was 87,486 function calls
to `VM_ALL_VISIBLE()`, once per heap block, every time, independent of the term.

**The tell that found it, because it will generalize to your own regressions:** we
had an apparent 2.2x slowdown between two benchmark runs (0.43 ms -> 0.95 ms at the
same scale) and initially suspected our own code. What ruled that out is that `pg_fts
v1.8.3` measured 0.94 ms on the *same table, in the same run* — agreeing with our
number to 0.01 ms. Two independently-maintained forks agreeing that closely on a number
that looked like a regression is itself evidence the mechanism is shared, not that
either fork's recent changes are innocent by coincidence. The number that actually
explained it was not the match-count ratio (df 25 vs df 196,785 — no correlation) but
the **heap-size ratio**: 0.43 ms / 0.95 ms / 3.81 ms at three heap sizes (1,076 MB,
2,357 MB, 9,238 MB — a straight line at roughly 3.2 ns per heap page). If two of your
own benchmark runs ever disagree on a `count(*)` number and the disagreement doesn't
track the query, check whether it tracks the *table size* instead — that is the
signature of this gate.

## Why it is a defect, not a trade-off

The path this gate exists to *avoid* — the ordinary posting-scan `count(*)` path —
answered df 25 in about 0.007 ms in our measurement. So below roughly **df 9,000** on
an 87,486-page heap, the "fast" path was **up to 40x slower** than the code it exists
to short-circuit, and the crossover point moves with heap size, not with anything a
user can see or tune. A term that matches nothing pays the same cost as a term that
matches nearly every document — the opposite of what a reader would expect from a
function named `..._fastpath`.

## What we did (for context, not something we are asking you to adopt verbatim)

We shipped two changes: (1) a zero-df early-out — if no segment's dictionary holds the
term at all, the answer is 0 regardless of visibility, so gate (4) never has to run;
(2) for the nonzero case, replacing the per-block `VM_ALL_VISIBLE()` loop with
`visibilitymap_count()`, which reads visibility-map *pages* and popcounts them,
turning an O(heap_pages) loop of function calls into an O(heap_pages / 32672) loop of
buffer reads. Measured on a separate, smaller heap (683 MB, not the 87,486-page one
above — the two numbers should not be divided against each other), the fixed gate ran
flat at 0.003-0.005 ms across every df, a 69-93x improvement on that heap.

The one hazard that swap introduces: `visibilitymap_count()` counts bits over the
*whole* map, including bits belonging to any block past the relation's current end, so
a count that merely equals `nblocks` could in principle include stale bits past
`RelationGetNumberOfBlocks()`. We did not just reason our way past this — we ship the
old per-block scan as a cross-check under `USE_ASSERT_CHECKING`, so a debug build
re-derives and asserts agreement on every count. Whether that hazard is reachable in
your relation-truncation code path is something you would need to check independently;
in ours it is not (`visibilitymap_truncate()` runs inside `RelationTruncate()`'s
critical section under `XLOG_SMGR_TRUNCATE`), but that reasoning is exactly the kind
`doc/CONVENTIONS.md` in our tree tells us to distrust without a cross-check, which is
why the assert exists.

## What was NOT measured

- We did not measure the fixed gate against pg_fts on the same table/heap — the fix
  was measured on a different, smaller corpus (683 MB) than the one that produced the
  0.278-0.291 ms numbers above (87,486-page heap). No post-fix ratio against pg_fts is
  claimed anywhere in this report.
- We did not check whether pg_fts has a different code path for `count(*)` on a
  negated term, a phrase, or a boolean combination — this report is about the single
  plain positive term path only, which is what `bm25_count_dictdf_fastpath()` says it
  handles.
- We did not check pg_fts versions before 1.8.3 or any version after it that may exist
  by the time you read this.
- We did not profile whether the fix's `visibilitymap_count()` approach interacts
  correctly with your merge/vacuum machinery — that would need to be re-verified in
  your tree, not assumed from ours, since the two trees' merge/vacuum code has diverged.

## What we would need from you

Nothing required. If useful: a confirmation that `pg_fts_am_scan.c:4402` (or wherever
it has moved to by the time you read this) is the function you'd want a patch against,
and whether you want the zero-df early-out and the `visibilitymap_count()` swap as one
patch or two. We are a fork/importer of pg_fts and are happy to send a patch adapted to
your current tree if that is useful; we understand you may have already found and
fixed this independently, or may have reasons not to want the assert-checked fallback
we carry.
