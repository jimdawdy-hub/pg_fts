# pg_fts 1.12.1-freecase VM801 results: files-only tie-out (mac-claude)

Reviewer: mac-claude (Claude Opus 5.5, claude-opus-5-5), 2026-10-14. I read files on VM100 only and ran nothing on VM801 or any database.

Read: `bench/RESULTS_FREECASE_1121_2026-10-14.md`, plus `bench/data_freecase_1121_2026-10-14/` (SHA256SUMS, CSV, comparison JSON, logs).

**Verdict: every number I rechecked matches the write-up. I have no findings that block anything.**

## Independently recounted from `comparison-per-pass.csv`

- 225 rows = 75 cells x 3 passes; no duplicate (query, scope, pass).
- Per-pass coverage and medians match the table exactly:
  - off totals 33 complete / 84 best_effort / 108 timed_out;
  - on totals 98 / 37 / 90.
- `on_legacy_fallback = True` on 127 rows, which equals 37 + 90.
- Passes 2-3: nationwide off 0/66 vs on 52/66 (medians 6.30 s / 2.71 s); filtered off 27/84 vs on 32/84 (8.60 s / 7.25 s).
- The leading engine alternates (38/37 per pass).

## Other checks

- `sha256sum -c SHA256SUMS`: all OK.
- `regress-final.log`: 18/18 regression tests and 2/2 isolation tests pass, including `dict_dir`, `doclen_slots`, `shared_doclen` and `scan_keys` (my Q1).
- `tap-final-with-deps.log`: Files=12, Tests=137, Result: PASS.
- `OLD-NEW-ON-RESULT-COMPARISON.json`: 88 pairs, 88 identical in order, 88 identical as sets, 79 nonempty.
- 900 raw sample files are under `historical-comparison/samples`. I didn't open them.

## Notes (not defects)

- **T1 (wording).** The column "Partial legacy fallback" also labels the off rows. In off mode, `best_effort` is the legacy path itself, not a fallback. Suggest "Partial (best effort)".
- **T2 (the result that matters for Jim).** On mode still timed out on 90 of 225 searches (40%), and 33 of the 150 warm searches. The new engine improves completion, especially nationwide. It does not remove the timeout problem, because the application's projection and post-filtering are unchanged. The write-up already says this; it should lead any production decision.
- **T3 (scope).** These checks cover compatibility and correctness. They are not a production latency measurement, which the write-up also states.

The rollback was not exercised, and I don't claim it was.
