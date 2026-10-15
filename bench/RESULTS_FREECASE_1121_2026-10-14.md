# Freecase integration on pg_fts 1.12.1 (2026-10-14)

**Status: implementation, local qualification and VM801 database tests complete.**
The pg_fts-on mode still timed out on **90/225 searches (40%)**, including
33/150 searches in repeated passes. Compatibility and correctness checks passed;
production performance acceptance remains unproven. This is an unreleased
combined candidate, not a production rollout.

## Identity and changes

- Worktree: `upgrade/freecase-1121-20261014`, uncommitted merge.
- Freecase base: `37801f3c6682ed0f00f36698b75daab6da0425fb`.
- Upstream v1.12.1: `4434607ff0f3fd57f39cced87b4b33e19a61497d`.
- Preserves configured 30-bit positions, legal proximity/exact operators,
  complete positional Boolean evaluation and the fork's ranked/filter algorithms.
- Integrates dictionary-directory caching; preserves the fork algorithms that
  already cover upstream multi-key, different-filter/rank, NOT and NULL fixes.
- Adds attempt-owned cache construction so ERROR during an unfinished build
  releases allocations. Only a completed offset-based chunk is published.
- No disk-format change: BM25_VERSION remains 4. No REINDEX was performed.
- Installs as extversion `1.12.1`; binary SHA distinguishes this fork from stock:
  `b277a1fc2c588eef4c9833038ff1db2364c915f6465090e871f72054d38ca712`.
- Explicit unfiltered NULL distance ordering retains its documented ERROR.

## Completed qualification

| Check | Result |
|---|---|
| PG18.4 normal build, 18 regression files | PASS |
| Two concurrency isolation files | PASS |
| Twelve recovery/stress TAP files, 137 assertions | PASS |
| Normal Ubuntu PG18.6 build and VM801 LOAD | PASS |
| Original issue 11 fixture, three repeats, two LIMIT shapes | 2,000 distinct results, no duplicates/missing/unexpected IDs; expected ordering |
| Allocation and SQL ASCII checks | PASS |
| Source review, mac-claude | No blocking findings; Q1/Q2 fulfilled |

The first full-TAP attempt ran zero tests because Perl IPC::Run was absent in
our disposable container. Installed the dependency there, returned the container
to network isolation, and reran successfully. The failed setup log is retained.

### Construction-window cleanup

A **private fault-injected build** deliberately raises SQLSTATE 57014 after cache
allocations, before publication. This is an ERROR cleanup test in the exact
construction window, not evidence of a random timeout storm or asynchronous
statement_timeout measurement. No hook is present in the installed artifact.

Thirty interrupted builds on one backend:

- Control: CacheMemoryContext +343,824 bytes.
- Fixed: -11,856 bytes, zero unfinished build contexts; next query succeeds.
- Normal successful construction: cache-context used bytes 519,432 remained
  identical across two repeated ranked queries; zero unfinished contexts.

Peak construction memory can temporarily approach twice the completed cache
allocation (roughly 130 MB at a 64 MB budget); this is not a total-backend cap.

## Existing VM801 database and index

Target is the latest verified existing production-derived benchmark database:
`freecase_vm801`, system identifier `7695560671403937875`, on VM801. It is the
preserved b12-derived corpus, not a newly exported current production snapshot.
The source snapshot and original uploaded 1.11.0 physical backup remain unchanged.

The install saved old library, bitcode and extension SQL/control files and a
rollback script, briefly restarted only VM801 PostgreSQL, and applied the two
comment-only extension upgrade edges. No data restore or index rebuild occurred.

Pre/post controls:

- Index OID/relfilenode: 50028857/50028857, unchanged.
- Index bytes: 33,735,385,088, unchanged; positions=on, valid/ready, one segment.
- `(qualifi <-> immun) & polic`: exactly 44,784 opinions before and after.
- Top 150 ranked IDs: identical ordered sequence before and after.
- Measured count: 0.94 s before / 0.84 s after; rank: 1.04 s / 1.11 s.
  **These single controls are compatibility checks, not a speedup claim.**

## Historical replay (complete)

Same 75 historical query/scope cells x 3 paired passes x 2 flag modes = 450 searches.
Persistent read-only workers, alternating leading engine, same application
search.py `539aac41dc4da19b3735edb96228dcb017f1ea2a6cf0a1d73c5b1788d45dd3a1`,
precedential=true, limit=25, work_mem=64 MB, session parallel setting 4.
On mode uses the new extension with the existing integration SQL unchanged;
legacy bounded fallback remains available and must be reported separately.
Off mode is the candidate app branch with the flag disabled, not an assertion
that the entire installed application is production's checkout.

Finished 2026-10-14T21:43:11Z, successful unit exit, 450/450 recorded,
225 per mode, 75 per mode/pass, no duplicate samples, stable guarded backend
PIDs 88850 (off) and 88853 (on). All on traces contain @@@; none of the off
traces contain it. No crashed workers or unexpected errors.

| Pass | Mode | App complete | Partial (best effort) | Timed out | Median observed seconds |
|---|---|---:|---:|---:|---:|
| 1 | off | 6 | 6 | 63 | 25.03 |
| 1 | on | 14 | 4 | 57 | 25.03 |
| 2 | off | 12 | 41 | 22 | 6.64 |
| 2 | on | 34 | 22 | 19 | 5.73 |
| 3 | off | 15 | 37 | 23 | 6.36 |
| 3 | on | 50 | 11 | 14 | 3.75 |
| Total | off | 33 | 84 | 108 | - |
| Total | on | 98 | 37 | 90 | - |

Partial means the application returned `best_effort` coverage in either mode.
Only on-mode attempts can fall back from pg_fts to legacy retrieval.

On fell back to legacy bounded retrieval 127 times (37 partial + 90 timed out).
"App complete" is the application's coverage label; it does not prove exhaustive
recall or relevance. Timeouts are failures to return within the budget, not honest
zero matches, and their durations are censored at the configured deadlines.

For repeated passes 2-3:

- Nationwide: off 0/66 app complete, on 52/66; medians 6.30 s / 2.71 s.
- Filtered scopes: off 27/84, on 32/84; medians 8.60 s / 7.25 s.

Both modes retain timeout problems. The new extension does not fix the existing
visible-distance projection or post-scan filtering in the unchanged application.
A read-only activity snapshot observed the ordinary backend in IO/DataFileRead,
with no blocking PIDs or vacuum worker. This supports an I/O contribution; it is
not an attribution of every timeout or proof of the physical storage class.

### Output preservation against the previous fork

For the 88 on-mode cells that completed under both the retained 1.11.0 replay and
this 1.12.1 replay, **88/88 ordered case-ID lists are identical** (79 are nonempty).
The separate immediate pre/post engine control also retained its 150 ordered IDs.
These are compatibility checks. Different host/cache conditions prevent treating
the two historical runs as a controlled extension speed comparison.

### Actual long opinion on the existing index

Read-only post-replay check on existing opinion 6353492, *Dobbs v. Jackson Women's
Health Organization*. Its body SHA equals the previously captured viewer text.
The phrase "greenlighting even total abortion bans" has a single matching start
at **position 72,794**, established from the configured analyzer's serialized
positions. The direct matcher and the existing `idx_so_pgfts_body` both find it.
An inserted-word near miss is rejected by both. EXPLAIN binds both queries to
that existing index, with no new table/index or data writes. The positive query
returned only the expected opinion in 1.03 s; the negative returned none in 1.21 s.

This demonstrates live long-position support past 65,535 on the current Ubuntu
PG18.6 deployment and existing corpus, in addition to local regression fixtures.

No cache dropping/prewarming. Minimal out-of-workload backend initialization;
first/repeated passes separate. Untimed opinion opens between searches can warm
shared heap/TOAST caches. VM801 has 80 GiB, not production's full-RAM configuration;
VM200 work shares the host. These timings cannot establish production latency
or a clean old-vs-new extension speedup.

## Evidence and scope limits

Raw artifacts: `/data/pgfts-1121-validation-20261014/` on VM100.
VM801 install/rollback: `/var/lib/pgfts-rehearsal/upgrade-1121-20261014/`.
Source/binary identity, source and install reviews, failed setup logs, successful
qualification logs, memory probes and before/after corpus controls are retained.

This task qualifies PostgreSQL 18 on x86_64 and the actual VM801 corpus.
No PG17/19, sanitizer/fuzz, ARM or Windows release qualification is claimed.
Nix is not installed here; Docker used PGXS instead. No commits/pushes or
production changes have been made. The completed replay left no tagged backend
sessions; the index OID, relfilenode, size and valid/ready flags are unchanged. New no-op SQL files may remain after an
old-runtime rollback; the restored old control/library select the old version.

## Reproducibility files in this repo

`data_freecase_1121_2026-10-14/` contains source and artifact identities, the
independent counts/tie-out, before/after controls, long-opinion proof, cancellation
probe receipts, qualification logs and the full per-cell paired CSV. The 450 raw
samples with full SQL remain at the VM100/VM801 paths above.

Installer review found a stopped-server rollback gap; before execution, the
script was changed to validate through pg_controldata, verify the saved archive
and restored library hashes, guard live sessions when available, handle both
catalog-version states, and mark failures. LOAD was added after restart. The
updated rollback script was syntax checked; an actual rollback was not necessary
and is not claimed as tested.

### Independent final verification

Mac-claude independently recounted all coverage figures and medians from the
paired CSV, checked evidence hashes and qualification logs, and confirmed the
88/88 identical ordered case-ID lists. No blocking findings. The review is
preserved in `data_freecase_1121_2026-10-14/MAC-RESULTS-CHECK.md`; its wording
corrections are incorporated above. This was a files-only review, not another
database test.
