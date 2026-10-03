# Project instructions -- pg_fts

Read this file first. It is short on purpose: it tells you what this project is, what it
optimises for, and the rules that exist because breaking them cost real time or shipped a
wrong number. Everything else is linked, not duplicated.

## What this is

A PostgreSQL extension: a BM25 inverted-index access method (`USING fts`) with an exact
`count(*)`, one `@@@` operator covering boolean / phrase / NEAR / prefix / fuzzy / regex,
and MVCC-correct results. It competes with pg_search (ParadeDB), pg_textsearch,
VectorChord-bm25, built-in GIN, and (unmeasurably) PlanetScale's closed TIN.

**It optimises for correctness and verifiability over headline latency.** It is the
smallest index and the only one with an index-native exact count and the full query
language; it is ~17x slower than pg_search on common-term ranked top-k, and that gap is
architectural (scalar postings vs bitmap+SIMD), not a tuning matter. Do not try to close it
with a point release.

## Where things live

| need | file |
|---|---|
| what to work on, what is open, what was decided | `ROADMAP.md` (the ONLY plan file) |
| how to cut a release, format-change rules | `RELEASING.md` |
| current measured numbers, retractions, rejected optimisations | `bench/BENCHMARK_SUMMARY.md` |
| feature matrix vs competitors | `doc/COMPARISON_MATRIX.md` |
| which `bench/` documents are current vs historical record | `bench/INDEX.md` |
| the latest whole-project review | `REVIEW_2026-09-17.md` |

`HANDOFF.md`, `DEFERRED.md` and `CAPABILITIES.md` were folded into `ROADMAP.md`; do not
recreate them.

## Rules that exist because they were broken

Each of these cost a wasted run, a wrong published number, or a shipped bug. They are not
style preferences.

### Measurement

1. **A projected ratio is not a measurement.** "Up to 32x fewer VM lookups" counted calls,
   not time, and measured as ~1%. Report what was measured; if you have not measured it,
   say "unmeasured".
2. **Assert correctness before looking at any timing.** Both arms must produce identical
   counts/results first. A speedup on a wrong answer is a bug.
3. **Re-run an arm against itself before believing a between-arm difference.** An apparent
   8.5% win was one baseline outlier; three same-arm runs overlapped completely.
4. **Hold a number until reproduced at a second scale.** The "49x merge transient" was
   published against this rule and was misattributed.
5. **Never wrap `psql` in `/usr/bin/time`.** ~10 ms of process start rounds sub-ms queries
   to 0.0. Use `\timing` inside one session and take the median.
6. **`psql -c` is a new backend every time.** Per-backend statics (counters) read as zero
   from a second invocation. Instrumentation that reports via a static must be read in the
   SAME session that populated it.
7. **`elog(LOG)` goes to the server log, not the build output**, and `log_min_messages =
   warning` silences it entirely. Two rounds were lost concluding "the code is not reached".
   Read the node's logfile, and set `log_min_messages = info` in any diagnostic harness.
8. **Verify instrumentation is present in the artifact you are testing** (`grep -c` the
   marker in the source that was actually tarballed/built). It was lost twice to edit-chain
   mistakes and once a green gate ran on unmodified code because an edit silently failed
   its assertion.
9. **A test that compares 0 against 0 proves nothing.** Probe with terms/rows that exist,
   and assert the count is non-zero.
10. **Do not benchmark against numbers you cannot reproduce.** TIN is managed-only; it gets
    a "not in this matrix" note, never a column of vendor figures.

### Diagnosis

11. **`gdb -p <pid> -batch -ex bt` on the live backend before `perf`.** It isolated the P0
    when perf callchains were useless. But a stack sample gives a LOCATION, not a
    bottleneck -- "it is inside `bm25_free_page`" was turned into "free_page is slow" and
    published as a known issue that measurement then disproved (0.005 ms/page). Get a rate.
12. **Instrument before theorising.** Four consecutive hypotheses about the bloat cause were
    wrong; one counter on `bm25_new_buffer`'s outcomes found it. Put a counter on the thing
    and read it.
13. **When a stage probe shows no growth, check you probed every stage.** "Growth is
    outside VACUUM" was wrong because the probe stopped before `bm25_vacuum_compact`.
14. **`tap-pg17` runs seven test files.** Interleaved log lines mix indexes. Narrow
    `PROVE_TESTS` to one file and print the relation name when diagnosing.

### Code

15. **Bug fix = root cause, in the shared function, for every caller.** 1.7.0 guarded
    `pd_lower` at one read site; seven siblings had the same defect and needed 1.7.1. Grep
    the siblings before declaring a class of bug fixed.
16. **Validate on-page integers BEFORE forming pointers from them.** `page + pd_lower` is
    itself UB for a corrupt value; the fuzzer caught this in a fix. Guard in the integer
    domain.
17. **Allocator state is a scoped `BM25AllocCtx`, reachable only through
    `bm25_alloc_scope_enter`/`_exit`.** Reading the old globals without owning them handed
    out garbage block numbers; only `t/007` caught it. `bm25_new_buffer` now `elog(ERROR)`s
    on that condition. Always pair enter/exit in `PG_FINALLY`; scopes nest by returning the
    previous context.
18. **`bm25_page_recyclable`'s two gates are both load-bearing.** The XID gate: its comment
    records a real SIGSEGV from bypassing it. The liveness gate (no `BM25_FREED` => not
    recyclable, 1.8.3): the FSM records free SPACE not liveness, and a live mid-chain page
    handed out as merge output self-deadlocked. **Every merger runs under
    `bm25_maintenance_lock`**; the two merge entry points `elog(ERROR)` otherwise -- the
    one site that skipped it deadlocked against autovacuum in every release to 1.8.2.
19. **Every corpus-scale allocation goes through `FTS_ALLOC_MAYBE_HUGE`.** `ci/check-alloc.sh`
    enforces it. A missed site made an index permanently unvacuumable in the field.
20. **On-disk format changes need dual-read + optional per-segment pointer + in-place
    upgrade, no REINDEX.** 1.5.0 (v3->v4) is the precedent and it works; "needs a REINDEX"
    is not an acceptable reason to reject a format change. See `RELEASING.md`.
21. **`rd_amcache` is one palloc'd chunk.** `git archive` excludes `bench/` and `test/`
    (`.gitattributes`) -- scp harnesses directly.
22. **ASCII only** in install SQL (`make check-ascii`), code, and commit messages.

### Repository hygiene

23. **One plan file.** `ROADMAP.md`. Status of every item lives there, not in a new
    `NOTE_*.md`.
24. **`bench/` is a dated record, not documentation.** New measurement files go under
    `bench/` with a date suffix and get one line in `bench/INDEX.md` saying whether they
    are current truth or superseded. C comments reference the CHANGELOG entry, never a
    `bench/` file.
25. **A release renames the base SQL script; delete the old one.** 31 dead base scripts
    accumulated in the root because nobody did.
26. **Every new TAP test goes into BOTH `flake.nix` and `.github/workflows/ci.yml`.**
    `t/010` (the P1 regression test) ran only in the nix gate for a week. There is no
    Codeberg CI: it has no shared runners, its workflows never ran once in 115 attempts,
    and they were deleted on 2026-09-17. **A badge or workflow that has never produced a
    run is not a gate -- check `started_at` before believing one.**
27. **The README comparison paragraph must agree with `bench/BENCHMARK_SUMMARY.md`.** It
    drifted to claim a rare-term lead the project's own table contradicts. When the table
    changes, the paragraph changes in the same commit.
28. **Never write AWS account / VPC / SG / AMI / instance IDs into the repo.** Coordinates
    live in `/tmp/lava_coords.txt` only. A violation was expunged with `git-filter-repo`.

### Releases

29. **Full gate before every tag**: `installcheck-pg17/18`, `tap-pg17/18`, `ci/check-alloc.sh`,
    `make check-ascii`, `test/fuzz/run.sh` all green; docs re-rendered; version graph
    verified (every prior version reaches the new one).
30. **Ship known issues as known issues, with a reproduction.** Never silently carry one;
    never rush a design change into a correctness release.
31. **When a published claim turns out wrong, the CHANGELOG says so under "Retracted".**
    The project's credibility rests on this more than on any benchmark.
32. **Push `main` to GitHub directly, then the tag, then verify `ls-remote ... '^{}'`
    before trusting a release run.** The Codeberg->GitHub mirror is NOT a short race: on
    v1.8.5 it delivered the tag and stalled on `main` for 2+ hours, so GitHub's tag
    pointed at the previous release and the job ran THAT commit's workflow -- the
    in-workflow guard cannot protect against a stale tag because a stale tag selects a
    stale workflow. The guard stays as defence in depth; the direct push is the fix.
    Verify a release by downloading the PGXN and GitHub artifacts and comparing sha256
    -- not by reading a log line, and never by grepping across runs (I read a previous
    release's "accepted" as the current one's).

## Build / test

Use the Nix flake. Gate: `nix build .#checks.x86_64-linux.{installcheck-pg17,installcheck-pg18,tap-pg17,tap-pg18}`.
Local syntax check (note the `.c` files `#include`d into `pg_fts_am.c`):

    nix develop -c bash -c 'PGINC=$(pg_config --includedir-server); cc -fsyntax-only \
      -Wdeclaration-after-statement -fwrapv -Wno-attributes -I. -Ivendor -I"$PGINC" \
      -I"$PGINC/internal" -D_GNU_SOURCE pg_fts_am.c'

Benchmarks and scale validation run on EC2 (`/tmp/launch.sh`, `/tmp/teardown.sh`); local
green means nothing for the delete/merge path. Terminate the instance when done.

See .agent-steering-domains.md for domain-specific steering (local).
