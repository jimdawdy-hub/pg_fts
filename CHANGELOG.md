# Changelog

All notable changes to pg_fts are documented here.

## Unreleased

### Proximity, phrase search, and ranking

- Added unordered `w/N`, chained/nested groups, OR alternatives and phrases on
  either side. Complete first/last-word spans preserve every valid combination.
  `p/N` and `NEAR` retain ordered endpoint behavior. AND/NOT inside text proximity
  remain explicit errors.
- Added exact `<->` / `<N>` operators, including `<0>`. Quoted phrases preserve
  stopword gaps. Native `tsquery` imports retain exact gaps, prefixes and weights.
  Text and binary query roundtrips preserve operators and distances.
- Prefix, fuzzy and regex operands now contribute their actual positions inside
  phrases. Weighted prefixes retain their mask; unsupported modifier combinations
  raise errors. Unterminated regex input now errors instead of returning empty.
- Compound positive proximity uses stored index positions, with shared span
  evaluation and exact heap fallback when positions are unavailable or oversized.
  Compound fuzzy/regex candidates preserve ordinary OR alternatives and use native
  character edit distances. No index format change or REINDEX is required.
- Ranked searches now include pending documents and modifier matches using an
  exact heap fallback. The existing literal-term BM25 scoring formula is unchanged;
  expansion-only matches can score zero. Stable score/TID ordering fixes missing
  and duplicate rows when an ordered scan grows its result batch.
- Standalone fuzzy matches now use character edit distances consistently for
  Unicode and long terms. Removed unsound trigram and byte-length exclusions;
  bounded ASCII dictionary skipping remains available.
- Binary query input rejects conflicting modifiers, invalid weights, and
  out-of-range distances. Legacy boolean distances and zero-distance ordered
  operators retain their existing interpretation when read.
- Runtime NULL index keys no longer crash the server. A NULL search predicate
  produces no matches; a NULL order key with a valid predicate preserves the
  matches. An unfiltered NULL-only index ordering raises an explicit error.
- Fixed four inherited ranked-search defects: a seek could read another term's
  block header, block bounds could be applied past their valid document range,
  MaxScore used suffix bounds for a low-impact prefix, and cutoff ties could
  evict the wrong row. Strict regressions compare small result limits with the
  exhaustive score/TID order, without the former percentage tolerance.
- Fixed score-addition order across ranked result limits. Tiny floating-point
  changes could reorder tied rows and make adaptive index scans repeat or omit
  results. Pruning bounds use the same addition order as final scores so they
  cannot underestimate a candidate through grouped rounding. Three-term and
  four-term queries now have exact prefix checks.
- Independent exhaustive SQL checks cover direct, indexed, counted and ranked
  result sets with positions on/off, pending/flushed data, and text/binary I/O.
  Strict checks compare ranked prefixes and complete indexed result sets.
- Known inherited limitation: the configured analyzer caps positions at 16,383.
  For example, a phrase after 17,000 filler words fails on that analyzer but works
  with the unconfigured analyzer. This change does not recover already-lost input
  positions or redesign the dictionary pipeline.

### Fixed

- **NOT over a phrase, proximity or field-restricted operand under-counted through the
  index.** The boolean evaluator behind bitmap scans, `fts_count` and ranked filtering
  approximates a phrase, `w/N`, `<N>` or `NEAR` operand as the AND of its terms, and a
  `term:LABEL` operand as the term's presence (postings carry no zone labels). Presence is
  a superset of the true matches, which the heap recheck trims -- but under a NOT the
  superset becomes a subset, and a recheck cannot restore rows it never sees. With or
  without stored positions, `apple & !"bravo cherry"` returned 34 of 206 matching rows,
  and `apple & !cherry:A` 25 of 154. Such operands are now approximated from below (as
  matching nothing) when they sit under an odd number of NOTs, so the candidate set stays
  a superset and the recheck is exact again. Reproduction (1.8.3 and the previous
  Unreleased state return 0; correct and now returned: 1):

      CREATE TABLE t (d ftsdoc);
      INSERT INTO t VALUES (to_ftsdoc('alpha bravo x cherry'));
      CREATE INDEX ON t USING fts (d);
      SET enable_seqscan = off;
      SELECT count(*) FROM t WHERE d @@@ 'alpha & !"bravo cherry"';

- **A scan retried after a concurrent merge freed two buffers twice.** When the segment
  directory changed during a scan, the retry path freed the tombstone maps and the
  positional path's TID buffer, both already freed. Found by reading the code while
  reworking the positional path (the first was reported by the `claudefts` branch); not
  reproduced, since it needs a merge to land inside the scan window, which only the
  test-hook build can force. The retry no longer frees either.

### Performance

- **Proximity combined with AND or NOT is decided from the stored positions.** On a
  `positions = on` index only a query of proximity and OR operators used the positions;
  once a phrase, `w/N`, `<N>` or `NEAR` operand sat beside an AND or under a NOT, every
  candidate was rechecked against the heap -- re-deriving its `ftsdoc` from the table row
  -- in the bitmap scan, `fts_count` and the ranked scan alike. Such queries now take the
  span matcher the heap recheck itself uses (`fts_match_eval`), fed from the postings:
  each distinct term is decoded once per segment and every candidate is decided there.
  In the regression corpus a bitmap scan of `apple & "bravo cherry"` used to remove 172
  rechecked rows; it now rechecks none. Answers are unchanged.

  A posting block that could not store its positions (its Sum(tf) overflowed a page), or
  a document whose positions overflow the evaluator's bound, used to abandon the
  positional path for the WHOLE query, recheck included. Now only those documents go to
  the heap recheck, and only when a proximity operator needs their positions -- a term
  read for its presence alone never does. The bitmap scan flags just those rows for the
  executor's recheck; `fts_count` and the ranked scan recheck just that subset. Prefix,
  fuzzy, regex and weight-restricted terms keep the recheck path.

- **`a & !b` no longer decodes every posting list in the segment.** Whenever a query
  contained NOT, the evaluator behind bitmap scans and counts first built each segment's
  "universe" -- every TID in the segment, found by decoding every posting list. It needs
  that set only when the query's final result is negated (`!a`, `!a & !b`, `a | !b`):
  negation is tracked with De Morgan, so `a & !b` is a plain set difference and paid for a
  full-segment decode it never used. The universe is now built per segment only for a
  negated final result. Answers are unchanged.

- **The ranked scan ignored a `WHERE` query that differed from its `ORDER BY` query.**
  `bm25_rescan` kept the first scan key's query and then overwrote it with the `<=>` query,
  so the ordering scan ranked *and filtered* by the `ORDER BY` query alone -- and it returns
  `xs_recheck = false`, so the executor never re-applied the `WHERE`. It returned `ORDER BY`
  matches that fail the `WHERE`, missed the `WHERE` rows holding no ranking term, and let
  the ranking query's own boolean operators filter. Reproduction:

      CREATE TABLE t (id int, d ftsdoc);
      INSERT INTO t VALUES (1, to_ftsdoc('simple', 'apple cherry')),
                           (2, to_ftsdoc('simple', 'apple')),
                           (3, to_ftsdoc('simple', 'cherry cherry'));
      CREATE INDEX ON t USING fts (d);
      SET enable_seqscan = off; SET enable_bitmapscan = off;
      SELECT id FROM t WHERE d @@@ 'apple'::ftsquery
       ORDER BY d <=> 'cherry'::ftsquery LIMIT 10;     -- 1.8.3: 3, 1   now: 1, 2

  The filter is now the AND of every scan key (next entry) and the rank is the `ORDER BY`
  query. When the single `WHERE` query is byte-identical to the `ORDER BY` query -- the
  common shape, including one CTE or parameter value feeding both -- the scan takes the
  unchanged path. Otherwise the ordering scan materializes the filter set with the
  `@@@` evaluator, scores every row of it by the `ORDER BY` query's terms in one merge-join
  pass over their postings (the per-term BM25 contribution the top-k engine uses; the
  ranking query's operators do not filter, as `ORDER BY` never does), and returns the scored
  rows by descending score, equal scores in heap order, then the rows holding no ranking term
  at distance 1. It can return every filter row, each exactly once, however deep the executor
  pulls. A filter row still in the pending list comes back unranked with the distance-1 rows;
  an over-generating filter is rechecked by the executor on only the rows it pulls.
- **Only the first `WHERE` key was applied.** `bm25_rescan` read `keyData[0]` alone, so two
  `@@@` quals served by one bitmap, plain or ordering index scan applied only the first --
  and those paths return no recheck for an exact query, so the executor never applied the
  second either. With `t` from the entry above (rows 1 and 2 hold `apple`, only row 1 also
  `cherry`): `SELECT id FROM t WHERE d @@@ 'apple'::ftsquery AND d @@@ 'cherry'::ftsquery;`
  returned 1, 2 on 1.8.3 and returns 1 now, as a sequential scan does. Every scan key is now
  read and the scan returns their AND (byte-identical keys folded, so a repeated qual keeps
  its single-key path); the COUNT pushdown was not affected (it takes only single-qual
  counts).
- **A NULL `ORDER BY` argument is served by the filtered ordering scan.** The runtime
  NULL-key entry above already stopped the crash. A NULL `<=>` argument beside a `WHERE`
  filter now takes the filtered scan, which returns the filter rows (the AND of every key)
  with a NULL distance for every `ORDER BY` key; the previous path stored one distance
  whatever the number of keys. A NULL `WHERE` key still returns no rows, and an unfiltered
  ordering by distance to NULL still raises an error.

### Known issues

- **A deep ordering scan can return duplicate rows and miss others (identical `WHERE` and
  `ORDER BY` query; present in 1.8.3, narrowed but not fixed here).** On a two-segment
  fixture (2,000 documents holding `cherry` with tf 1-7, 10% deleted and re-inserted, then
  VACUUM), `WHERE d @@@ 'cherry' ORDER BY d <=> 'cherry' LIMIT 100000` returns 2,000 rows but
  only 1,785 distinct ids on this tree (129 returned twice, 43 three times, 215 matching
  rows never returned), against 1,762 distinct on 1.8.3;
  `fts_search(idx, 'cherry', 100000)` returns all 2,000 distinct rows on the same fixture.
  The adaptive-k ordering scan recomputes the top-k for a larger k and resumes at the count
  of rows already returned, which assumes each larger top-k extends the previous one in the
  same order. The `wand_skip_blocks` last-block skip is fixed above (inherited ranked-search
  defects); the filtered scan decodes forward rather than calling `wand_seek`, and returns
  every filter row exactly once.

### Tests

- The `fts_vacuum()` convergence check keeps autovacuum off its table. It asserts that three
  consecutive `fts_vacuum()` calls leave the index size unchanged, and an autovacuum pass
  between two of them could run the index cleanup and change the size: under aggressive
  autovacuum settings 1.8.3 failed the check in 3 of 5 runs; with autovacuum off on the table
  it passed every run. The assertion itself is unchanged.
- A regression block compares ten NOT shapes through the index (bitmap scan and
  `fts_count`) with the heap matcher, across two segments with tombstones plus the
  pending list.
- A regression block counts fourteen shapes with NOT over a phrase, `w/N`, `<->`,
  `NEAR` and `term:A` operand six ways (bitmap scan and `fts_count` on a positions = on
  and a positions = off index, and the heap matcher on each table), over two segments,
  tombstones and a pending list. Every expected count was checked against an independent
  computation of the fixture's truth.

- One existing expected line changed, to the heap truth: `SELECT count(*) FROM psh WHERE d
  @@@ 'term1' AND d @@@ 'body'` now expects 0, not 50. The english configuration stores
  "body" as `bodi`, so the raw `'body'` matches no row -- a sequential scan answers 0 on
  1.8.3 too -- and 1.8.3's 50 came from applying only the first key (above). A new line with
  the stemmed `'bodi'` expects the 50.
- `pg_fts` regression: filter-vs-rank through the ordering scan (stored and expression
  index, positions on and off), pending rows, two `WHERE` keys on the bitmap, plain and
  ordering paths against a sequential scan, the one-value CTE shape (unchanged top-k path;
  its pending row is ranked by the exact pending fallback), a deep pull across segments with deletes, VACUUM
  and heap-slot reuse (every filter row exactly once, in exact order), and NULL `WHERE` and
  `ORDER BY` values.

## 1.8.3 - 2026-09-18

**Correctness release: two deadlocks that shipped in every prior version, found while
fixing the bulk-ingest bloat -- which is also fixed.** No on-disk format change; **no
REINDEX required**. Upgrade recommended for any index taking concurrent inserts.

### Fixed

- **Deadlock: concurrent insert + VACUUM on the same index.** The insert path's
  "directory is full, merge to make room" (`bm25_add_segment_with_room`) was the only
  merger that did not take the maintenance mutex, so it could run concurrently with
  autovacuum's merge. Under the old extend-only allocation the two never touched the same
  block and the race was merely wasteful; once merges reuse pages (below) both mergers
  handed out the same block and deadlocked on its buffer lock. **Confirmed on v1.8.2 as
  shipped**: the same row-per-transaction ingest with autovacuum on deadlocks at row 1,674
  with no other change. Every merger now takes the mutex, and both merge entry points
  `elog(ERROR)` if entered without it -- which immediately caught a second unprotected
  site, `CREATE INDEX CONCURRENTLY`'s finalize (holds only ShareUpdateExclusiveLock), now
  also covered.
- **Deadlock: a live page handed out as merge output.** `bm25_page_recyclable()` returned
  *true* for a page without the `BM25_FREED` flag ("older free, or in-use race"). The FSM
  records free *space*, not liveness, so a partially filled **live** posting page qualified
  -- instrumented live: `blk=65 flags=0x4 nextblk=66`, mid-chain -- and was written as
  output while the same merge held it pinned as input. Self-deadlock. An un-flagged page
  is now treated as live and never handed out, checked before the AccessExclusiveLock
  bypass as well. Pages freed by builds predating the flag are reclaimed by tail
  truncation instead of reuse.
- **Bulk-ingest growth eliminated on row-per-transaction ingest.** Root cause: the merge
  allocated `EXTEND_ONLY` for its whole loop and so never consulted the free list -- not
  for pages freed by *this* call (the hazard it guards) and not for pages freed by
  *previous* calls (safe, and nearly all of them). At high terms-per-document every insert
  triggers a merge, so the merge was the dominant writer and its freed pages were reachable
  only by `fts_vacuum`. New `BM25_ALLOC_SNAPSHOT` mode gathers the free list **once at
  entry, before this call frees anything**, hands out only from that snapshot, and never
  re-consults the live FSM -- so the recycle-race guard holds by construction and earlier
  frees are reused.

  Measured at field shape (40k docs at 1,660 terms/doc, then row-per-transaction churn,
  autovacuum on, nothing manual): **v1.8.2 grew 1,823 -> 4,975 -> 8,383 MB then deadlocked;
  1.8.3 held 1,823 -> 1,823 -> 1,823 -> 1,832 -> 1,831 -> 1,823 -> 1,823 MB over 30,000
  documents.** A 100,000-document run ended at 1,875 MB with `fts_vacuum` finding **nothing
  to reclaim** -- the resident size is the live size. Parity vs regex exact throughout.

### Known issue (narrowed)

- **A single very large `INSERT ... SELECT` of oversized rows still bloats until
  `fts_vacuum`.** Inside one statement the freeing transaction is itself the oldest
  snapshot, so no page it frees can pass the recyclability horizon until it ends; no
  allocation policy changes that. Modelled the alternative (fewer, larger merges inside a
  long statement): the leveled merge already amortises to log_F(N) rewrites, so it is worth
  ~2x, not the 8x it looks like. `fts_vacuum` after a bulk load remains the guidance for
  that one shape; it takes seconds.

### Tests

- `t/007_segment_cap.pl` runs repeated `VACUUM`s concurrently with its four
  directory-filling inserters, under a 300 s deadline. **Verified red on v1.8.2's
  `pg_fts_am.c` and green on 1.8.3** with the harness restored between runs. Two harness
  defects fixed on the way: pumping one IPC::Run handle at a time starved the others
  (mimicking the deadlock on correct code -- the wait events said `ClientRead`), and psql
  fed from a scalar needs an explicit `\q` or completion is unobservable.

### Retracted

- 1.7.2's diagnosis that the bloat mechanism was "freed pages fail the recyclability XID
  gate in the inserting transaction" was **half right**: that binds only inside a single
  multi-row statement. On row-per-transaction ingest -- the field's live shape -- the
  cause was the extend-only merge, and a fresh transaction per row changed the result by
  only 1.4x until that was fixed. Details and the falsified prediction that exposed it:
  `bench/RESULTS_I1_2026-09-18.md`.

## 1.8.2 - 2026-09-17

Code-quality release from the fresh-eyes review (`REVIEW_2026-09-17.md`), plus one real
fix found while doing it. No on-disk format change; **no REINDEX required**.

### Fixed

- **A ninth unvalidated `pd_lower` read**, in the trigram blob reader
  (`pg_fts_trgm_index.c`). It computed a `memcpy` length as `pd_lower - contents_offset`;
  on a corrupt or recycled page whose `pd_lower` is below the contents offset that wraps
  to a huge `Size` before the `Min()` clamps it, and the copy runs past the page. Same
  defect class as the 1.7.0 P0 that made an index permanently unvacuumable. Now routed
  through `bm25_page_data_end()`, as are the 14 remaining reads in `pg_fts_am_scan.c`.
  1.7.1 claimed to have fixed "all eight" sites; this makes it nine, and the count is now
  every read of `pd_lower` in the tree.

### Changed (behaviour-preserving; full gate green after each)

- **Allocator state is a scoped struct, and misuse is a hard error.** The four file-scope
  globals (`bm25_lowfree`, `_n`, `_i`, `bm25_alloc_extend_only`) became one
  `BM25AllocCtx` reachable only through `bm25_alloc_scope_enter()` /
  `bm25_alloc_scope_exit()`, which nest by returning the previous context. In the 1.7.1
  work, code read those globals without owning them and handed out garbage block numbers
  ("could not open file ... target block 829694001: previous segment is only 527 blocks");
  only `t/007_segment_cap.pl` noticed. `bm25_new_buffer()` now `elog(ERROR)`s on that
  condition. Deliberately an `elog`, not an `Assert` -- the release gate is not a cassert
  build, and a check that fires only in a build nobody ships is documentation, not
  enforcement.
- **`bm25_collect_matches` split, 412 -> 226 lines.** The per-segment loop body is now
  `bm25_collect_segment()` (returns `SEG_RESTART` for the positional-phrase fallback the
  loop used to express as `s = -1; continue`) and the pending-list walk is
  `bm25_collect_pending()`. Shared state travels in a `BM25CollectCtx`.
- **The single translation unit is now a documented decision, not an accident.**
  `pg_fts_am.c` `#include`s `pg_fts_am_scan.c`, `pg_fts_trgm_index.c` and `pg_fts_lev.c`.
  Splitting was costed: 15 statics would go extern, ~10 shared types would move into the
  on-disk-format header, and the hot-path `static inline` helpers inside the 45%/37%
  common-term profile would stop inlining (PGXS does not use LTO). In return, three `.o`
  files and no behaviour change. Kept; the reasoning is at the `#include` site and in both
  included files' headers, with the two prerequisites if separate compilation is ever
  needed.

## 1.8.1 - 2026-09-17

Counting-path work from the TIN feasibility review. No on-disk format change; **no REINDEX
required**.

### Added

- **Ten gate-refusal tests for the single-term `count(*)` fast path.** That fast path
  (answering from the dictionary's `df` with no posting decode and no heap access) has
  existed since the COUNT pushdown work, but shipped with a single positive test and nothing
  proving its gates actually refuse — the shape where a missed gate silently returns a
  plausible **wrong count**. Each case is now compared against a ground truth computed
  without the index: prefix, conjunction, disjunction, negation, unmerged pending documents,
  tombstones, and a not-all-visible heap all fall back and agree exactly, and the fast path
  is confirmed to resume after `VACUUM`.

### Changed

- `fts_count()` and the `COUNT(*)` pushdown now consult the visibility map **once per run of
  matches on the same heap page** instead of once per matching tuple, and create one tuple
  slot per call instead of one per probed tuple. Safe because matches arrive sorted and
  de-duplicated and a docid is `block × MaxHeapTuplesPerPage + offset`, so matches on a page
  are contiguous; the visibility map is page-granular.

  **Measured effect: none significant (~1–2%, inside run-to-run noise).** An apparent 8.5%
  improvement came from a single high outlier in the baseline; repeated same-arm runs
  overlap (base 397.3–408.2 ms, fix 397.4–402.7 ms). The loop is dominated by
  `table_index_fetch_tuple` heap probes, not by visibility-map lookups. Counts are
  identical in both arms. Shipped as a code-quality change, not a performance feature.

### Documentation

- README and the SGML manual now describe when the `df` fast count applies and, more
  importantly, when it refuses.
- `bench/RESULTS_ABC_2026-09-17.md` records the measurements, including the two corrections
  above; `bench/NOTE_TIN_FEASIBILITY_2026-09-14.md` is annotated with the outcome. A third
  proposed item (copying posting bytes verbatim during a merge) was **withdrawn** after
  reading the merge path: it decodes through the build hash table and re-encodes at flush,
  so there is no byte-stream splice point.

## 1.8.0 - 2026-09-14

**Query parsing fix with a behaviour change.** No on-disk format change; **no REINDEX
required** — stored data was never affected.

### Fixed

- **`-`, `.` and `/` inside a word are terms, not operators.** Reported from the field:

  | query | before | after |
  |---|---|---|
  | `pkg-config` | `('pkg' & !'config')` | `'pkg-config'` |
  | `install-info` | `('install' & !'info')` | `'install-info'` |
  | `foo/bar` | `'foo'` (rest swallowed) | `'foo/bar'` |
  | `python3.14` | `('python3' & '14')` | `'python3.14'` |

  The hyphen case was the damaging one: the `!` clause **actively excluded the documents
  being searched for**, so searching `pkg-config` returned everything *except*
  pkg-config, and `install-info` matched 1 row instead of 10. `/` was worse in a
  different way — it opened a regex and swallowed the remainder of the query. As the
  reporter put it, this is a worse failure mode than operator injection: injection raises
  a visible error, this silently returns a different, wrong answer.

  The separator set is not a guess — it is what the **document analyzer already joins**,
  verified against `to_ftsdoc('simple', 'a-b c/d e.f g_h i+j')`, which yields
  `'a-b' 'a' 'b' 'c/d' 'e.f' 'g' 'h' 'i' 'j'`: `-`, `.` and `/` stay inside a token while
  `_` and `+` split. PostgreSQL's own parser agrees, classifying them `asciihword`,
  `file` and `file`. So the query lexer was the only side that disagreed, and the tokens
  needed to match these queries were already stored.

### Behaviour change

- A `-` between two word characters no longer negates. **`a -b` still excludes `b`**
  (prefix position), and `!b` is unchanged, but an application relying on `a-b` meaning
  "a AND NOT b" must now write `a !b` or `a - b`.
- `c++` and `gtk+` still lex to `'c'` and `'gtk'`. A trailing separator is dropped, which
  is what `to_tsvector` and our own document analyzer do, so this is parity rather than a
  bug — noted because the original report listed it alongside the others.

Regression cases covering all four inputs, plus prefix negation, leading `-`, and
`/regex/`, are pinned in `sql/pg_fts.sql`.

## 1.7.2 - 2026-09-14

Measured the cause of the bloat known issue and removed ~31% of it. No on-disk format
change; **no REINDEX required**.

### Fixed

- **Bulk ingest grows the index ~31% less.** At high terms-per-document every document
  exceeds one pending page, so each one mints a **one-document segment** — and the
  insert-time merge then folded it in immediately, rewriting a whole level-0 run for every
  single document. Measured: **23–30 index pages extended per document** (linear) against
  roughly 2 pages of actual postings, a ~12–15× write amplification with page reuse at
  ~0.3%.

  The merge is now gated on there being `BM25_MERGE_FANOUT` small runs waiting. Below that
  threshold the leveled compactor would find no level over capacity and do nothing anyway,
  so this skips work without changing behaviour. Over six 5,000-document batches the index
  peaked at **21,874 MB instead of 31,537 MB**, and the size after one `fts_vacuum` is
  byte-identical (124 MB).

  The segment-directory bound this protects was re-verified under the worst case for
  segment minting — one row per transaction, 4,000 transactions — reaching a maximum of
  **15 segments against the hard cap of 128**. `t/007_segment_cap.pl` now asserts `<= 64`
  rather than `<= 128`, since a bound at the cap only fails once the index is already in
  the state that motivated the eager merge (a field deployment went 8 → 128 segments in
  ~1 h and could then neither merge nor VACUUM).

### Known issues

- **The bloat is reduced, not eliminated.** Growth is still ~3.7 GB per 5,000 documents at
  field shape, and `fts_vacuum` after bulk ingest is still recommended (it is fast — tens of
  seconds for millions of pages — and recovers the space completely).

  The mechanism is now measured rather than guessed: freed pages **are** found and then
  **rejected** by `bm25_page_recyclable()`, because they were freed by the inserting
  transaction itself and `GlobalVisCheckRemovableXid()` cannot yet clear them
  (`norecyc=3,169` of 5,924 allocations). That gate is correct and must stand — bypassing it
  previously corrupted a concurrent reader. So in-transaction reuse is impossible by
  construction, and fully fixing this means moving the merge out of the inserting
  transaction: a design change, not a point-release edit.

Measurements: `bench/RESULTS_KNOWN_ISSUES_2026-09-14.md`.

## 1.7.1 - 2026-09-14

Follow-up to 1.7.0's page-corruption fix, plus a **retraction of one of 1.7.0's known
issues**. No on-disk format change; **no REINDEX required**.

### Fixed

- **The `pd_lower` bounds guard is now applied at every page-read site.** 1.7.0 fixed the
  dict walk in `merge_source_load_page`, where an unvalidated `pd_lower` made the merge
  request an impossible allocation and left the index permanently unvacuumable. Auditing the
  siblings found **eight** sites forming `page + pd_lower` from unvalidated on-page data —
  including both walks in `bm25_free_segment` and the doclen and posting readers. All now
  route through one helper, `bm25_page_data_end()`, which validates in the integer domain
  (forming the pointer at all is undefined behaviour for an absurd value) and returns an
  empty range for anything out of bounds, so a caller degrades to "this page has nothing to
  read" rather than walking off the page. 1.7.0 fixed one instance of this defect; this
  fixes the class.

### Retracted

- **1.7.0's "`bm25_free_page` emits one WAL record per page" known issue was wrong.**
  Measured directly: `fts_vacuum` freed **8,686,917 pages in 46 seconds — 0.005 ms/page**,
  roughly 2,800× cheaper than the ~14 ms/page I published, and a second run confirmed it
  (7,912,288 pages in 33 s). There is no per-page WAL problem and no WAL batching is needed.
  My figure came from a 113-minute run on an index that had already hit the 1.7.0
  allocation bug repeatedly; `gdb` showed the backend inside `bm25_free_page` and I turned
  "where it is" into "why it is slow". A stack sample gives a location, not a bottleneck.

### Known issues

- **The transient bloat spike is confirmed and larger than reported: ~210×, not 45×.**
  Measured at field shape (1,660 terms/doc), inserting 5,000 documents at a time with no
  maintenance: the index grows **~5.6 GB per batch with `nsegments` pinned at 8**, reaching
  61,814 MB after ten batches, and a single `fts_vacuum` returns it to **236 MB**. The space
  is freed-but-never-reused, not live.

  **The cause is not yet known.** Four hypotheses were eliminated: one-doc segment
  accumulation (impossible — `BM25_MAX_SEGMENTS` is 128 and the insert path forces a merge),
  128-segment cycling (`nsegments` sits at 8), freed pages failing the recyclability XID gate
  (instrumentation showed the free-list scan is never reached: `probe=0 reject=0`), and
  loop-wide `bm25_alloc_extend_only` (scoping it per merge produced *byte-identical* growth
  — reverted rather than shipped as a fix). The next step is a counter on each of
  `bm25_new_buffer`'s three outcomes rather than another hypothesis.

  **Practical guidance unchanged:** run `fts_vacuum` after bulk ingest. It is fast (tens of
  seconds for millions of pages) and recovers the space completely.

Details and measurements: `bench/RESULTS_KNOWN_ISSUES_2026-09-14.md`.

## 1.7.0 - 2026-09-13

Two field-blocking fixes found by reproducing the reported ~2.87M-doc email-body index
shape. No on-disk format change; **no REINDEX required**.

### Fixed

- **An index could become permanently unvacuumable.** The dict-page walk in
  `merge_source_load_page` took its end bound from the page's `pd_lower` with no
  validation, and stepped by an untrusted `termlen`. On a recycled or malformed page the
  walk ran past the page and counted garbage entries, so the caller's doubling asked for an
  impossible allocation:

  ```
  ERROR:  invalid memory alloc request size 3406063183
  ```

  Because this runs under `bm25_merge_segments_streaming`, it failed **every merge, every
  autovacuum cleanup, and `fts_vacuum`** — the index could never be vacuumed or reclaimed
  again. This is the likely cause of the reported "VACUUM/merge do not reclaim bloat".
  Isolated with `gdb`; both the counting and filling walks are now bounds-checked, and
  `pd_lower` is validated as an integer before any pointer is formed from it (forming
  `page + pd_lower` for a corrupt value is itself undefined behaviour — the new fuzz target
  for this loop caught that with UBSan).
- **Huge-allocation gaps** in `bm25_doclens_load`'s resident docid array and `bulkdelete`'s
  `carry`/`newdead` tombstone arrays, which used plain `palloc`/`repalloc` and so failed the
  same way on a large or delete-heavy index. The `FTS_ALLOC_MAYBE_HUGE` macros already
  existed for the per-term posting arrays; these sites were missed.
- **Index cleanup no longer grows the index.** `bm25_vacuum_compact` now skips a compaction
  pass when its free space is not yet *reusable*: `bm25_page_recyclable()` gates on
  `GlobalVisCheckRemovableXid()`, so pages freed by the same cleanup's merge are all
  rejected, and the pass would relocate live data upward while reclaiming nothing. Measured
  before: 35 → 52 → 69 MB across three cleanups with no rows added. After: flat.

### Added

- Fuzz target for the dict-page walk (`test/fuzz/fuzz_block.c`), asserting the walk stays
  inside the page and can never report more entries than a page can physically hold, for
  arbitrary page bytes and arbitrary `pd_lower`.
- `t/010_vacuum_delete_heavy.pl` now asserts **no growth** across repeated cleanups, and
  additionally that cleanup still **reclaims** after deletes.

### Known issues

- **A transient bloat spike at `nsegments=8`**, reproduced at field shape: an index went
  299 MB → **66,796 MB** → 1,016 MB across three churn rounds, settling at 1,480 MB. The
  index is not permanently bloated — it inflates ~45× while segments accumulate and
  collapses once merges catch up, so an index sampled during that window looks like
  unbounded bloat. Not yet fixed.
- **`bm25_free_page` emits one WAL record per page.** `fts_vacuum` on a 3.8 GB index ran
  113+ minutes without finishing (progressing, not hung): ~489k pages × a full
  `GenericXLog` delta each. Needs WAL batching. Not yet fixed.

Both are documented with reproductions in `bench/RESULTS_FIELDSHAPE_2026-09-13.md`.

### Documentation

- README and the SGML manual no longer recommend scheduling a periodic `fts_vacuum`.
  Measured at 1M docs with autovacuum on and no manual maintenance: flat at 511 MB over
  five cleanups, flat at 875 MB over six churn rounds, and 875 → 106 MB after deleting half
  the table, with results exact throughout.

## 1.6.1

**P0 fix: `VACUUM` could consume CPU indefinitely and never complete on an index
with many tombstones.** C-only, no SQL objects, no on-disk format change
(BM25_VERSION stays 4), **no REINDEX** — `ALTER EXTENSION` is the whole upgrade.

Also re-vendors sparsemap 5.4.0 → 5.5.1.

### The bug

On a 2,188,038-document index, deleting 312,166 rows and running `VACUUM` produced
a backend pinned at 100% CPU that **never finished** — 4h39m of CPU consumed, with
**99.75% of `perf` samples in `__sm_get_chunk_offset`**, reproduced twice. There was
no error and no log line; the index simply never got cleaned.

Because a `VACUUM` that never completes also never reclaims space, an index that
appeared never to shrink after deletes is a likely symptom of this. If you have seen
either behaviour, this release is the fix.

Measured after the fix, same workload: **393 s and completes**, with results
identical to sequential-scan ground truth.

| stage | before | after |
|---|---|---|
| `VACUUM` with 312k tombstones | 4h39m CPU, never finished | **393 s, rc=0** |
| further round (376k more deleted) | — | 270 s |
| further round (375k more deleted) | — | 178 s |
| `fts_vacuum` | — | 135 s |

Correctness verified at every stage — index counts equal sequential-scan counts
(`year` 504368/504368, 378037/378037, 251902/251902; `slovakia` 5605/5605,
3751/3751).

### Root cause: one mistake in two places

Both sites probed the tombstone sparsemap in a pattern that defeats every
acceleration structure it offers, so each membership test walked the chunk chain from
the head. At ~1,068 chunks × millions of probes, that does not terminate in practical
time. **Fixing the first site only exposed the second.**

1. **`bm25_merge_segments_streaming`** (the merge/compaction path, reached by
   `bm25_vacuumcleanup`). This loop walks *terms* in sorted order, and each term's
   postings ascend from a low docid — so the docid sequence resets at every one of
   millions of term boundaries. Neither the 8-way MRU cache used here, nor a
   forward-resume cursor, nor batched `sm_contains_many` survives that: each pays an
   `O(chunks)` startup *per term*.
   **Fix:** the tombstone map is read-only for the whole merge, so decode it **once
   per source** into a dense bitmap (`sm_next_member`, a single forward pass) and test
   each posting in **O(1)**.
2. **`bm25_bulkdelete`** (the per-index delete path). A cursor *was* used, but was
   declared **inside** the walk and therefore reset every iteration, restarting each
   lookup from the head. The enclosing walk is monotonically ascending — exactly the
   cursor's contract — so the cursor was right in intent and defeated by its scope.
   **Fix:** hoist the declaration out of the loop.

This is the same class of pathology fixed for the *ranked scan* in 1.4.1 (24 s →
2.5 ms); these two paths never received the equivalent treatment.

### sparsemap 5.4.0 → 5.5.1

Re-vendored as exactly upstream plus our one namespacing block; `vendor/sm.h` is
byte-identical to upstream, and the public header changes only its version macros, so
this is a drop-in.

Two fixes reach code pg_fts actually executes:

- **Big-endian chunk-descriptor flag reads** (5.5.0). Ten sites aliased the 64-bit
  descriptor as `uint8_t *`, walking its 2-bit flags in reverse on big-endian and
  breaking every counting and navigation path. `sm_contains` was unaffected because it
  shifts the word directly — which is precisely why the bug hid behind a working
  membership test. pg_fts is exposed through `sm_next_member`, used to iterate
  tombstones. (Note: big-endian remains untested in our CI.)
- **`__sm_append_data` now returns `bool` and is `warn_unused_result`** (5.5.1). In
  5.5.0 the append inside `__sm_map_set` was **unchecked**, so a full buffer silently
  overflowed instead of reporting `ENOSPC`. pg_fts reaches that path via
  `sm_add_many_grow` → `__sm_add_c` → `__sm_map_set`, and our grow-and-retry loop
  *depends* on `ENOSPC` being signalled rather than the buffer being overrun.

The three headline 5.5.0 fixes (`sm_difference` RLE data loss, `sm_offset` invalid
maps, `sm_split` ENOSPC) are in functions pg_fts does not call.

### A note on how this was found, and on our test coverage

The hang was found while qualifying the sparsemap bump at scale — not by the local
test suite. `installcheck` (PG 17/18), the full TAP set, alloc/ascii guards and the
block fuzzer all pass on the **unfixed** code, and passed on **two wrong fixes**
before the real cause was isolated with `gdb`. None of those checks deletes a large
fraction of a large indexed table and then vacuums.

The gap was known: ROADMAP item 9's outstanding task was exactly "quantify the merge
path under a delete-heavy workload", and that measurement had never been completed.
Details, including the failed attempts and why each failed, are in
`bench/P0_VACUUM_HANG_2026-09-10.md`.

## 1.6.0

**Correctness release: an unverifiable phrase no longer silently answers as a
conjunction.** C-only -- no SQL objects change, no on-disk index format change
(BM25_VERSION stays 4), **no REINDEX**. MINOR rather than patch because query
results change, for the better.

Also re-vendors sparsemap 5.4.0 -> 5.5.0, which fixes a big-endian corruption
that reaches our tombstone iteration.

### 1. A phrase whose adjacency cannot be verified now returns false

`phrase_step()` fell back to presence-only AND whenever either operand lacked
positions -- "recall preserved, precision degraded" -- so a **phrase query could
report a NON-ADJACENT document as a match**, with nothing to distinguish it from a
real phrase hit.

This is now false, which is what PostgreSQL does: absent
`TS_EXEC_PHRASE_NO_POS`, `OP_PHRASE` "always returns false if lexeme position
information is not available" (`tsearch/ts_utils.h`). Upstream returns false for
`strip(to_tsvector('simple','quick brown')) @@ 'quick <-> brown'` even though the
words *are* adjacent; `pg_fts_match.c` claims to mirror `TS_execute` and on this
branch did the opposite.

Four routes reached the bad path, all confirmed on 1.5.10:

| input | 1.5.10 | 1.6.0 |
|---|---|---|
| `$$'brown':1 'quick':1$$::ftsdoc` (canonical literal, no `@`) | t | **f** |
| `to_ftsdoc(strip(to_tsvector(...)))` | t | **f** |
| `ftsdoc \|\| ftsdoc` where one side lacks positions | t | **f** |
| `quick <-> (brown & fox)` on a **fully positioned** doc, via the tsquery cast | t | **f** |

The fourth is the important one: the boolean arms null out positions, so the
document's own flag cannot distinguish "no positions anywhere" from "this operand
lost them". The fix therefore carries an explicit reason flag on the operand, set
at exactly one producer.

**Prefix-inside-phrase is unchanged.** `"quick bro*"` stays deliberately
permissive, because prefix positions are genuinely not tracked -- that is shipped,
documented lossiness rather than a bug, and it now has test coverage it lacked.

Why false and not an error: `@@@` is a match operator, so raising an error would
be order-dependent (a predicate that errors on a full scan can succeed under a
`LIMIT`) and would turn a handful of unverifiable rows into a whole-table failure.

### 2. Field-zone restrictions on a positionless document match nothing

Zone labels are carried in each position's high bits, so a document without
positions carries no label information -- it is *unknown*, not "D". Previously
`term:D` matched **every** positionless document while `term:A` matched none, and
a concatenation that dropped one side's labels silently answered `term:D` = true.
A zone restriction that cannot be evaluated now does not match.

### 3. sparsemap 5.4.0 -> 5.5.0

Re-vendored as exactly upstream 5.5.0 plus our one namespacing block
(`SPARSEMAP_PREFIX=__pg_bm25_`); `vendor/sm.h` is byte-identical to upstream.
Header change is purely additive (one new function), so it is a drop-in.

The fix that reaches pg_fts is **chunk-descriptor flag reads on big-endian
hosts**: ten sites aliased the 64-bit descriptor as `uint8_t *`, walking the 2-bit
flags in reverse on big-endian and breaking every counting and navigation path.
`sm_contains` was unaffected because it shifts the word directly -- which is
precisely why the bug hid behind a working membership test. pg_fts is exposed
through `sm_next_member`, used to iterate tombstones, so on a big-endian host that
iteration could silently go wrong. Upstream measured a map with bits 42 and 1024
set reporting cardinality 1, minimum 768, maximum 1792 on sparcv9.

The three headline 5.5.0 fixes (`sm_difference` RLE data loss, `sm_offset`
structurally invalid maps, `sm_split` ENOSPC) are in functions pg_fts does not
call -- included, but not our exposure.

### Upgrade notes

`ALTER EXTENSION pg_fts UPDATE TO '1.6.0'` is the whole upgrade. No REINDEX, no
data migration.

If an application relied on the old lossy phrase behaviour as a cheap
conjunction, write the conjunction explicitly (`'quick & brown'`). If you issue
phrase or NEAR queries at scale, note separately that
`WITH (positions = on)` is what makes them fast -- 36x on a 2.19M-document corpus
(see 1.5.10's notes and `bench/NOTE_PHRASE_PROFILE_2026-09-06.md`).

### Validation

All three phrase evaluation paths were checked for agreement on a 3,000-row corpus
where only a third of rows have the phrase adjacent: sequential scan (heap
matcher) **1000**, index scan with `positions=off` **1000**, index scan with
`positions=on` **1000**, regex ground truth **1000**. installcheck (PG 17/18),
full TAP set, alloc/ascii guards, block fuzzer all pass; upstream sparsemap's own
suite passes 10/10 including its property tests.

## 1.5.10

Performance release: **common-term ranked top-k is 1.56x faster.** C-only, no SQL
objects changed, no on-disk index format change (BM25_VERSION stays 4), no
REINDEX. Both wins came from profiling the scan with `perf` on real hardware,
and both are ordinary read-path fixes -- no format, ordering or exactness change.

| query | 1.5.9 | 1.5.10 | change |
|---|---|---|---|
| common k10 (`year`, df 734,896) | 56.30 ms | **36.16 ms** | **1.56x** |
| common k100 | 69.78 ms | **46.01 ms** | **1.52x** |
| rare k10 / mid k10 / 2-term OR | 5.85 / 10.69 / 4.32 | 5.89 / 10.64 / 4.12 | flat |

### 1. Ascending-resume hint in the doclen lookup

`bm25_doclen_cursor_lookup()` ran an unconditional binary search over the
resident 128-entry doclen block -- **~7 branchy iterations per posting**, on a
term whose docids are consecutive. `perf annotate` put ~45% of a common-term
query in that search (the BM25 math itself was 1.68%).

The WAND scan probes docids in strictly ascending order, so the next answer is
almost always the next entry: try a short linear walk from a resume hint, fall
back to the binary search on a miss, and reset the hint whenever a new block is
decoded. **56.30 -> 42.67 ms.**

### 2. `bm25_for_get()` was still decoding bit-by-bit

`bm25_for_unpack()` (batch) had long since been optimized to a
word-load/shift/mask extraction -- its comment even says it "replaces the per-bit
inner loop that dominated posting decode" -- but **the random-access twin
`bm25_for_get()` never got that treatment** and still ran one bit-test per bit of
width, per call. It is on the hot path twice: `wand_contrib_cur()` reads `tf`
through it for *every scored posting*, and the v3 inline-doclen path reads |D|
through it too.

Gave it the same extraction, including the `shift == 0` undefined-behaviour guard
the batch version documents for a corrupt on-disk width byte. **42.67 -> 36.16
ms.** The `bm25_for_get(buf, i) == bm25_for_unpack(buf)[i]` equivalence is already
asserted by both `test/fuzz/fuzz_for.c` and `test/hegel/test_for.c`.

### Rejected by measurement (recorded so they are not retried)

- **Partial/lazy block decode for rare-term latency.** Gains ~1%. The motivating
  "71x decode amplification" was an arithmetic artifact of ours: the doclen
  sidecar is keyed by **all** docids, so a rare term's target sits at an
  arbitrary offset in its block -- instrumented at **60-82 entries decoded per
  block**, which is the unavoidable gap-decode prefix (delta-encoded docids have
  no random access), not waste. Forcing a small decode window made it *worse*
  (rare 5.83 -> 7.74 ms) via tens of thousands of geometric re-walks.
- **Impact-ordered postings / a precomputed block-max score / finer block
  granularity / early termination** -- all previously disproven or rejected; see
  `bench/NOTE_WAND_PRUNING_2026-09-04.md`.

After this release **rare and mid are at their floor**: what remains in
`bm25_doclen_cursor_load_page()` is inherent gap-decoding. Moving them further
would need a format change (periodic absolute docids within a block) worth at most
~2x of a portion of the query.

### Validation

Ranked top-k **parity PASS on all 10 cases** (single-term, AND, OR at k=10 and
k=100) against an exact `fts_bm25` sort, on 2.19M Wikipedia articles at 1421 MB.
installcheck (PG 17/18), full TAP set, alloc/ascii guards and the block fuzzer
(`== ALL CLEAN ==`) all pass. Measured on EC2 r6id.4xlarge, medians of runs 4-8.

## 1.5.9

Correctness fix for non-UTF-8 databases, plus two ranked-latency optimisations.
C-only, no SQL objects, no on-disk index format change (BM25_VERSION stays 4).

### 1. Non-ASCII case folding was broken on non-UTF-8 server encodings

**Who is affected:** databases whose server encoding is NOT UTF-8 (LATIN1,
WIN1252, etc) **and** whose locale is not `C`. UTF-8 databases were never
affected.

`fold_token()` case-folded ASCII but passed every byte >= 0x80 through
**unchanged**, so upper- and lower-case accented letters were different terms and
case-insensitive search silently failed for all non-ASCII text. Measured on
LATIN1 + `de_DE.iso88591`: a document `Apfel` (A-umlaut, 0xC4) did **not** match a
query `apfel` (a-umlaut, 0xE4), while PostgreSQL's own `to_tsvector()` **did**.
We were diverging from PostgreSQL text search on exactly the deployments most
likely to be non-UTF-8.

The non-UTF-8 path now delegates to `str_tolower()` -- the same
locale/collation-aware primitive tsearch's `lowerstr()` uses -- so pg_fts
produces byte-identical terms to `to_tsvector()` on those servers.

Behaviour under locale `C` is deliberately unchanged: the C library has no case
mapping for high bytes there. (PostgreSQL appears to "match" under `C` only
because its parser *discards* the accented character; pg_fts keeps it, which
loses less information.) The contract is now explicit: **non-ASCII folding on a
non-UTF-8 server follows the database locale, exactly as PostgreSQL does.**

**Upgrade action for affected databases:** terms already stored by an older
version are unfolded and will not match the newly-folded query form. Re-derive
them -- `UPDATE t SET d = to_ftsdoc('<cfg>', body)` for a stored `ftsdoc` column,
or `REINDEX INDEX <name>` for an expression index. Until then those rows keep the
old (case-sensitive for non-ASCII) behaviour. Nothing to do on UTF-8.

Also hardened: the UTF-8 folding loop called `utf8_to_unicode()` without checking
that the character's bytes fit within the token. Not reachable today (the
tokenizer never splits a well-formed UTF-8 character and pg_fts imposes no term
length cap), but the bound is now explicit.

New regression coverage in `t/004_encodings.pl` asserts an upper-case accented
document matches a lower-case query on LATIN1 with an ISO-8859-1 locale; it skips
cleanly where no such locale exists. The pre-existing LATIN1 probes only tested
exact-case round-trips, which is why this bug survived.

### 2. Rare-term ranked latency: 1.7x faster (block-granular doclen decode)

The page-directory cursor decoded a **whole sidecar page** (~31 blocks, ~4,000
doc entries) to answer one doclen lookup. A rare term scattered across the docid
space touches nearly every sidecar page, so scoring 10,875 postings cost ~2.2M
doc-decodes -- a ~200x amplification, measured as ~7.9 ms of a 10.2 ms rare-term
ranked query. Now only the **covering 128-doc block** is decoded: the page's block
headers are walked (no FOR-unpack) to locate it, then that one block is unpacked.

rare k10 **10.2 -> 6.05 ms**. Mid is ~flat (a denser term's consecutive postings
already shared a block), common 60.9 -> 56.5 ms.

### 3. Multi-term ranked latency: 1.44-1.63x faster (shared resident block)

Each `(term, segment)` has its own doclen cursor, but the scoring loop asks every
cursor sitting at the pivot docid for its contribution -- i.e. **N cursors look up
the SAME docid**, and each decoded the same sidecar block independently. The
resident decoded block is now hoisted into a per-**segment** slot shared by all of
that scan's cursors, so the 2nd..Nth lookup of a docid is a pure in-memory binary
search.

| query | before | after | change |
|-------|--------|-------|--------|
| 1-term | 6.02 / 10.83 ms | 6.15 / 11.06 ms | flat (one cursor) |
| 2-term OR | 6.17 ms | **4.27 ms** | **1.44x** |
| 3-term OR | 10.95 ms | **6.71 ms** | **1.63x** |

(The originally-planned "LRU of decoded blocks" was dropped: the WAND visits a
cursor's docids monotonically ascending, so a block is never revisited by the same
cursor and an LRU would have nothing to hit. The duplication is across cursors,
which is what this fixes.)

### Rejected by measurement (recorded so it is not retried)

A df-threshold "bulk-load the whole sidecar for small-df terms" fast path was
planned and then **disproven**: measured ranked cost is ~linear in df with no
fixed floor (df 2,560 -> 2.35 ms, already the plain `@@@` count floor), while a
bulk load reads ~547 sidecar pages regardless of df. There is no crossover; the
page directory already wins at every df. Details in
`bench/NOTE_RARE_MID_LATENCY_OPTIONS_2026-09-05.md`.

### Validation

Ranked top-k **parity PASS** on all five query shapes (single-term, AND, OR, at
k=10 and k=100) against an exact `fts_bm25` sort, on 2.19M Wikipedia articles.
Encoding fix verified against real LATIN1/WIN1252/UTF-8 clusters and against
`to_tsvector` on identical bytes. installcheck (PG 17/18), full TAP set (incl.
`t/004_encodings` running for real with an ISO-8859-1 locale, and
`t/006_concurrent_extend`), alloc/ascii guards and the block-fuzzer all pass.

## 1.5.8

Performance + robustness release.  C-only, no SQL change, no on-disk index
format change (BM25_VERSION stays 4), **no REINDEX**.

**1. Doclen-sidecar ranked latency: 2.5x faster rare/mid terms.**  The
`doclen_sidecar=on` default (the ~4.7x smaller index) had a fixed per-scan tax:
1.5.4-1.5.7 decoded the ENTIRE segment sidecar once per ranked scan into a
scan-local array (~18 ms on a 2.19M-doc segment: ~534 page reads plus a
FOR-unpack of every block), which dwarfed the actual scoring for anything but a
very common term.  A fresh 5-way benchmark on real Wikipedia caught it (rare
ranked 25.6 ms vs 1.6 ms with inline doclen).

Replaced with a **page-directory cursor**: one tiny `(first_docid, blk)` entry
per sidecar PAGE, built by walking only page HEADERS (no block decode) and
cached in the index relcache (`rd_amcache`) as ONE contiguous chunk keyed by the
metapage generation -- so it is built at most once per backend, not per scan.  A
lookup binary-searches the directory to the covering page, decodes ONLY that
page, and keeps it resident (the WAND scan visits docids ascending).  Single-chunk
is deliberate: it satisfies the `rd_amcache` "pfree()d wholesale on relcache
invalidation" contract that 1.5.4's multi-chunk 20 MB decoded array violated (the
1.5.5 crash).  The whole-segment bulk decode is retained for the MERGE path,
which legitimately reads every doc sequentially.

Measured on 2.19M Wikipedia articles (median, warm, `doclen_sidecar=on`):
rare 25.6 -> ~10 ms, mid 29.3 -> ~11 ms.  Ranked top-k parity PASSES on all
bands (k=10 and k=100, single-term and AND), and a 90 s concurrent
`fts_merge` + `fts_vacuum` + 6-reader soak kept the ranked top-10 stable with
zero mismatches and zero errors.

Known remaining gap (documented, not a regression): a very common term (735k df,
34% of the corpus) is still ~70 ms, and that is NOT the doclen path -- a plain
`@@@` count of the same term is 2.4 ms while the ranked top-10 reads 8,115
buffers, i.e. the block-max WAND is not pruning it.  That is a separate lever.

**2. `fts_search()` SRF could return fewer than k rows.**  The top-k engine
over-fetches for MVCC (`wantk = k*4`); the `amgettuple` ordering scan retries and
grows on its own, but the `fts_search` SRF called the engine once, so a
heavy-delete workload where most of the top candidates are invisible could yield
`nvis < k`.  `bm25_topk_visible` now grows `wantk` and re-generates when the
visibility loop ends short AND more candidates existed, with a bounded growth cap
(and keeps the directory-generation retry inside each attempt).

**3. Sparsemap error-path leaks.**  `sm_create()` maps are libc-malloc (no
palloc allocator is installed), so an `ereport(ERROR)` between create and
`sm_free` leaked past transaction abort.  `bm25_bulkdelete` and
`bm25_segment_docids` now free them via `PG_TRY`/`PG_FINALLY`.  (The cleanup
pointers are resynced before each throw because `sm_add_many_grow` updates
`*map` even on a partial grow-then-fail -- freeing the pre-call pointer would be
a double free.)  `bm25_read_blob` buffers are palloc'd and are left alone.

**4. Reserved keywords are literal words inside a phrase or NEAR.**  The query
lexer recognized `and`/`or`/`not`/`near` as operators unconditionally, so
`"the and clause"` or `NEAR(near y, 2)` failed to parse.  Keyword tokens now
carry their folded text and the phrase/NEAR operand loops accept them as terms,
matching `to_tsquery` (which lexes them as lexemes).  The ambiguous BARE
top-level form (`and & x`) is deliberately unchanged.

Also: a genuine bug in the vendored sparsemap (an `__sm_insert_data`
offset/length convention mismatch -- a latent buffer over-write currently masked
by compensating capacity slack) was found during this work and reported upstream;
it is not triggered by pg_fts today.

## 1.5.7

Concurrency crash-fix release: three pre-existing races surfaced by a
read+insert+merge+vacuum soak, all present since at least 1.5.3.  C-only, no SQL
change, no on-disk format change (BM25_VERSION stays 4), no REINDEX.

**Who is affected:** any index under concurrent write + maintenance load
(ingestion plus `fts_merge`/`fts_vacuum`/autovacuum).  1.5.3 crashed into
recovery under such a soak; 1.5.7 stays up and error-free.

**1. Merge crash (severe).**  Every operation that mutates the segment directory
or frees + recycles pages -- `bm25_flush_pending`, the tiered
`bm25_merge_segments`, `bm25_vacuum_compact`, bulkdelete's livedocs swap -- ran
with no mutual exclusion: an INSERT's tiered merge holds only RowExclusiveLock, a
user `fts_merge`/`fts_vacuum` holds ShareUpdateExclusiveLock/AccessExclusiveLock
on the INDEX, and autovacuum cleanup holds ShareUpdateExclusiveLock on the TABLE
-- lock tags that do NOT conflict.  Two of these running at once let one free +
recycle a segment's pages while the other's streaming merge was still reading
them -> SIGSEGV in `merge_source_load_page`.  Fix: a per-index maintenance
serialization lock (a heavyweight page lock on the metapage block, the same
mechanism GIN uses to serialize pending-list cleanup) -- blocking for explicit/
required maintenance, conditional (skip if busy) for the opportunistic
insert-time tiered merge.

**2. Index-relkind assert / API misuse.**  The freed-page recycle gate called
`GlobalVisCheckRemovableXid(index, xid)` with the INDEX relation; that routine
expects a table (or NULL) and tripped an assertion under --enable-cassert (and
is latent API misuse otherwise).  Fixed to pass NULL (the global visibility
horizon), a sound and slightly conservative bound.

**3. Scan read past a concurrent truncation.**  `fts_vacuum` (and autovacuum
compaction) truncate the freed tail of the index file back to the OS.  A scan
follows the segment directory it snapshotted (dict/posting chain heads by block
number), re-checking the metapage generation afterward and retrying if it moved
-- but a block number from the pre-truncation snapshot points past EOF, and
`ReadBuffer` raised a hard "could not read blocks N: read only 0 of 8192" ERROR
before the generation re-check could discard the stale result (a transient query
error under heavy read+vacuum churn).  Fix: the scan's chain-following reads now
treat an out-of-range block as end-of-chain (a truncated block can only mean a
concurrent vacuum bumped the generation), so the existing generation guard
restarts the scan from a fresh directory and the count/ranked result stays exact.

**Validation (assert build, on the exact concurrent workload):**
`t/006_concurrent_extend` 45 consecutive runs with zero crashes (1.5.3 crashed
~13/15); a read+insert+merge+`fts_merge`+`fts_vacuum`+`VACUUM` soak across many
runs with zero "could not read blocks" errors, zero crashes, and the
concurrently-churned corpus's fixed-term count staying exact throughout.  The
nix `tap-*` check now runs the full `t/003`-`t/008` set (was only `t/005`) so
this class of crash is caught by `nix flake check` locally.

## 1.5.6

Crash-fix release.  C-only, no SQL change, no on-disk format change
(BM25_VERSION stays 4), no REINDEX.

**Who is affected:** anyone on **1.5.4 or 1.5.5** with the default
`doclen_sidecar=on`.  Upgrade to 1.5.6.  (1.5.3 and earlier lack the doclen
cursor and are unaffected.)

**The bug:** the doclen-sidecar cursor added in 1.5.4 has an `owned` flag that
tells `bm25_doclen_cursor_free` whether the cursor allocated its own decoded
arrays (and must free them) or merely borrowed the scan cache's (and must not).
`bm25_doclen_cursor_init` set `owned` only on the rarely-taken self-decode path
and left it UNINITIALIZED on the common borrow and v3-segment paths.  The
cursor lives in a `palloc`'d (not zeroed) `WandCursor`, so `owned` held stale
heap bytes: when they were non-zero, cursor teardown `pfree()`d a pointer it did
not own -- a borrowed interior/shared pointer -- corrupting the allocator
(`ERROR: could not find block containing chunk ...` on a following multi-term
`fts_search`) or segfaulting a concurrent backend.  Intermittent: it fired only
when the reused chunk's bytes happened to be non-zero, which is why fresh
backends often looked fine but the CI regression + concurrent-extend suites
tripped it.

**The fix:** initialize `owned = false` at the top of `bm25_doclen_cursor_init`
so every path is defined; only the genuine self-decode path sets it true.
Hardening in the same release: the scan-time sidecar decode
(`bm25_doclens_load`) now bounds its page walk to the relation's block count and
stops at any page that is no longer a `BM25_DOCLEN` page, so a chain broken by a
concurrent merge/vacuum recycling its pages (the A1 race, already retried via
the metapage-generation guard) cannot spin or read unrelated pages before the
retry.

**Validation:** clean under AddressSanitizer over the exact multi-term
`fts_search` sequence that regressed (200-iteration loop, plus a
garbage-`owned` poison test); installcheck (PG 17/18), the full TAP set
(t/003-008, including the concurrent-extend crasher), alloc/ascii guards, and
the block-fuzzer all pass.  The nix `tap-*` check now runs the full t/003-008
set (previously only t/005) so this class of crash is caught by
`nix flake check` locally, not only in downstream CI.

## 1.5.5

Concurrency crash-fix release.  C-only, no SQL change, no on-disk format change
(BM25_VERSION stays 4), no REINDEX.

**Who is affected:** anyone running **1.5.4** with the default
`doclen_sidecar=on` under concurrent write + query load.  Upgrade to 1.5.5.
(1.5.3 and earlier do not have the 1.5.4 doclen cache and are unaffected.)

**The bug:** 1.5.4 cached the decoded doclen sidecar in the index relcache entry
(`rd_amcache`).  `rd_amcache` must be a single palloc'd chunk because
PostgreSQL `pfree()`s it wholesale on a relcache invalidation (e.g. one raised
by a concurrent `fts_merge`/segment extend via `RelationReloadIndexInfo`); the
1.5.4 cache was multi-chunk (a header plus per-segment decoded arrays), so the
invalidation freed only the header, corrupting the allocator and/or leaving a
concurrently-scanning backend's cursor pointing at freed memory -- an
intermittent backend crash under the exact ingest+merge+query overlap the
concurrent-extend TAP test drives.

**The fix:** the decoded-sidecar cache is now **scan-local** -- decoded once per
scan into the scan's own memory context and shared across that scan's
per-(term,segment) cursors, freed when the scan ends.  This keeps 1.5.4's
read-locality win (a common term's sidecar is decoded once per scan, then every
doclen lookup is an in-RAM binary search -- no per-posting sidecar page reads)
while being invalidation-safe: nothing is stored in `rd_amcache`, so a
concurrent merge cannot free memory a live cursor borrows.  (Cross-query caching
was dropped; if cold-scan decode ever dominates at scale, a persistent
build-time sidecar directory is the follow-up.)  Verified by running the
concurrent-extend TAP test 20x with no crash (it reproduced ~1-in-10 on 1.5.4).

## 1.5.4

Performance + correctness release making the default `doclen_sidecar=on` (v4)
layout both **fast** and **exact on multi-term AND**.  C-only, no SQL change,
**no on-disk index format change (BM25_VERSION stays 4), no REINDEX**.

**1. Doclen-sidecar read locality (performance).**  Since 1.5.0 the per-doc
length lives in a per-segment sidecar instead of inline in each posting.  That
saves ~35% index size but a ranked scan of a common term (whose postings are
scattered across the whole docid space) then read roughly one sidecar buffer
per scored posting -- effectively the entire sidecar chain per query.  Measured
on a 2.19M-doc corpus: a common term touched **16,887 buffers** with the sidecar
vs **1,432** inline, and warm ranked latency was ~2x inline and far behind
competitors.  1.5.4 decodes a segment's whole sidecar **once per backend** into
a sorted `(docid, byte)` array cached in the index relcache entry (rebuilt only
when the metapage generation moves), then answers every doclen lookup with an
in-RAM binary search -- **0 buffer reads after the first build**.  The common
term now touches ~2,000 buffers (level with inline) and mid-frequency ranked
queries are ~5 ms.  (An ultra-common term -- e.g. one in a third of all docs --
remains dominated by the posting scan itself, the same cost inline pays.)

**2. Block-max WAND multi-term AND recall (correctness).**  A pre-existing
soundness gap in the block-max block-skip: the fast path skipped a whole posting
block whenever a single term's cursor sat at or before the WAND pivot -- but a
cursor being past the *pivot* does not mean it is past the *block*, so a later
document in the skipped block that contained BOTH query terms (and thus scored
the SUM of their contributions, which the one-term block bound never covered)
could be dropped from the top-k.  On a 2.19M Wikipedia corpus the ranked top-10
for `slovakia & hungary` missed the true #1 and admitted lower-scoring docs.
The fix only takes the whole-block-skip fast path when no other term's cursor
falls within the skipped block's docid range; otherwise it advances past the
pivot exactly.  This was present on BOTH the sidecar and inline layouts (it is
in the shared WAND traversal), and single-term ranked was always exact.

**3. Sidecar block-max bound vs quantized doclen (correctness).**  The v4 sidecar
stores a quantized length byte (SmallFloat, rounded DOWN), so scoring can see a
slightly shorter |D| -- and thus a slightly higher score -- than the exact
minimum |D| the block header records.  The block-max WAND bound now dequantizes
the block's min |D| through the same codec, so the bound stays a true upper
bound for the quantized scores and cannot wrongly prune a top-k document.

**Validation:** ranked top-k now matches the exact `fts_bm25` top-k for AND
queries on both layouts (new regression test `and_sidecar_topk_exact` /
`and_inline_topk_exact`), verified at 2.19M docs on the exact
`slovakia & hungary` case that first exhibited the gap; a concurrent soak
(readers + writer + merge/vacuum loop) on a sidecar-on index stayed correct and
bounded; installcheck (PG 17/18), TAP, alloc/ascii guards, and the block-fuzzer
all pass.

## 1.5.3

Correctness + performance bug-fix release: **the segment MERGE path produced a
broken v4 doclen sidecar** (empty), so a merged v4 segment's ranked scores were
wrong and its ranked scan was pathologically slow.  C-only, no SQL change.

**Who is affected:** any index built with the default `doclen_sidecar=on` (v4)
under 1.5.0-1.5.2 that has undergone a segment merge or `fts_vacuum`/`fts_merge`
compaction -- i.e. essentially every non-trivial actively-used v4 index.  A
freshly-built, never-merged single-segment v4 index was correct; the corruption
was introduced by merge.  Indexes built with `doclen_sidecar=off` (inline) were
never affected.

**The bug:** the streaming merge wrote merged postings in the 2-column (no
inline doclen) layout but never populated the merged segment's doclen collector,
so `bm25_write_doclen_sidecar` returned `InvalidBlockNumber` for the merged
segment.  A segment with 2-column postings but `doclenstart = Invalid` is then
read as if doclen were inline -- so scoring read a garbage "doclen" from past the
tf column.  Wrong doclen corrupts the BM25 length-normalization (wrong ranking)
and defeats block-max WAND pruning (the ranked scan scores far more of the
posting list than the top-k needs -- the multi-second `Index Searches: 0` scans
reported from the field).

**The fix:** the merge now feeds each surviving posting's `(docid, doclen)` into
the merged segment's doclen collector, so the merged segment gets a correct,
populated sidecar and a valid `doclenstart`.  A regression test builds several
segments, forces a merge, and asserts the merged sidecar index returns the same
ranked top-k as an inline-built twin.

**Action for operators on 1.5.0-1.5.2 with a default (v4) index:** REINDEX, or
rebuild under `doclen_sidecar=off`, to correct any already-merged segment's
doclen.  New merges under 1.5.3 are correct.  (If you were already on
`doclen_sidecar=off` per the 1.5.2 note, you are unaffected and need do nothing.)

## 1.5.2

Bug-fix release: the native-v4 ranked-scan slowdown on large, many-segment
indexes (a field-reported 1.5.x adoption blocker), plus an escape hatch.  C-only,
no REINDEX (`ALTER EXTENSION pg_fts UPDATE TO '1.5.2'`).

- **Doclen sidecar lookup is now random-access, not a forward walk.**  The v4
  scoring path reads each scored doc's quantized length from the per-segment
  sidecar.  1.5.1 read it through a forward cursor, which is O(1) amortized only
  when scored docids are dense; on an index with a long merge/delete history the
  surviving docids are sparse, so a term whose postings sit at high/scattered
  docids forced the cursor to decode the whole sidecar up to that docid -- a
  ranked top-k that touched tens of thousands of buffers (even for a rare term).
  The cursor now builds a small per-segment page directory (first-docid per
  sidecar page, one buffer/page, no block decode) once and BINARY-SEARCHES it to
  jump straight to the covering page, so a lookup is O(log pages) and total
  sidecar reads are bounded by the pages actually covering scored docids.
- **New `WITH (doclen_sidecar = on|off)` reloption (escape hatch).**  Default
  `on` (the v4 quantized sidecar).  `off` stores doclen inline in each posting
  (the pre-1.5 layout) -- the same ranked-scan behavior as 1.4.x -- for a
  workload that prefers it while keeping the 1.5.x crash fixes.  Both layouts are
  read by the same self-describing decoder, so an index can mix sidecar and
  inline segments and the option can be changed without REINDEX (new segments
  follow the current setting).
- **Note.**  Block-max WAND still does not early-terminate a very-high-df term
  whose per-block score bounds cluster near the top-k threshold; that is
  pre-existing (1.4.x) and unchanged.  This release fixes the v4-SPECIFIC cost
  (the sidecar walk) that made a many-segment v4 index slower than the same
  query on v3.

## 1.5.1

Bug-fix release: three field-reported regressions in the 1.5.0 v3->v4 doclen
sidecar upgrade (one caused a production search outage).  C-only, no SQL change,
no REINDEX (`ALTER EXTENSION pg_fts UPDATE TO '1.5.1'`).  **A 1.5.0 index --
whether an upgraded-in-place v3 or a native v4 -- is read correctly by 1.5.1
with no REINDEX.**

- **Fixed corrupt dual-read of a pre-existing v3 index (the outage).**  1.5.0
  added `doclenstart` INSIDE `BM25SegMeta`, which grew that struct (48->56
  bytes).  Because segment descriptors are stored inline in the metapage's
  `segs[]` array, a v3 metapage laid them out at the old 48-byte stride; the
  1.5.0 reader cast the page straight to the larger v4 struct and read every
  `segs[1..]` field (and `generation`) from the wrong offset -> a garbage
  `livedocslen` became `palloc(4294967295)` and a garbage `dictstart` became an
  out-of-range block seek.  The metapage read is now VERSION-AWARE: a v3
  metapage is deserialized at the v3 stride into the in-memory v4 struct
  (`doclenstart` = Invalid, i.e. inline doclen), and a v3 metapage is upcast to
  v4 in place on the first metapage mutation.  A compile-time assert now pins
  the v3/v4 head-layout contract so a future field insertion cannot silently
  reintroduce this.
- **Fixed the v4 ranked-scan slowdown on many-segment indexes.**  The
  per-segment doclen sidecar was BULK-LOADED (whole segment) at scan start, so a
  ranked/@@@ scan was O(segment docs) per query regardless of matches -- on an
  index with a long merge history (many segments) this read tens of thousands of
  buffers for a small top-k.  Scoring now reads the sidecar through a FORWARD
  CURSOR that touches only the pages covering the docids actually scored
  (bounded by the WAND's ascending docid walk), matching the posting scan's own
  block-skip.
- **Note on high-df ranked latency.**  Block-max WAND does not early-terminate a
  high-frequency term whose per-block score bounds cluster near the top-k
  threshold; this is a pre-existing property of the docid-ordered index (present
  in 1.4.x, not introduced by v4 -- measured v4 is faster than v3 on the same
  high-df term).  It is unchanged here; a future impact-ordered format is the
  only lever and is not in this release.

## 1.5.0

Storage + performance release: per-document length moves out of the posting
lists into a per-segment quantized sidecar (on-disk format v3 -> v4).  C-only,
**no REINDEX** (`ALTER EXTENSION pg_fts UPDATE TO '1.5.0'`).

- **Doclen sidecar (the size + common-term-latency win).**  BM25 needs each
  document's length for its length-normalization, but pg_fts stored it once per
  *posting* (once per doc x term) -- the widest posting column.  1.5.0 stores it
  once per *document* as a single quantized byte (a Lucene/Tantivy-style
  fieldnorm: 5-bit exponent + 3-bit mantissa) on a per-segment sidecar page
  chain, and scoring reads that byte instead of decoding a per-posting column.
  Measured on 2M high-vocabulary docs:
    - index **37.5% smaller** (954 MB -> 596 MB);
    - common-term ranked top-10 **7.7x faster** (17.5 ms -> 2.3 ms), top-100
      **5.6x faster** (18.4 ms -> 3.3 ms), because each posting block is ~56%
      smaller and length-normalization is now a byte lookup;
    - rare/mid ranked, boolean AND, phrase, prefix, and count(*) unchanged.
  `avgdl` stays EXACT (from the per-segment sumdoclen/ndocs); only the per-doc
  normalization denominator is quantized, which changes BM25 score ORDERING by
  at most a fraction of a percent at tie boundaries (the accepted fieldnorm
  tradeoff; verified <= 0.2% on the 2M rig).
- **No REINDEX; dual-read + lazy migration.**  A v4 build reads existing v3
  segments (inline doclen) and new v4 segments (sidecar) in the same index; the
  block's column count is self-describing from its byte length, so decode is
  correct across mixed-version segments.  Segments migrate to v4 as merge/vacuum
  rewrites them -- an existing index keeps working untouched and converges to the
  smaller format over time with no operator action.

## 1.4.1

Bug-fix release: two field-reported robustness fixes on high-vocabulary corpora
under heavy churn.  C-only, no index format change, no REINDEX
(`ALTER EXTENSION pg_fts UPDATE TO '1.4.1'`).

- **Ranked scan no longer degrades under tombstone bloat.**  A ranked
  (`ORDER BY d <=> query`) scan checks each candidate docid against the
  segment's deleted-doc (tombstone) map.  That check used an 8-way MRU chunk
  cache which degenerates to an O(chunks) head-walk per lookup once an
  ascending scan runs past its eight cached chunks -- so a segment carrying
  millions of tombstones (e.g. after a full-table `UPDATE` + `VACUUM`) turned a
  common-term top-k from ~30 ms into tens of *seconds* (measured 24 s for a
  735k-df term at 2.2M docs; ~99.9% of the time was in the sparsemap walk).
  The tombstone check now uses a forward-resume cursor (`sm_cursor_t`) that
  resumes the walk from the last located chunk, restoring O(postings + chunks).
  Validated at 2M docs with ~4M tombstones: 24 s -> 2.5 ms.

- **Fuzzy/regex/NOT candidate scan is memory-bounded.**  When no trigram
  acceleration is available (`trigrams = off`, the default, or a pattern too
  short to yield trigrams), fuzzy/regex/NOT queries fall back to a whole-segment
  candidate scan.  That fallback accumulated every posting (Sum of df across the
  dictionary -- the whole expanded inverted index) before de-duplicating, so on
  a high-vocabulary corpus it could attempt a multi-gigabyte allocation and fail
  with "invalid memory alloc request size".  It now folds duplicates as it
  collects, keeping peak memory O(ndocs) regardless of Sum(df).  Results are
  unchanged (the fallback still returns the exact set).

## 1.4.0

Feature release: field-targeted (weight-zone) search.  **No index format change,
no REINDEX** (`ALTER EXTENSION pg_fts UPDATE TO '1.4.0'`).

- **Field zones via tsvector-style weight labels A/B/C/D.**  Tag a sub-document
  with a weight and concatenate labelled parts so a query term can restrict
  itself to a field:

      CREATE INDEX ... USING fts ((
        to_ftsdoc('english', subject, 'A') ||
        to_ftsdoc('english', body,    'C'))) WITH (positions = on);
      ... WHERE d @@@ to_ftsquery('english', 'vacuum:A & tgl:B')

  New: `to_ftsdoc(regconfig, text, "char")`, `setftsweight(ftsdoc, "char")`,
  the `ftsdoc || ftsdoc` concatenation operator, and the query syntax
  `term:A` / `term:AB` (a term restricted to one or more zones), mirroring
  standard `to_tsquery('english','term:A')`.  `to_ftsdoc(tsvector)` now also
  carries the tsvector's own A/B/C/D weights.
- **Upgrade is a no-op for existing indexes.**  Weight labels live only in the
  ftsdoc VALUE (the top 2 bits of each token position); the on-disk index
  posting format is unchanged.  A field-restricted query is answered via the
  heap recheck (like fuzzy/regex), so existing indexes keep working and queries
  without a `:label` behave exactly as before.  To get field provenance, rebuild
  a table's ftsdoc from labelled `to_ftsdoc(...,weight) || ...` documents
  (opt-in per table -- NOT a global reindex).  An unlabelled document reads as
  label D, so `term:D` matches it and `term:A` does not.
- Field restriction requires the ftsdoc to carry positions (the labels ride on
  positions); build the index `WITH (positions = on)` for field-restricted
  ranked/count queries.  BM25 scoring stays document-level -- a zone filter
  changes which documents match, not how a matching document scores.
- Limitation: weight labels apply to plain terms; `term:A*` / `term:A~k` (weight
  + prefix/fuzzy/regex) are rejected as a syntax error.

## 1.3.2

Performance bug-fix release. **No on-disk format change** from 1.3.1; no
**REINDEX** required (`ALTER EXTENSION pg_fts UPDATE TO '1.3.2'`).

- **Fixed a ~5x common-term ranked-latency regression introduced in 1.3.0.**
  The 1.3.0 ranked-exactness hardening replaced the block-max WAND scan's O(1)
  per-block skip with a per-posting re-pivot on every prune, which on a common
  term turned each block-max prune into ~128 re-pivots (measured on 2.19M
  Wikipedia, PostgreSQL 18: `year` top-10 rose 31.8ms -> 163ms; the slowdown
  scaled with document frequency -- mid-frequency terms ~2.6x, rare terms
  unaffected). The exactness bug that hardening guarded against is latent (not
  reachable in practice -- segments own contiguous, non-overlapping docid
  ranges), so the trade was a real regression for defense against an unreachable
  bug. The fix restores the O(1) block-skip in the common single-segment /
  few-term case while keeping the safe per-posting seek for the densely-
  interleaved multi-segment case, so ranked exactness is fully preserved. After
  the fix, common-term ranked latency is competitive with the fastest
  block-max-WAND BM25 extensions again (`year` top-10 ~28ms, top-100 ~29ms), and
  rare/mid terms lead. Anyone on 1.3.0 or 1.3.1 doing ranked (`<=>`) searches on
  common terms should upgrade.

## 1.3.1

Correctness bug-fix release. **No on-disk format change** from 1.3.0; no
**REINDEX** required (`ALTER EXTENSION pg_fts UPDATE TO '1.3.1'`).

- **Stopwords are now dropped from the query, not just the document.**
  `to_ftsdoc(regconfig, text)` removes a configuration's stopwords (e.g. `the`,
  `a`, `of`), but `to_ftsquery(regconfig, text)` previously kept them verbatim,
  so a stopword query term was unsatisfiable and silently zeroed a boolean AND
  (`the & postgres` matched nothing; `the vacuum problem` under implicit-AND
  returned far fewer results than `vacuum problem`). `to_ftsquery` now runs each
  term through the same dictionary pipeline and elides stopword terms from the
  query tree -- matching standard `to_tsquery`: `to_ftsquery('english','the &
  postgres')` reduces to `postgres`, and an all-stopword query becomes empty
  (matches nothing). Prefix/fuzzy/regex terms are matched literally and are
  never stopword-dropped. Reported against a 2.8M-document English email-body
  index in production.
- Known limitation (tracked, not fixed here): `and`/`or`/`not`/`near` are
  reserved query operators and cannot be searched for as literal words; on
  natural-language corpora they are stopwords and dropped anyway.

## 1.3.0

Feature + hardening release. **No on-disk format change** from 1.2.2; no
**REINDEX** required (`ALTER EXTENSION pg_fts UPDATE TO '1.3.0'`).

- **`WITH (trigrams = on|off)` reloption (default OFF).** The per-segment
  trigram tier accelerates only regex and long fuzzy queries; the query side
  already falls back to a full dictionary scan when it is absent, so the default
  now omits it -- a smaller index (~18% in a 2.19M-doc measurement) at no
  correctness cost. Build `WITH (trigrams = on)` for regex- or long-fuzzy-heavy
  workloads. Results are identical either way.
- **Faster `count(*)`.** A single plain term over a tombstone-free, pending-
  free, fully-all-visible index is now counted straight from the dictionary
  document frequency -- no posting decode, no heap probe (measured: a common
  term at 2.19M docs, ~756 ms -> ~2 ms). Set-membership decodes skip the tf/
  doclen columns they never use. The `count(*)` index pushdown now also fires
  for a plain-column `fts` index (the recommended stored-`ftsdoc`-column form),
  not only an expression index -- previously a stored-column `count(*)` fell
  back to a bitmap heap scan.
- **Managed-service hardening.** `fts_merge()` and `fts_vacuum()` now refuse to
  run during recovery (a hot standby is read-only) and require the caller to own
  the target index (they open it by OID and take heavy locks). Two functions
  that emit indexed content by index OID -- `fts_search()` and
  `fts_anomalous_docs()` -- are revoked from `PUBLIC` (the index owner and
  superusers keep access; an owner may grant explicitly). Corpus statistics
  (BM25 IDF + length normalization) now exclude recently-dead tuples surfaced to
  the build with `tupleIsAlive = false` -- such tuples are still indexed (an old
  snapshot may need them) but no longer inflate the document count / total
  length.
- **Ranked-exactness hardening (internal).** The block-max WAND pivot skip now
  advances every cursor at or before the pivot rather than skipping one cursor's
  whole block, removing a provably-unsound (though not field-reachable) over-
  skip. No behavior change on pg_fts's contiguous-docid-range segments.

## 1.2.2

Bug-fix release. **No on-disk format change** from 1.2.1; no **REINDEX**
required (`ALTER EXTENSION pg_fts UPDATE TO '1.2.2'`). Two `fts_vacuum` fixes.

- **Fixed `fts_vacuum()` growing the index instead of shrinking it.** The 1.2.1
  deletion-XID recycle gate (which protects a concurrent scan from reading a
  just-freed page) also blocked `fts_vacuum()`'s compaction from repacking into
  the low pages it had itself just freed, so the vacate+pack phase extended the
  relation and `fts_vacuum()` GREW the index on every call and never truncated a
  tail. Compaction now reuses freed pages again and `fts_vacuum()` compacts to a
  stable floor (measured: a churned index 143 MB -> 60 MB, idempotent). If you
  ran `fts_vacuum()` on 1.2.1 and it did not shrink, re-run it on 1.2.2.
- **Fixed a rare crash from `fts_vacuum()` (or autovacuum) concurrent with
  reads.** `fts_vacuum()` ran under a lock that does not block scans, so a
  reader could still be copying a segment's pages while compaction recycled and
  overwrote them, corrupting the read (a rare SIGSEGV under heavy simultaneous
  read + insert + merge + vacuum). Page recycling during compaction is now
  bypassed only under an exclusive lock, and `fts_vacuum()` takes
  `AccessExclusiveLock` on the index (like `REINDEX`) so its in-place shrink is
  safe; autovacuum's cleanup keeps the gate and reclaims space across passes
  without blocking or corrupting concurrent scans. (Root-caused with
  AddressSanitizer; a concurrent read+vacuum regression test now gates CI.)

## 1.2.1

Bug-fix release. **No on-disk format change** from 1.2.0; no **REINDEX**
required (`ALTER EXTENSION pg_fts UPDATE TO '1.2.1'`). Fixes three production
failures on a continuously-written index and hardens the scan-vs-merge path.

- **Fixed the 128-segment cap becoming an unrecoverable outage.** On an index
  whose rows mostly exceed one page, every insert creates a segment; the live
  count could reach the internal 128-segment maximum and then reject all further
  writes -- and neither `VACUUM` nor `fts_merge()` could recover (merging needs a
  free slot to flush pending into, a chicken-and-egg deadlock; only `REINDEX`
  escaped). Adding a segment now merges to free a slot and retries instead of
  erroring, so a write is never refused because compaction fell behind. In
  addition, the index now compacts continuously on the write path (leveled LSM
  merge after each segment-creating flush), keeping the segment count bounded
  (O(log N) tiers) automatically -- no periodic `VACUUM`/`fts_merge()` needed to
  stay healthy under continuous ingestion.
- **Fixed `ERROR: unexpected data beyond EOF` when `fts_merge()`/`VACUUM` ran
  concurrently with ingestion.** Relation extension was only locked during a
  parallel build, so two ordinary backends extending the index at once (an
  insert flush and a merge/vacuum) could race. The extension is now always
  locked around the single page add, as heap and the core index AMs do;
  concurrent writers still proceed in parallel. `fts_merge()` is now safe to run
  while writes continue.
- **Fixed a crash / wrong count from `count(*)` on an `@@@` query under plan
  caching or concurrency.** The count-pushdown plan stored the query as a bare
  internal pointer, which dangled once its planning memory was freed (e.g. a
  `count(*)` in a PL/pgSQL loop, or concurrent re-execution), corrupting the
  query and crashing the backend. The query is now deep-copied into the plan.
- **Hardened concurrent scan vs. merge/vacuum** with a deletion-XID page-recycle
  gate (a freed page is not reused until no in-progress scan could still
  reference it) plus bounds checks on all page-derived lengths, so a scan that
  races page recycling degrades to a retry rather than a crash. Format-
  preserving (no `REINDEX`).

## 1.2.0

Minor release, re-numbered from the 1.1.6 and 1.1.7 patch releases. It contains
exactly the 1.1.6 + 1.1.7 changes below.

**Reindex recommended.** 1.1.6 changed ranked-scan (`ORDER BY <=>`) *results*.
Because the query behavior over an index changes, we group this as a minor
release (not a patch) and recommend rebuilding every `fts` index after
upgrading so ranked results are consistent for anyone who observed the old
truncated output. (There is no on-disk format change in 1.1.6/1.1.7/1.2.0 --
the read-path fix is correct against an existing index without a rebuild -- but
the re-numbering exists precisely so this class of behavior change is never
shipped as a silent patch again.) If you already upgraded to 1.1.6 or 1.1.7,
upgrade to 1.2.0 (`ALTER EXTENSION pg_fts UPDATE TO '1.2.0'`).

Upgrade steps:

```
ALTER EXTENSION pg_fts UPDATE TO '1.2.0';
REINDEX INDEX CONCURRENTLY your_fts_index;   -- recommended; repeat per fts index
```

- **Fixed `ORDER BY doc <=> query` (ranked) index scans silently returning
  fewer rows than match.** A ranked query retrieved through the KNN/ordered
  index scan capped at ~4096 rows regardless of how many documents actually
  matched (e.g. 6057 or 19347 matches both returned ~4096), independent of
  `LIMIT` -- so ranked search dropped and mis-ordered results. The ordered scan
  had an internal top-k ceiling meant to bound worst-case latency, but a KNN
  index scan must return every matching row in score order (the query's `LIMIT`
  is the only bound). The ceiling is removed: the scan now returns the complete
  match set in order. A small `LIMIT` (a page of results) is still served
  cheaply. The plain `@@@` match path was always complete and is unaffected.
- **Build progress logging.** A build over a large corpus of long documents
  (full email bodies, source code) is dominated by per-document text analysis
  (tokenize + stem). A serial build (`max_parallel_maintenance_workers = 0`) on
  a multi-gigabyte corpus can legitimately run for many minutes before the first
  segment is flushed -- the in-memory buffer fills only after a whole budget's
  worth of large documents, during which the segment count does not change and
  nothing is written yet, which is hard to tell apart from a hang. The build now
  emits a `LOG`-level line as documents are analyzed and at each segment flush
  (set `log_min_messages = log` to see them), so a long build is distinguishable
  from a stuck one. Verified end to end on a 1.97M-document / 54 GB-of-text
  high-vocabulary corpus: a serial `english`-configuration build completes,
  collapses to a single segment, and is valid and queryable; the wall-clock cost
  is the inherent analysis cost, which parallel workers reduce proportionally.
- Documentation: expanded the large-build guidance with a build-time/throughput
  section (analysis is the dominant cost and is embarrassingly parallel; how to
  read the new progress logs).

## 1.1.7

Bug-fix / observability release. Superseded by 1.2.0 (which relabels 1.1.6+1.1.7
as a minor release and documents the REINDEX requirement). **No on-disk format
change** from 1.1.6.

- **Build progress logging.** A build over a large corpus of long documents
  (full email bodies, source code) is dominated by per-document text analysis
  (tokenize + stem). A serial build (`max_parallel_maintenance_workers = 0`) on
  a multi-gigabyte corpus can legitimately run for many minutes before the first
  segment is flushed -- the in-memory buffer fills only after a whole budget's
  worth of large documents, during which the segment count does not change and
  nothing is written yet, which is hard to tell apart from a hang. The build now
  emits a `LOG`-level line as documents are analyzed and at each segment flush
  (set `log_min_messages = log` to see them), so a long build is distinguishable
  from a stuck one. Verified end to end on a 1.97M-document / 54 GB-of-text
  high-vocabulary corpus: a serial `english`-configuration build completes,
  collapses to a single segment, and is valid and queryable; the wall-clock cost
  is the inherent analysis cost, which parallel workers reduce proportionally.
- Documentation: expanded the large-build guidance with a build-time/throughput
  section (analysis is the dominant cost and is embarrassingly parallel; how to
  read the new progress logs).

## 1.1.6

Bug-fix release. **No on-disk format change** from 1.1.5; no **REINDEX**
required (`ALTER EXTENSION pg_fts UPDATE TO '1.1.6'`).

- **Fixed `ORDER BY doc <=> query` (ranked) index scans silently returning
  fewer rows than match.** A ranked query retrieved through the KNN/ordered
  index scan capped at ~4096 rows regardless of how many documents actually
  matched (e.g. 6057 or 19347 matches both returned ~4096), independent of
  `LIMIT` -- so ranked search dropped and mis-ordered results. The ordered scan
  had an internal top-k ceiling meant to bound worst-case latency, but a KNN
  index scan must return every matching row in score order (the query's `LIMIT`
  is the only bound). The ceiling is removed: the scan now returns the complete
  match set in order. A small `LIMIT` (a page of results) is still served
  cheaply; only an explicit large/unbounded ranked scan does the deeper work.
  The plain `@@@` match path was always complete and is unaffected.

## 1.1.5

Bug-fix and usability release. **No on-disk format change** from 1.1.4; no
**REINDEX** required (`ALTER EXTENSION pg_fts UPDATE TO '1.1.5'`).

- **Fixed a very slow `CREATE INDEX CONCURRENTLY` finalization on a large,
  high-vocabulary index.** After the merge converged, the CONCURRENTLY
  validation phase could run for a very long time at 100% CPU without
  completing. It built a per-segment live-document set one dictionary term at a
  time, which was quadratic on a segment with millions of low-frequency terms.
  It now builds that set in one linear pass. On a ~1.9M-document body corpus the
  validation phase drops from over an hour (not completing) to a few minutes.
- **New GUC `pg_fts.build_mem_ceiling_mb`** (default `0` = previous behavior):
  the per-participant flush-budget ceiling, in MB. Raising it lets a large build
  flush fewer, larger segments so the segment count stays well under the
  internal limit -- useful when you have spare RAM and want less post-scan
  merging. Peak build memory is about
  `shared_buffers + (max_parallel_maintenance_workers + 1) * pg_fts.build_mem_ceiling_mb`.

## 1.1.4

Bug-fix release. **No on-disk format change** from 1.1.3; no **REINDEX**
required (`ALTER EXTENSION pg_fts UPDATE TO '1.1.4'`).

- **Fixed segment merges that could fail to converge, or crash, on a large,
  high-vocabulary index.** Two issues in the merge path, both exposed only at
  scale (validated on a ~1.9M-doc / 40GB+ index):
  - A merge discarded its finished output and retried if the segment directory
    changed at all while it ran (for example a concurrent flush appending a
    segment). On a big index each merge takes minutes, so it could read a great
    deal and never commit -- the reported "reads hundreds of GB, segment count
    never drops" non-convergence. A merge now re-locates its inputs by content
    and commits alongside concurrent flushes.
  - A committed merge freed its input pages, which the next merge could recycle
    for its output while still reading the previous chain -- leading to a rare
    crash (SIGBUS) on very large merges. Merges now write to freshly extended
    pages during the merge loop and reclaim the freed space afterward.
  These are memory/scale-path fixes only; the on-disk format is unchanged.

## 1.1.3

Bug-fix release. **No on-disk format change** from 1.1.2; no **REINDEX**
required (`ALTER EXTENSION pg_fts UPDATE TO '1.1.3'`).

- **Fixed non-converging merges on a large, high-vocabulary index.** On a
  multi-tens-of-GB index with many similarly-sized segments (e.g. a ~1.9M-doc /
  ~45GB email-body corpus), `fts_merge` and the build's compaction could run for
  hours without finishing: the segment merge was size-tiered with *unbounded
  fan-in*, so it tried to merge essentially all segments into one in a single
  pass over the whole index. The merge is now **leveled (LSM/HanoiDB-style) with
  bounded fan-in**: a segment's level is derived from its size and no single
  merge combines more than a bounded number of segments, so compaction proceeds
  in small, discrete, observable steps (each merge logs `merging N of M
  segments` at `DEBUG1`) with bounded write amplification and always converges.
  Validated on a 1.9M-doc / 26GB corpus: build to a bounded tiered set in ~17
  minutes; `fts_merge` collapse to a single segment in ~8 minutes; previously it
  did not complete. The segment level is computed from size, not stored, so the
  on-disk format is unchanged and no REINDEX is needed.

## 1.1.2

Bug-fix release. **No on-disk format change** from 1.1.1; no **REINDEX**
required (`ALTER EXTENSION pg_fts UPDATE TO '1.1.2'`).

- **Fixed a hang in the final phase of a large `CREATE INDEX CONCURRENTLY`.**
  On a large, high-vocabulary corpus, a build could get all the way through the
  merge (the 1.1.1 fix) and then wedge in finalization -- the build leader
  parked waiting on parallel workers while another backend blocked on the
  relation-extension lock, with the index never becoming valid. The build
  finalization started a second parallel worker set to merge the segments; on a
  large index under `CONCURRENTLY` on a busy host, the participants could
  contend on the relation-extension lock and stall indefinitely. Finalization is
  now serial (the 1.1.1 O(N) merge made the parallel pass unnecessary for
  convergence), so no relation-extension contention arises and the build
  completes. `fts_merge()` still merges in parallel when run on its own.

## 1.1.1

Bug-fix release. **No on-disk format change** from 1.1.0; no **REINDEX**
required (`ALTER EXTENSION pg_fts UPDATE TO '1.1.1'`).

- **Fixed quadratic (O(N^2)) time in `VACUUM` / bulk-delete on a large index.**
  1.1.0 fixed the same pattern in the build's trigram writer; three more
  instances remained on the delete/vacuum path (building a segment's live-docid
  set and the tombstone sets one member at a time re-walked the sparsemap from
  the start on every insert).  Harmless on a small index, but on a large index
  a `VACUUM` or a large `DELETE` could spend a very long time in tombstone
  construction &mdash; the same "time explodes at scale" behavior the build had.
  All corpus-scale sparsemap builds now use the bulk O(N) path.  Tombstone
  results are unchanged (verified against a delete + `VACUUM` cycle).
- **Docs:** added a build time model and serial/low-parallelism recommendation
  (the final single-segment collapse is a single-backend pass over the whole
  index, so budget it in a maintenance window or leave the index tiered), and
  noted that `fts_index_stats()` (like `fts_index_nsegments()`) can be polled on
  an in-progress index.

## 1.1.0

Build-convergence and operability release.  **No on-disk format change** from
1.0.8; no **REINDEX** required (`ALTER EXTENSION pg_fts UPDATE TO '1.1.0'`).

- **Fixed a non-converging index build on large, high-vocabulary corpora.**
  Building an index over many long, high-vocabulary documents (full email
  bodies, source code, patches -- many distinct low-frequency terms per doc)
  could enter a merge phase that ran for hours with no forward progress and
  never completed, even though memory stayed bounded.  The cause was a
  quadratic (O(N^2)) construction of each trigram's term-set during the merge;
  it is now built with a bulk O(N) path.  A build that previously did not finish
  in 8.5 hours completes in minutes.
- **Large builds now always converge, in bounded steps.**  Instead of always
  collapsing to a single segment at the end of a build (a single-backend pass
  over the whole index), a build whose total size exceeds the new
  `pg_fts.build_collapse_max_mb` GUC (default 4096 MB) stops at a bounded,
  size-tiered set of segments.  The index is valid and fully queryable; ranked
  scans traverse a bounded handful of segments (a small fixed cost).  Run
  `fts_merge(index)` to collapse to a single optimal segment in a maintenance
  window.  Set the GUC to 0 to always collapse (the historical behavior), or
  raise it to collapse larger indexes during the build.
- **Build monitoring.**  Per-merge progress is logged at `DEBUG1` (segments in,
  terms/docs written, elapsed), and a `LOG` line reports when a build stops at a
  tiered set.  `fts_index_nsegments()` now works on an in-progress
  (`indisvalid = f`) index, so a build can be polled to watch its segment count
  fall as merges complete.
- **Docs:** a new "Building indexes on large or high-vocabulary corpora" section
  covers the build-memory formula (including `shared_buffers`), the collapse
  GUC, monitoring, and partitioning.

## 1.0.8

Bug-fix release. **No on-disk format change** from 1.0.7; no **REINDEX**
required (`ALTER EXTENSION pg_fts UPDATE TO '1.0.8'`).

- **Fixed out-of-memory / worker SIGKILL during a large index build's merge
  phase.** The 1.0.6 flush-budget ceiling bounds the scan phase, but the merge
  phase held two vocabulary-proportional working sets that no setting bounded:
  it loaded every input segment's entire dictionary into memory (and the final
  reduction opens all segments at once), and it accumulated the whole merged
  vocabulary before writing the dictionary. On a large, high-vocabulary corpus
  (tens of millions of distinct terms) each could reach multiple gigabytes
  regardless of `maintenance_work_mem`, so a big build could exhaust host memory
  in the merge phase even at a configuration whose scan phase fit comfortably.
  The merge now reads each input dictionary a page at a time and spills the
  output dictionary metadata to a temporary file, so its memory no longer scales
  with the corpus vocabulary. Measured peak build memory roughly halved on a
  high-vocabulary corpus, with a much flatter growth curve; build time did not
  regress. (Memory-only change: on-disk format is byte-identical, no REINDEX.)

## 1.0.7

Bug-fix and usability release. **No on-disk format change** from 1.0.6; no
**REINDEX** required (`ALTER EXTENSION pg_fts UPDATE TO '1.0.7'`).

- **Fixed a concurrent scan-vs-merge stale read** (the A1 hazard). A scan
  snapshotted the segment directory, released the metapage lock, then walked
  segment pages holding only per-page share locks; a concurrent `fts_merge` /
  `fts_vacuum` / autovacuum could free those pages and a concurrent insert
  recycle them, so the scan followed a now-stale segment descriptor and returned
  a wrong (too-low) match count or ranking. The metapage now carries a
  `generation` counter bumped on every segment-directory change (segment
  add/merge/free and the bulkdelete livedocs-pointer swap); a scan records it at
  its snapshot and re-checks it before trusting the result, restarting from a
  fresh snapshot if it moved. The counter lives after the segment array, so
  existing indexes are unaffected -- no format change, no REINDEX. Reproduced
  and verified deterministically (`test/a1_recycle/`).
- **`to_ftsdoc(tsvector)`**: build an `ftsdoc` directly from an existing
  `tsvector` (lexemes and positions mapped straight across, no re-analysis).
  Lets you index a stored `tsvector` column, or migrate a `to_tsvector`
  workload, without re-parsing text. Positions are preserved only when every
  lexeme has them (a stripped tsvector indexes positionless).
- **Long-running scans, `CREATE INDEX CONCURRENTLY` validation, and
  `fts_count` are now promptly cancellable.** Added interrupt checks at
  lock-free points in the scan and trigram-scan page walks, so a query stuck on
  a large or pathological index responds to statement timeout / Ctrl-C instead
  of spinning to completion.

## 1.0.6

Bug-fix release. **No on-disk format change** from 1.0.5; no **REINDEX**
required (`ALTER EXTENSION pg_fts UPDATE TO '1.0.6'`).

- **Fixed runaway memory during a long index build over a large corpus**
  (the phase after the 1.0.5 fix). The per-participant build memory budget grew
  geometrically with no ceiling, so a large build's in-memory working set could
  climb to tens of gigabytes before flushing; combined with one budget per build
  participant (the leader plus each parallel worker), a big parallel build could
  exhaust host memory and thrash into swap hours in. The budget is now capped at
  `2 x maintenance_work_mem`, so peak build memory is bounded to
  `(max_parallel_maintenance_workers + 1) x 2 x maintenance_work_mem` regardless
  of corpus size. (Peak build memory scales with the worker count -- size
  `maintenance_work_mem` with that multiplier in mind.)
- **A freshly built or REINDEXed index now reclaims the free tail its final
  merge leaves on disk**, so it ships closer to its compacted size instead of
  carrying the merge's freed-input pages until the next VACUUM. (Full
  compaction of interior free space still comes from `fts_vacuum` / VACUUM.)

## 1.0.5

Bug-fix release. **No on-disk format change** from 1.0.4; no **REINDEX**
required (`ALTER EXTENSION pg_fts UPDATE TO '1.0.5'`).

- **Fixed sustained, unbounded-looking memory growth during a long index build
  over a high-vocabulary text column** (e.g. email/message bodies with quoted
  chains, patches, and code -- millions of distinct terms). The build bounds its
  memory by flushing a segment when the in-memory working set exceeds
  `maintenance_work_mem`, but the size check did not count the term hash table,
  which lives in a child memory context -- so on a vocabulary-dominant corpus
  the check undercounted the real working set and the flush fired far too late,
  letting a multi-hour build grow well past `maintenance_work_mem` (observed
  ~19 GB resident+swap on an 83 GB / 1.8M-row build before it was killed). The
  check now counts child contexts, so a build settles at roughly
  `maintenance_work_mem` regardless of vocabulary size. Affects both serial and
  parallel builds; no change to results or on-disk format.

## 1.0.4

Scale-hardening release. **No on-disk format change** from 1.0.3; no **REINDEX**
required (`ALTER EXTENSION pg_fts UPDATE TO '1.0.4'`).

- **`CREATE INDEX` on a large table with a modest `maintenance_work_mem` no
  longer fails** with "reached the maximum of 128 segments." The build flushed
  one segment per `maintenance_work_mem` of accumulation with no intermediate
  merge, so a large enough index overflowed the segment directory before the
  end-of-build merge. Each build participant now grows its own flush budget
  geometrically, so the flush count grows only logarithmically with corpus size
  (and stays far under the cap) -- parallel-safe, with no on-disk or behavior
  change to the finished index.
- **Corrected integer-width overflows that only surface at extreme scale** (wrong
  results, not crashes): document-frequency sums used in IDF/BM25 scoring and in
  `fts_index_df()` are now 64-bit (a term in more than ~4 billion documents no
  longer wraps); the anomaly-scan "skip common terms" filter no longer misfires
  on a term whose df exceeds ~2.1 billion.
- **`fts_index_stats`'s `nterms` output is now `bigint`** (was `int`), so an
  index with more than ~2.1 billion total distinct terms reports a correct
  count. This widens the function's output column; the upgrade replaces the
  function definition (a `DROP`/`CREATE`, applied automatically by
  `ALTER EXTENSION ... UPDATE`).

## 1.0.3

Bug-fix release. **No on-disk format change** from 1.0.2; no **REINDEX**
required (`ALTER EXTENSION pg_fts UPDATE TO '1.0.3'`).

- **Fixed an `invalid memory alloc request size` crash in a parallel index-build
  worker** (reported against a ~13-hour parallel `CREATE INDEX CONCURRENTLY`
  over a large table with a very large vocabulary). This was a different site
  from the 1.0.2 fix: the trigram inverted-index builder and the streaming
  segment merge sized several allocations from the *merged-group vocabulary*,
  which -- unlike the per-segment build path -- is not bounded by
  `maintenance_work_mem`, so a hot trigram's term list (and the merge output
  arrays) could exceed the 1 GB allocation limit on a large enough corpus. All
  corpus/vocabulary-scale allocations in the build, merge, and analyze paths now
  use a huge-safe allocation, closing this crash class off across the board.
- **A single document that would assemble into an `ftsdoc` larger than 1 GB now
  reports a clear "document is too large" error** instead of an opaque
  allocation failure. An `ftsdoc` is a variable-length value limited to 1 GB.

## 1.0.2

Bug-fix release. **No on-disk format change** from 1.0.1; no **REINDEX**
required (`ALTER EXTENSION pg_fts UPDATE TO '1.0.2'`).

- **Fixed a read-path crash (`invalid memory alloc request size`) when decoding
  a posting block with a very large per-block position count.** The
  positions-decode path in `bm25_decode_term` sized its scratch buffers with an
  unguarded allocation; when a block's summed term frequency pushed the buffer
  past the 1 GB `MaxAllocSize` limit, the allocation threw and aborted whatever
  triggered the decode -- a `CREATE INDEX CONCURRENTLY` validation scan in the
  reported case, but the same path is reached by ordinary scans (count, ranked,
  phrase), merges, and vacuum. A legitimately large position count now uses a
  huge-safe allocation; a corrupt or inflated on-disk term-frequency (a class
  the existing block-header and column-length corruption checks did not catch)
  is now detected and rejected with a `WARNING` (a bounded miss, `REINDEX` to
  rebuild), rather than reading past the block. This was the read-side
  counterpart of the build-time huge-allocation fix; both sides are now guarded.
- The corruption/fuzz harness gained a dedicated planted-bug ("teeth") build for
  this class, so a regression that removed the guard would fail CI.

## 1.0.1

Bug-fix release. **No on-disk format change** from 1.0.0; no **REINDEX**
required (`ALTER EXTENSION pg_fts UPDATE TO '1.0.1'`).

- **Fixed an out-of-memory crash when building or merging a large index.** The
  segment-merge phase (used by the final compaction of an index build, by
  `fts_merge`, and by parallel builds) decoded every posting of every term from
  all merged segments into memory at once before writing the result, so
  compacting a large index could hold the entire index's postings in RAM and
  OOM the server. Merging is now a bounded, streaming k-way merge that holds
  only one term's postings at a time; peak merge memory is independent of index
  size. Measured on a 3M-document build: peak merge memory dropped from 2240 MB
  to ~1 MB, with the same result and no build-time regression. No on-disk
  format change and results are unchanged (index-vs-sequential-scan parity, with
  positions, tombstone drops, and phrase queries all preserved).

## 1.0.0

First stable release. **No on-disk format change** from 0.3.x; no **REINDEX**
required (`ALTER EXTENSION pg_fts UPDATE TO '1.0.0'`). The on-disk format
(BM25_VERSION 3, FTS_DOC_VERSION 3) and the SQL surface are now considered
stable; future 1.x releases keep backward compatibility.

- **`fts_vacuum` now converges and reclaims space in a single call, never
  grows the index, and is interruptible.** Compaction previously could
  oscillate (transiently grow the index before shrinking) and, in a first
  correctness pass, could stabilize without reclaiming dead space; and no pg_fts
  operation checked for interrupts, so a long build/merge/vacuum could not be
  cancelled. `fts_vacuum` now compacts to the size floor in one call, is stable
  across repeated calls, and never returns larger than it started. It honors
  `pg_cancel_backend` and `statement_timeout` (nine interrupt-check points along
  the merge/vacuum path); a cancelled or out-of-disk run leaves the index valid
  and correct, just not fully compacted. Because compaction rewrites live data
  before freeing the old copy (for crash safety), it transiently needs free disk
  space of roughly the live index size, like `VACUUM FULL` / `CLUSTER` /
  `pg_repack`.
- **The transparent `count(*) ... WHERE col @@@ q` fast path is now chosen at
  scale.** The `FtsCount` custom-scan cost model was priced against the whole
  heap and lost to a bitmap index scan on large tables; it is now priced as the
  index-only visibility-map count it actually performs, so the planner uses the
  faster path automatically.
- **Supported versions.** PostgreSQL 17 and 18 are fully supported and gated in
  CI (regression + isolation + TAP). PostgreSQL 19 / `master`-devel builds and
  is exercised best-effort (it is unreleased).
- **Testing.** The TAP suite (crash recovery, replication, torn-page recovery,
  server-encoding install/parity) is now a gating part of CI on both forges,
  alongside regression + isolation, AddressSanitizer / UndefinedBehaviorSanitizer
  builds, a fuzz harness for the posting-decode path, property-based tests, and a
  line-coverage floor.

## 0.3.6

- **`fts_snippet` default ellipsis is now ASCII `...` (was the UTF-8 `…`).** The
  non-ASCII default made `CREATE EXTENSION pg_fts` FAIL on a non-UTF-8 server
  database (LATIN1, EUC_JP, ...) with "invalid byte sequence for encoding" --
  pg_fts was uninstallable there. The install SQL is now pure ASCII (guarded by
  `make check-ascii` in CI on both forges), so pg_fts installs on every server
  encoding. Callers who want the `…` glyph pass it explicitly:
  `fts_snippet(doc, q, ellipsis => Eu2026)`.
- **Character-encoding / multi-script correctness is now permanently tested.** A
  UTF-8 regression block asserts pg_fts `@@@` == native `to_tsvector @@` across
  14 scripts (Latin, Windows-1252 punctuation, CJK Han, Japanese, Hangul, NFC vs
  NFD combining marks, emoji + 4-byte astral, CJK Ext-B, Arabic/Hebrew RTL,
  Turkish dotless-i, German sharp-s), plus a corner-case block (fold-length
  changes, multi-mark combining, ZWJ, BOM, fullwidth, Cyrillic) exercising the
  built-in analyzer; and `t/004_encodings.pl` gates LATIN1 + EUC_JP *server*
  encodings (install + native parity on high/multibyte bytes).

## 0.3.5

Hardening + testing release. **No on-disk format change**; no **REINDEX**
required (`ALTER EXTENSION pg_fts UPDATE TO '0.3.5'`).

- **Further hardened the segment posting-decode path** against corrupt/torn
  pages (three issues found by the new fuzz harness, extending the 0.3.4 fix):
  the per-block `count` clamp was one-sided (a `uint32` count >= 2^31 cast to a
  negative `int` and slipped past `> BM25_BLOCK_SIZE`) and is now tested on the
  unsigned value; the three FOR columns' width-driven byte consumption is now
  bounded against the block's declared `bytelen` before decoding, so a corrupt
  width byte cannot read past the page; and a shift-by-64 undefined behavior in
  `bm25_for_unpack` on a corrupt width (> 64) is fixed (valid widths unaffected).
  A corrupt block remains a bounded miss with a `WARNING`, never a crash.
- **New testing regime** (see `doc/testing.md`), run in CI on both forges:
  an AddressSanitizer+UBSan build of the regression + isolation suite; a gating
  fuzz/corruption harness (`test/fuzz/`) over the FOR codec, the stored-document
  validator, and the block decoder, with planted-bug "teeth"; property-based
  tests (`test/hegel/`) for the codec + validator invariants; a torn-page
  crash-safety TAP test (`t/003_corruption.pl`); and a **90% line-coverage gate**
  on the pg_fts sources. `fts_doc_is_valid`'s logic was factored into a pure
  header (`pg_fts_docvalid.h`) shared with the fuzzer (behavior-identical).


## 0.3.4

Crash-safety bug-fix release. **No on-disk format change**; no **REINDEX**
required (`ALTER EXTENSION pg_fts UPDATE TO '0.3.4'`).

- **Fixed an intermittent crash in the segment posting-decode path**
  (`fts_doc_matches` <- `bm25_collect_matches` <- `bm25_gettuple`), a follow-on to
  the 0.3.3 pending-list fix that its validator did not cover. `bm25_decode_term`
  read a posting block header's `count` from disk and unpacked that many values
  into fixed 128-element (`BM25_BLOCK_SIZE`) stack arrays (`gaps`/`tfs`/`dls`)
  **with no bound check** -- a torn or corrupt block header with `count >
  BM25_BLOCK_SIZE` overflowed the stack (an AddressSanitizer heap/stack-buffer-
  overflow, reproduced against the FOR codec). The WAND block loader already
  clamped its count; this decoder (used by the boolean/`@@@`/count-pushdown/
  ranked/anomaly/trigram scan paths -- every `bm25_decode_term` caller) did not.
  It now clamps the per-block count to `BM25_BLOCK_SIZE` and stops decoding a
  block whose declared column byte lengths (`bytelen`/`posbytelen`) run past the
  page, so a corrupt block is a bounded miss (with a `WARNING` hinting `REINDEX`)
  instead of a crash. Fixing it inside `bm25_decode_term` protects all callers at
  once. Valid indexes are unaffected; a regression test decodes a large
  multi-block posting list (df >> 128, with positions).


## 0.3.3

Crash-safety bug-fix release. **No on-disk format change**; no **REINDEX**
required (`ALTER EXTENSION pg_fts UPDATE TO '0.3.3'`).

- **Fixed two backend crashes on the pending-list path** (reported on 0.3.2 /
  PostgreSQL 18 under heavy concurrent write load): a `_FORTIFY_SOURCE` buffer
  overflow (SIGABRT) in `add_posting` during the autovacuum pending-list flush,
  and a SIGSEGV in `fts_doc_matches` while scanning pending documents. Both
  stemmed from the pending-list readers casting raw index-page bytes to an
  `ftsdoc` and trusting its term metadata (`nterms`, per-term `len`/`tf`/
  `posoff`) without validation, so a malformed or torn page turned a bad length
  into a wild `memcpy` or a bad offset into an out-of-bounds read. The flush
  (`bm25_vacuumcleanup` -> `bm25_flush_pending`) and scan
  (`bm25_gettuple` -> `bm25_collect_matches`) paths now validate each pending
  document's structure against its own byte length (`fts_doc_is_valid`) before
  trusting any offset, and skip a malformed document with a `WARNING` (hinting
  `REINDEX`) instead of crashing the backend. `add_posting`'s fixed-size term
  key also clamps its length defensively as a last line of defense. Valid
  documents are unaffected. A crash-regression test covers the long-token
  pending -> scan -> flush cycle.


## 0.3.2

Additive release. **No on-disk format change**; no **REINDEX** required for the
extension upgrade (`ALTER EXTENSION pg_fts UPDATE TO '0.3.2'`). Indexes over
non-ASCII text should be `REINDEX`ed to pick up the new Unicode lowercasing;
ASCII-only indexes are unaffected.

- **`pg_stat_user_indexes` now reflects bm25 index usage** (PR #5, dinesh-salve).
  Every query path that reads the index registers an index scan
  (`pgstat_count_index_scan`), so `idx_scan`/`last_idx_scan` are no longer stuck
  at 0: the bitmap scan, the plain + ranked (`ORDER BY <=>`) index scans, the
  `count(*)` pushdown / `fts_count()`, and native `fts_search()` top-k.
  `idx_tup_read` is reported on the bypass paths too (the AM scan paths already
  get it from the generic index layer). A bare `ORDER BY <=>` with no `@@@`
  filter is a seq-scan+sort and correctly stays at 0.
- **Unicode lowercasing in the built-in analyzer** (PR #4, dinesh-salve). The
  built-in `to_ftsdoc(text)`/`to_ftsquery(text)` analyzer folded only ASCII
  `A-Z`, so accented text never matched case-insensitively (`'CAFÉ'` missed
  `'café'`). A shared `fold_token()` (used by the document analyzer, the query
  lexer, and the aux tokenizer, so both sides fold identically) now lowercases
  non-ASCII tokens per Unicode code point via `unicode_lowercase_simple()` in
  UTF-8 databases; non-UTF-8 databases keep byte-wise ASCII folding. Simple
  lowercasing, not full case folding (`'ß'` stays `'ß'`), matching pg_search's
  default, and `to_ftsdoc()` stays `IMMUTABLE`. **No on-disk format change**;
  ASCII-only indexes are unaffected. Indexes over non-ASCII text built before
  this change should be `REINDEX`ed (their stored terms are unfolded).
- **Build-time huge-allocation fix for very high-df terms.** At large diverse
  corpora (found while benchmarking at 20M docs -- see `bench/RESULTS_20M.md`) a
  single ultra-common token's build-time posting arrays can exceed `MaxAllocSize`
  (1 GB), which plain `palloc` rejects, aborting the index build. `add_posting`,
  `bm25_decode_term`, and `bm25_write_postings` now use the `...Huge` allocation
  variants past 1 GB. No format change.

## 0.3.1

Additive feature release. **No on-disk format change** (read-only over the
existing index) and no **REINDEX** required. `ALTER EXTENSION pg_fts UPDATE TO
'0.3.1'`.

- **Lexical anomaly detection: `fts_anomalous_docs(index, k, max_df)`.** A
  set-returning function that surfaces the top-`k` most lexically-anomalous
  documents in an fts index -- those containing globally **rare** terms. A
  document's anomaly score is the maximum idf over its terms (driven by its
  single rarest term), using the same rarity value BM25 uses:
  `idf = log(1 + (N - df + 0.5)/(df + 0.5))` on the **global** df (a term's df
  is summed across all segments before scoring, so a document split across two
  segments is not made to look artificially rare). Returns
  `(ctid tid, score float8, rarest_term text, min_df int)` ordered by score
  DESC, limit `k`.
  - **Cheap because it walks only the low-df tail.** The rarest terms have the
    shortest posting lists, so the function walks the term dictionary and
    **skips any term whose global df exceeds `max_df` before decoding a single
    posting** -- the common, high-df bulk of the dictionary is never decoded.
    On a 1M-document corpus with a handful of injected unique tokens, the query
    returns those docs in **well under a millisecond** (measured 0.6 ms), not a
    full-corpus scan. `max_df` defaults to `max(N/1000, 1)` when NULL, keeping
    the walk on the low-df tail.
  - The returned ctids are index-resident heap pointers (like `fts_search`);
    this is an analytic/heuristic result, so no per-doc heap visibility check is
    done -- join `ctid` back to the table and filter for visibility if needed.
    Per-segment tombstones are honored, so deleted documents are not reported as
    anomalies.
  - Lexical only: it catches rare/novel *wording and tokens*, not semantic
    novelty (see `bench/NOTE_ANOMALY_DETECTION.md`). Bench harness in
    `bench/anomaly.sql`.
- **Fixed `ftsdoc` text I/O round-trip (Codeberg #3).** `ftsdoc_out` emitted the
  canonical `'term':tf` form but `ftsdoc_in` re-tokenized that string as raw
  text, so `ftsdoc_in(ftsdoc_out(x)) != x` -- text `COPY`/`pg_dump --inserts` of
  stored `ftsdoc` columns corrupted the data. `ftsdoc_in` now parses the
  canonical grammar `'term':tf[@p1,p2,...]` (falling back to raw-text analysis
  for the ergonomic `'the quick brown fox'::ftsdoc` cast), and `ftsdoc_out`,
  `ftsdoc_send`/`ftsdoc_recv` now carry per-token **positions** so both text and
  binary I/O are faithful, position-preserving round-trips. Input is validated
  at the trust boundary (ascending/distinct terms, `tf>=1`, ascending positions,
  `tf` positions per term; corrupt binary bounded before palloc). The `ftsdoc`
  binary wire version bumped 2 -> 3; `ftsdoc_recv` still **accepts v2** so a
  `pg_dump -Fc` taken under an older pg_fts restores cleanly (v2 docs are
  position-free). No on-disk index format change.

## 0.3.0

Feature release with an **on-disk index format change (BM25 v2 -> v3)**. Existing
bm25 indexes must be **REINDEX**ed; the format guard rejects a v2 index with a
REINDEX hint. No `ftsdoc`/`ftsquery` type change.

- **Token positions in the postings, gated by a new `positions` reloption.**
  `CREATE INDEX ... USING fts (...) WITH (positions = on)` stores per-token
  positions in the posting blocks (a 4th, lazily-decoded frame-of-reference
  column after docid-gaps/tf/doclen). Phrase and NEAR queries are then answered
  **directly from the posting lists** -- intersect on docid, verify adjacency
  from the stored positions via the same `phrase_step` logic the heap recheck
  uses -- with **zero heap access and no recheck**. This removes the phrase/NEAR
  count cliff (a common two-word phrase count over an expression index dropped
  from seconds to the AND-count range in local tests) for both the expression
  index (`to_ftsdoc(col)`) and the stored-`ftsdoc`-column shapes.
  - **Default is `positions = off`**: positions roughly double the posting bytes
    on high-term-frequency corpora, so the size-sensitive majority who never
    phrase-search pay nothing. Phrase/NEAR is **always correct** either way; it
    is only fast (index-only, no recheck) with `positions = on`. With
    `positions = off` it falls back to the correct-but-slower heap recheck.
  - Positions are decoded **lazily**: plain BM25 ranked / boolean AND / count
    queries never read or decode the positions column (a `posbytelen`-guided
    pointer skip, mirroring the existing tf/doclen skip), so a non-phrase query
    pays ~zero for positions existing (measured: no regression vs v2 on a
    common-term ranked/count query).
  - `fts_vacuum` / merge carry positions through the compaction rewrite and keep
    reclaiming space; a pathological per-(term,doc) term frequency whose
    positions would overflow a page drops that block's positions and phrase
    falls back to recheck for those docids (correctness preserved).

## 0.2.4

Bug-fix release. The fix is in the shared library; no SQL objects change and no
REINDEX is required. `ALTER EXTENSION pg_fts UPDATE TO '0.2.4'`.

- **Phrase / NEAR queries silently returned wrong results on a *stored* `ftsdoc`
  column.** The positions[] region of a document was addressed as
  `MAXALIGN(absolute-pointer)`, but the analyzers lay it out at
  `base + MAXALIGN(offset)`. For a heap-resident (detoasted) document whose base
  is not itself MAXALIGN'd, `MAXALIGN(base+off) != base+MAXALIGN(off)`, so the
  position array was mis-addressed and phrase/NEAR degraded to a plain AND
  (matching any document containing the terms, ignoring adjacency). Fixed to the
  offset-based address. Expression indexes on `to_ftsdoc(col)` were unaffected
  by this bug (freshly-analyzed, always-aligned documents); short documents in
  the existing tests happened to remain aligned, which is why it was missed.
- Note: phrase *count* over an expression index on a common two-word phrase is
  still slow (it rechecks the whole AND-set against the heap, re-analyzing each
  document). A positional-index format change in a later release removes that
  heap recheck; this release only fixes the stored-column correctness bug.

## 0.2.3

Performance release. The change is in the shared library; no SQL objects change,
results are unchanged, and no REINDEX is required.
`ALTER EXTENSION pg_fts UPDATE TO '0.2.3'` after installing the new library.

- **Ranked `ORDER BY d <=> q LIMIT k` over a boolean AND/NOT query is much
  faster.** The 0.2.1 boolean-structure correctness fix pre-collected the entire
  exact `@@@` match set before the ranked scan filtered against it, which was
  slow on common terms (e.g. `year & hungary` top-10 took ~37 ms at 2M docs
  because the whole `year` posting list was materialized). The ranked scan now
  evaluates the query's boolean structure **lazily** during the WAND traversal
  (from which terms are present at each candidate), with no collect pass:
  `year & hungary` top-10 drops to ~1 ms at 2M (measured), and a near-universe
  NOT like `year & !hungary` from ~415 ms to ~42 ms. Results are byte-identical
  (the ground-truth ranked-parity test passes unchanged). Pure-OR / single-term
  queries were already on the fast path and are unchanged; phrase/NEAR/fuzzy/
  regex keep the exact-recheck path.

## 0.2.2

Bug-fix release. The fix is in the shared library; no SQL objects change.
`ALTER EXTENSION pg_fts UPDATE TO '0.2.2'` after installing the new library.

- **Phrase (`"a b c"`) and NEAR queries now enforce term adjacency on all query
  paths.** They previously degraded to AND (matching any document containing the
  terms, regardless of order/adjacency) on the primary `to_ftsdoc(regconfig,
  text)` path — e.g. `to_ftsdoc('english', body)` — because that analyzer did not
  store token positions; and the index candidate path did not request the heap
  recheck that would have enforced adjacency, so non-adjacent documents leaked
  through `@@@`, the bitmap scan, and the ranked `<=>` scan alike. Now: the
  config analyzer stores positions; `@@@`/bitmap enforce adjacency via the
  executor recheck; and the ranked `<=>` scan and `fts_count()` recheck the exact
  match set against the heap document (`bm25_recheck_exact`). Phrase / NEAR /
  boolean ranking is exact on all paths.
- No REINDEX required (bm25 on-disk format unchanged). Phrase correctness on a
  *stored* `ftsdoc` column populated by the old analyzer requires re-analyzing
  those rows; expression indexes on `to_ftsdoc(...)` are correct immediately.
- Known limitation (documented): ranked `<=>` over fuzzy/prefix/regex returns a
  correct *subset* of the `@@@` matches (never a wrong document, but may be
  incomplete, since the ranked scan builds cursors from the literal term). Use
  `@@@` for exhaustive fuzzy/prefix/regex retrieval.

## 0.2.1

Bug-fix release. The fix is entirely in the shared library; no SQL objects
change and existing `fts` indexes need no REINDEX (on-disk format unchanged from
0.2.0). `ALTER EXTENSION pg_fts UPDATE TO '0.2.1'` after installing the new
library.

- **Ranked `<=>` scan now respects boolean AND/NOT/PHRASE structure.** The
  `ORDER BY d <=> q LIMIT k` ordering scan previously ranked the term
  *disjunction* (it flattened the query to its terms) and never intersected with
  the boolean match set that `@@@` uses, so AND/NOT/PHRASE queries could return
  documents that fail `@@@` — e.g. `a & !b` ranked documents that *contain* `b`.
  The ranked scan now gates results by the exact `@@@` match set, so every row
  it returns satisfies `@@@`. `@@@` matching and pure-OR / single-term ranking
  were already correct and are unchanged.

## 0.2.0

**Breaking:** the index access method was renamed **`bm25` → `fts`**
(`CREATE INDEX ... USING fts (to_ftsdoc('english', body))`).  This lets pg_fts
coexist in the same database as Timescale pg_textsearch (whose AM is named
`bm25`), so a pg_textsearch workload can be migrated one index at a time rather
than in a single hard cutover.  Existing `USING bm25` indexes must be recreated
as `USING fts`.  The BM25 scoring functions (`fts_bm25`, `fts_bm25f`,
`fts_bm25_opts`) are unchanged — BM25 is the ranking algorithm, `fts` is the
access method.

- On-disk format version check: opening an index whose stored format version
  does not match the loaded shared library now raises a clear error
  (`... has pg_fts on-disk format version N, but this build expects M`) with a
  `REINDEX` hint, instead of silently misreading the index.
- New `doc/MIGRATING_FROM_PG_TEXTSEARCH.md`: query/DDL rewrite table, the
  multi-column → concatenated-`to_ftsdoc` pattern, and index build sizing
  (`CREATE INDEX` bounds build memory to `maintenance_work_mem`).

## 0.1.0 — initial public release

First public release.  The extension was developed as an internal, qualified
feature series (each stage clean under `--enable-cassert`, regression-green)
that reached internal version 1.20 before being squashed to a single `0.1.0`
install script for release.  Versioning starts at 0.1.0 to signal that the
on-disk format and ranked-query performance will iterate before 1.0.

Included in 0.1.0:

- `ftsdoc` / `ftsquery` types, the `@@@` match operator, and the `<=>`
  relevance-ordering operator (`ORDER BY d <=> q LIMIT k` plans as an index
  scan, no Sort).
- The `bm25` inverted-index access method: WAL-logged via GenericXLog
  (crash-safe, physical-replication safe), MVCC-correct (per-segment
  tombstones), segmented (Lucene/Tantivy-style) on-disk format with a
  size-tiered background merge, block-max WAND / MaxScore top-k with lazy
  per-column decode.
- Okapi BM25 scoring with the lucene / robertson / atire / bm25+ / bm25l
  variants; BM25F multi-field weighting; index-maintained corpus statistics
  (N, avgdl, per-term df) so ranking needs no heap recheck.
- A rich query language over one operator: boolean, phrase `"a b c"`, NEAR,
  prefix `term*`, fuzzy `term~k` (Levenshtein DFA), and regex `/re/`, with a
  trigram pre-filter for fuzzy/regex.
- `fts_highlight()` / `fts_snippet()`; `tsquery_to_ftsquery()` migration helper
  and cast.
- Incremental maintenance (INSERT appends to a pending list, no REINDEX);
  `fts_merge()` and `fts_vacuum()` (compact + truncate) for on-demand
  maintenance.
- `fts_count()` and a transparent `count(*) ... WHERE @@@` CustomScan pushdown
  for MVCC-correct bulk counts from the index — a capability the specialist
  BM25 extensions do not expose.
- Parallel index build/merge; standalone PGXS build plus Nix flake and a
  Windows/MSVC meson recipe; supported on PostgreSQL 17, 18, and 19/devel.

Known performance position (see `bench/RESULTS_VS_VCHORD_PGTEXTSEARCH.md`):
pg_fts is far faster than the built-in tsvector/GIN + `ts_rank`
stack on ranked retrieval (up to ~40×), but trails the specialist BM25
extensions (VectorChord-bm25, Timescale pg_textsearch) on raw ranked latency and
index size.  Closing that
gap is a posting-codec rewrite tracked in `ROADMAP.md`; 0.1.0 ships on its
distinguishing strengths — query-language breadth, index-native COUNT, and
MVCC/crash correctness — and will iterate on ranked performance.
