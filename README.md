> **Freecase integration candidate:** upstream 1.12.1 plus the existing legal-search
> and wide-position fixes. Compatibility and correctness were tested locally
> and on VM801; pg_fts-on still timed out on 90/225 searches (40%).
> Production performance acceptance remains unproven. This is not a production release.
> See `bench/RESULTS_FREECASE_1121_2026-10-14.md`. Historical upstream benchmark tables below are not measurements of
> this combined build. Existing format-4 indexes are retained.

# pg_fts — BM25 full-text search for PostgreSQL

[![CI](https://github.com/gburd/pg_fts/actions/workflows/ci.yml/badge.svg)](https://github.com/gburd/pg_fts/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/tag/gburd/pg_fts?label=release&sort=semver)](https://github.com/gburd/pg_fts/releases)
[![License: PostgreSQL](https://img.shields.io/badge/license-PostgreSQL-blue)](LICENSE)

A PostgreSQL extension for full-text search with true **BM25/BM25F** relevance
ranking, a dedicated `fts` inverted-index access method, and a rich query
language (boolean, phrase, NEAR, prefix, fuzzy, regex).  Unlike the
`tsvector`/`tsquery` + GIN stack, the index maintains the corpus statistics
BM25 needs (document count, average length, per-term document frequency) and
stores term frequency + document length in the posting lists, so ranking is
answered from the index with no heap recheck.

## Benchmarks and comparison

* `bench/BENCHMARK_SUMMARY.md` — current measured results with full methodology
  (rig, corpus, 8-run timing protocol, correctness gate), plus the list of
  optimisations that were tried and **rejected by measurement**, and the record of
  benchmark numbers we published wrong and corrected.
* `doc/COMPARISON_MATRIX.md` — feature/performance matrix against pg_textsearch,
  pg_search (ParadeDB), VectorChord-bm25 and built-in tsvector/GIN, marking
  untested competitor capabilities as untested rather than absent.

## Requirements

- PostgreSQL **17 and 18** are fully supported and gated in CI (build +
  regression + isolation + TAP on both).  PostgreSQL **19/`master`-devel**
  builds and is exercised best-effort in CI (it is unreleased; packaging can
  lag).  Version differences are handled with compile-time guards.
- A C toolchain and the PostgreSQL server headers (`postgresql-server-dev-*`
  or a source install exposing `pg_config`).

## Build and install

```sh
make PG_CONFIG=/path/to/pg_config
sudo make install PG_CONFIG=/path/to/pg_config
```

`PG_CONFIG` defaults to whatever `pg_config` is on `PATH`.

On Windows with MSVC (where PostgreSQL is built with meson rather than PGXS)
use the meson recipe instead, pointing `pg_dir` at an MSVC-built PostgreSQL
≥ 17 (a MinGW/Strawberry PostgreSQL will not work):

```sh
meson setup build -Dpg_dir=C:/pgsql --buildtype=release
ninja -C build
ninja -C build install
```

With [Nix](https://nixos.org) (flakes) you can build and test without a local
PostgreSQL install:

```sh
nix build .#default              # build against nixpkgs PostgreSQL 17
nix flake check                  # build + regression/isolation tests, PG 17 and 18
nix develop                      # dev shell with the toolchain + pg_config
nix run .#docs                   # validate doc/pg_fts.sgml
```

## Test

```sh
# against a running server (regression + isolation; TAP needs a
# --enable-tap-tests build):
make installcheck PG_CONFIG=/path/to/pg_config
```

Standalone property-based tests (hegel-c) for the pure-C codec/automaton cores
live in [`test/hegel/`](test/hegel/README.md); they need extra deps (hegel-c,
libcbor, cmocka, the `hegel` binary) and are separate from `make installcheck`.

## Use

```sql
CREATE EXTENSION pg_fts;

CREATE TABLE docs (id bigint, body text);
-- index the analyzed document
CREATE INDEX docs_bm25 ON docs USING fts (to_ftsdoc('english', body));

-- boolean / phrase / prefix / fuzzy / regex match
SELECT id FROM docs
 WHERE to_ftsdoc('english', body) @@@ to_ftsquery('english', 'quick & fox');

-- BM25-ranked top-k (index-only ordering scan).  The @@@ predicate is required
-- to use the index for the ORDER BY d <=> q KNN scan.
SELECT id FROM docs
 WHERE to_ftsdoc('english', body) @@@ to_ftsquery('english', 'quick fox')
 ORDER BY to_ftsdoc('english', body) <=> to_ftsquery('english', 'quick fox')
 LIMIT 10;

-- fast COUNT (transparent: a plain count(*) WHERE @@@ is pushed to the index).
-- A single plain term on a VACUUMed, tombstone-free index is answered from the
-- dictionary's document frequency alone -- no postings read, no heap touched.
-- Anything else (prefix/fuzzy/regex/weighted/multi-term, pending docs, tombstones,
-- or a heap that is not all-visible) falls back to the exact count automatically.
SELECT count(*) FROM docs
 WHERE to_ftsdoc('english', body) @@@ to_ftsquery('english', 'quick');

-- maintenance (run on the primary; both require index ownership and error on a
-- read replica -- they write WAL)
SELECT fts_merge('docs_bm25');    -- compact segments now
SELECT fts_vacuum('docs_bm25');   -- reclaim disk space (compact + truncate)

-- regex / long-fuzzy acceleration is opt-in (default off):
--   CREATE INDEX ... USING fts (to_ftsdoc('english', body)) WITH (trigrams = on);
-- fts_search()/fts_anomalous_docs() emit indexed content and are REVOKEd from
-- PUBLIC; the index owner and superusers keep access (GRANT to widen).
```

See `doc/pg_fts.sgml` for the full reference (rendered to HTML and published to
[GitHub Pages](https://gburd.github.io/pg_fts/)), `doc/CAPABILITIES.md`
for the feature matrix, `ROADMAP.md` for the roadmap, and
`doc/MIGRATING_FROM_PG_TEXTSEARCH.md` if you are moving from Timescale
pg_textsearch.

---

pg_fts -- BM25 full-text search for PostgreSQL
==============================================

pg_fts is a contrib extension providing full-text search with BM25/BM25F
relevance ranking, a dedicated inverted-index access method, phrase/prefix/
fuzzy/regex query support, and result presentation.  It differs from the
tsvector/tsquery + GIN stack in that the index maintains the corpus statistics
(document count, average length, per-term document frequency) BM25 ranking
requires, and posting lists carry term frequency and document length, so
ranking needs no heap recheck.

The extension is developed as a qualified feature series (each stage builds
clean under --enable-cassert and passes its regression test).  The internal
series was squashed to a single install script for the first public release
(0.1.0); the public line has since iterated through 0.2.x to 0.3.2, with
in-place `ALTER EXTENSION pg_fts UPDATE` upgrade scripts between releases.

Features
--------

  * ftsdoc/ftsquery types, to_ftsdoc()/to_ftsquery(), the @@@ match operator
  * the fts index access method (bitmap scan + <=> ordering scan, GenericXLog
    crash-safe, MVCC-correct)
  * fts_bm25(): Okapi BM25 scoring, with the lucene/robertson/atire/bm25+/bm25l
    variants; fts_bm25f(): BM25F multi-field weighting
  * index-maintained corpus statistics (fts_index_stats()/fts_index_df()) so
    ranking needs no heap recheck
  * fts_highlight() and fts_snippet(); tsquery_to_ftsquery() migration + cast
  * phrase queries ("a b c") via per-term positions; prefix (term*), fuzzy
    (term~k, Levenshtein DFA), and regex (/re/) terms, with an optional trigram
    pre-filter (`WITH (trigrams = on)`; default off -- regex/long-fuzzy fall
    back to a dictionary scan without it)

    > **Phrase queries need `WITH (positions = on)` to be fast.** The option
    > defaults to **off**, and without it a phrase cannot be verified from the
    > index: the scan falls back to AND plus a **heap recheck** of every
    > candidate document. Measured on 2.19M Wikipedia articles
    > (`bench/NOTE_PHRASE_PROFILE_2026-09-06.md`): ranked top-10 for
    > `"united states"` costs **8,385 ms** with the default and **229 ms** with
    > `positions = on` (**36x**; 1.6-era figures; 1.10.0 runs it in **36.9 ms**
    > with `positions = on`, see Performance); an exact phrase `count(*)` goes **7,170 ms ->
    > 132 ms** (**54x**). The cost is a larger index -- 1,421 MB -> 2,626 MB
    > (1.85x) on that corpus. If you issue phrase or NEAR queries at scale,
    > enable it at CREATE INDEX time.
    >
    > Note also that phrase syntax uses **double** quotes:
    > `to_ftsquery('english', '"united states"')`. Single quotes produce a
    > plain conjunction (`('unit' & 'state')`), which matches many more rows.
  * external-content indexing via an expression index on to_ftsdoc(col)
  * incremental maintenance (INSERT appends to a pending list, no REINDEX);
    background/on-demand merge (fts_merge()) and compaction (fts_vacuum())

    > **Two build-tuning facts worth knowing before your first large index**
    > (measured on 2.19M Wikipedia articles;
    > `bench/RESULTS_GATING_2026-09-09.md`):
    >
    > **1. Raise `maintenance_work_mem` to >= 1GB and the post-build merge
    > disappears.** At that setting this corpus builds straight to a single
    > segment. At PostgreSQL's 64MB default the same build leaves 8 segments plus
    > a **216 s** merge, and the index lands **twice as large** (8,613 MB vs
    > 4,605 MB). If a build is followed by a long merge, this is the first knob to
    > reach for.
    >
    > **2. `max_parallel_maintenance_workers` makes *merges* slower.** It speeds a
    > build up at no durable size cost, but do not raise it for merges.
    > A parallel build is faster (464 s vs 523 s at `maintenance_work_mem=1GB`) and,
    > once `fts_vacuum` has run, **exactly the same size** (1,420 MB either way) --
    > an earlier claim that it was ~17% larger was measured before vacuuming and is
    > withdrawn. The merge finding is solid and separate: a parallel `fts_merge` is
    > **1.45x slower** than serial and leaves 19% more residue, so do not raise this
    > setting hoping to speed up a merge.
  * block-max WAND / MaxScore top-k with lazy per-column decode; fts_search()
    index-only BM25 top-k
  * fts_count(): MVCC-correct bulk count via the index, plus a transparent
    count(*) WHERE @@@ CustomScan pushdown (fires for a stored-column index too,
    not only an expression index); a single plain term over a VACUUMed index is
    answered from the dictionary document frequency alone (~hundreds of times
    faster than decoding the postings)

Query language
--------------

  quick brown          implicit AND
  quick & brown        AND          quick | brown   OR      !slow / -slow  NOT
  (a | b) & c          grouping
  "quick brown fox"    phrase (adjacent)
  quick p/5 fox        ordered proximity, up to 5 token positions apart
  quick w/5 fox        either word order, up to 5 token positions apart
  (dog | canine) w/10 bite   either dog or canine near bite
  NEAR(quick fox, 5)    ordered proximity (existing syntax)
  a w/3 b w/5 c        chained proximity (left associative)
  "summary judgment" w/5 negligence   phrase proximity
  breach <2> contract  exact two-position gap
  quick*               prefix
  quick~2              fuzzy, edit distance <= 2
  /^qu.*x$/            regex over each term
  title AND fox        keyword operators (AND/OR/NOT, case-insensitive)

`w/N` accepts terms, phrases, OR alternatives, and nested proximity groups.
It joins nonoverlapping matches whose nearest edges are 1..N token positions
apart, in either order (adjacent words have distance 1). Chaining is left
associative; parentheses change grouping. All matching spans are retained.
For example, `(a w/3 b) w/5 c` puts `c` near either outside edge of the `a`/`b`
match. `p/N` and `NEAR` retain their historical ordered endpoint semantics.
AND/NOT directly inside proximity are rejected because they have no span.

Quoted phrases use exact adjacency, with removed stopwords preserving their
spacing: `to_ftsquery('english','"breach of contract"')` yields
`'breach' <2> 'contract'`. Exact `<N>` includes `<0>` for the same position.
Prefix, fuzzy and regex terms work positionally inside phrases. Prefixes may
also carry weights (`attorn*:A`); fuzzy+weight and regex modifiers error.

Use `WITH (positions=on)` for compound proximity without heap rechecks, also
when combined with AND and NOT. Weighted/expanded terms still use exact
rechecks, and so does a document whose positions were not stored or are
oversized (that document alone).
The configured analyzer preserves 30-bit positions using PostgreSQL's parser
and dictionary pipeline. This fixes the prior 16,383-position cap for newly
analyzed source text. Existing capped `ftsdoc` values and indexes need regeneration
from their original text; converting an existing `tsvector` cannot recover spacing
already lost on input. The on-disk representation is unchanged.

Example
-------

  CREATE EXTENSION pg_fts;

  CREATE TABLE docs (id int, body text);
  CREATE INDEX docs_bm25 ON docs USING fts (to_ftsdoc('english', body));

  SELECT id,
         fts_bm25(to_ftsdoc('english', body), q,
                  s.ndocs, s.avgdl,
                  fts_index_df('docs_bm25', q)) AS score,
         fts_snippet(body, q) AS excerpt
  FROM docs, fts_index_stats('docs_bm25') s,
       to_ftsquery('postgres & "query planner" & index*') q
  WHERE to_ftsdoc('english', body) @@@ q
  ORDER BY score DESC
  LIMIT 10;

Performance
-----------

**1.12.0** (`bench/RESULTS_112_2026-10-09.md`) changes ranked queries only, measured
against 1.11.0 on the same hosts and indexes: identical results; single-client rare /
common top-10 0.54 / 0.67 -> 0.27 / 0.36 ms; throughput at 16-64 clients rare +67-97%,
mid +49-60%, common +74-92%, `united & states` +42-53%; `count(*)` unchanged.  The
competitors have not been re-measured against 1.12.0, so the cross-engine table below is
still the 1.11.0 run, and every pg_fts figure in it is 1.11.0's.

Numbers below are from `bench/RESULTS_111_2026-10-09.md` (summarized in
`bench/BENCHMARK_SUMMARY.md`; if the two ever disagree, the results file is right).  They
are for the **1.11.0 release binary**, built from its PGXN zip.  Method, briefly: four
engines at their latest release, **one AWS r7gd.4xlarge per engine** (Graviton3, 16 vCPU,
128 GiB, local NVMe), Debian 13 arm64, PostgreSQL 17.10 built from source with identical
settings on every host, all four run the same night; English Wikipedia, 2,188,038 articles,
md5-identical input; each engine's documented English-stemmed index and query form; warm
cache; latency = median of the last 5 of 8 runs in one session, 3 sessions; throughput =
`pgbench -T 30` at 16/32/64 clients after a CHECKPOINT and 60 s idle, two runs.  pg_fts's
ranked results are checked against an exhaustive reference before any timing is taken;
match counts against a regex over the raw text.  Protocol (written before the run),
scripts, raw output and every engine's install log: `bench/PROTOCOL_111_2026-10-09.md`,
`bench/data_111_2026-10-09/`.  Speedups over 1.10.0 are in `bench/RESULTS_A_2026-10-07.md`.

| ms, single client | **pg_fts 1.11.0** | pg_textsearch 1.5.1 | pg_search 0.26.1 | VectorChord-bm25 0.3.0 |
|---|---|---|---|---|
| rare term top-10 | **0.57** | 0.99 | 2.59 | 13.6 |
| mid term top-10 | **0.42** | 1.21 | 2.27 | 26.6 |
| common term (df 735k) top-10 | **0.72** | 10.69 | 2.63 | 72.4 |
| common term top-100 | **1.15** | 13.01 | 5.46 | 78.0 |
| AND / OR top-10 (rare terms) | **1.16 / 1.68** | >300 s / >300 s | 3.31 / 3.58 | n/a / 7.90 |
| AND top-10, `united & states` | **2.49** | >300 s | 11.61 | n/a |
| AND top-10, `world & war` | 5.87 | >300 s | **5.75** | n/a |
| 4-term OR top-10 | 13.97 | 14.63 | **13.40** | 42.4 |
| phrase top-10, `"united states"` | **2.84** | >300 s | 11.41 | n/a |
| phrase top-10, `"world war"` | **6.45** | >300 s | 11.54 | n/a |
| exact `count(*)` | **0.18** | n/a | 8.64 | n/a |

| tps, 16 / 64 clients | **pg_fts 1.11.0** | pg_textsearch | pg_search | VectorChord |
|---|---|---|---|---|
| rare term top-10 | **24,696 / 25,431** | 14,259 / 12,595 | 5,364 / 6,291 | 366 / 875 |
| common term top-10 | **19,359 / 19,507** | 1,321 / 1,267 | 5,327 / 5,959 | 73 / 138 |
| exact count | **74,619 / 68,764** | n/a | 945 / 4,434 | n/a |

Index size: pg_fts **1,421 MiB** on a stored `ftsdoc` column (1,369 MiB as an expression
index), pg_textsearch 1,887, pg_search 3,395, VectorChord 42,434 (see the caveat in the
results file).  Build, as an expression index so every engine analyses the text inside its
build: pg_search **72 s**, pg_fts 238 s (no `fts_vacuum` needed), pg_textsearch 267 s.

  * **Where pg_fts wins.**  Ranked single-term queries at every frequency, including
    common terms (best-first block order with exact block bounds: a top-10 for a term in
    735k documents visits ~32 blocks).  Throughput under load: 1.7-3.2x pg_textsearch and
    4.0-5.9x pg_search on rare/mid terms, 3.3-3.6x pg_search on a common term.
    Conjunctive queries, both rare and common, and phrases: AND and phrase walk the rarest
    term's blocks best-first and look the others up.  pg_textsearch's boolean and phrase
    forms are sequential scans that each exceeded 300 s here.  Exact `count(*)` is
    index-native, 48x pg_search single-client.  The smallest index.  One operator for the
    full query language (phrase, NEAR, prefix, fuzzy, regex, field zones), exact top-k
    (no early termination), MVCC-correct results, and crash, replication and corruption
    testing.
  * **Where pg_fts does not win.**  pg_search builds 3.3x faster.  On `world & war` (both
    terms frequent, their best documents spread over many blocks; 2%, spreads overlapping)
    and on a 4-term OR (4%), pg_search is slightly faster.
  * **What is not compared.**  Relevance quality (NDCG), write throughput, x86 for this
    run, and network storage (a cold-cache band on local NVMe is in the results file:
    41-65 ms for pg_fts 1.11.0).  All four engines rank the same documents highly but
    tokenize slightly differently.
  * vs the built-in tsvector/GIN + ts_rank stack, pg_fts is far faster on ranked
    retrieval (up to ~40x on common-term top-k, because ts_rank must fetch and
    sort every match).

fts_bm25_opts variants reproduce Lucene/bm25s scores for conformance.
Ranked-retrieval performance continues to iterate (see ROADMAP.md).

Known limitations / future work
--------------------------------

  Build time trails pg_search (above); ROADMAP.md tracks the remaining work.  Other
  tracked ideas:

  * A fully resumable WAND cursor (emit/suspend/resume) instead of the current
    adaptive-k batch-with-growth.  WAND needs the top-k threshold to prune, so
    the batch shape is natural; the adaptive-k form already bounds work to the
    LIMIT actually requested and starts at a full page so common LIMITs are one
    pass.
  * Impact-ordered postings, to let ranked scans over a very common term stop
    earlier than docid-ordered block-max WAND allows.
  * Richer regex trigram tiling (full Navarro (k+1)-tiling / Mihov-Schulz
    automaton, as in pg_tre) beyond the literal-run tiling implemented here.
  * A+C for the trigram index: option C would store the *complement* of a dense
    trigram's term set (small when the trigram is common) with an is_complement
    flag, keeping every stored set <= half the vocabulary.

  Evaluated and deliberately not done: patched-FOR (PFOR) block encoding
  (measured ~<0.5% index saving, not worth the decode complexity); a chained
  overflow segment directory (the size-tiered merge keeps the count far below
  the 128 cap, and the cap raises a clear error rather than corrupting).

Storage architecture
--------------------

The fts index is a set of immutable SEGMENTS plus a small pending write buffer
(the Lucene/Tantivy consensus design):

  * Each segment has a term dictionary (with a sparse per-page block index for
    O(log P) term lookup and sublinear prefix scan), FOR-bit-packed 128-doc
    posting blocks carrying per-block max-tf and min-|D| impact bounds, an
    optional trigram index over the vocabulary (fuzzy/regex; built only
    `WITH (trigrams = on)`, default off), and a livedocs
    tombstone bitmap.
  * INSERT appends to the pending buffer (immediately searchable); a flush
    (fts_merge() or VACUUM) folds pending docs into a new segment.  CREATE INDEX
    flushes multiple segments to bound build memory (maintenance_work_mem).
  * A size-tiered merge coalesces similarly-sized segments (dropping tombstoned
    docs), keeping the live segment count small so per-term query cost stays low.
  * DELETE/UPDATE are recorded as per-segment tombstones by VACUUM
    (ambulkdelete); scans and fts_count subtract them, and merges drop them.

Query execution
---------------

  * @@@ boolean/phrase/NEAR/prefix/fuzzy/regex plans as a bitmap scan.
  * ORDER BY d <=> q LIMIT k plans as an index scan (no Sort) driven by
    document-at-a-time block-max WAND (short queries) or MaxScore (>= 4 terms),
    with lazy per-column posting decode so pruned blocks never decode tf/doclen.
  * fts_count(regclass, ftsquery) counts matches in bulk from the index using
    the visibility map (heap probed only for not-all-visible pages).  A plain
    count(*) ... WHERE col @@@ q is transparently answered by this fast path via
    a Custom Scan (FtsCount) -- no need to call fts_count() explicitly.
  * fts_vacuum(regclass) reclaims the physical space left by builds and merges:
    it compacts to a single segment (relocating live pages toward the front of
    the file) and truncates the freed tail back to the OS (runs automatically
    during VACUUM when the index is substantially bloated).  A single call
    reclaims most of the space; a second converges to the floor -- measured
    2026-09-09, one call left ~4.7% above the live floor on a 2.19M-doc index,
    which matches what the reference documentation already stated.

    > **How much space this is, measured.** After a 2.19M-document build at
    > `maintenance_work_mem=1GB`, `pg_relation_size` was **4,406 MB** but only
    > 173,529 pages were live (**1,355 MB**) — 69% of the file was already-freed
    > pages. `fts_vacuum` reclaimed all of it: **4,406 → 1,355 MB**. Live pages
    > average **98.8% full**, so this is not a packing problem; it is that a merge
    > allocates its output by extending the file, and the truncation step can only
    > return a *contiguous free tail* — with the final output sitting at the top of
    > the file, the freed pages beneath it need the compaction pass to move live
    > data down before anything can be truncated.
    >
    > **Unattended autovacuum holds the index bounded, and reclaims after deletes — no
    > scheduled maintenance required.** Measured at 1M docs with autovacuum on and no
    > manual maintenance at all: five consecutive cleanups with nothing changed stayed
    > **flat at 511 MB**; six rounds of insert + delete churn stayed **flat at 875 MB**;
    > and after deleting half the table, cleanup brought the index **875 → 106 MB (8.3×)**
    > with queries served throughout and results exact
    > (`bench/RESULTS_P1_SCALE_AB_2026-09-13.md`).
    >
    > Earlier releases did grow per vacuum pass. Two 2026-09-12 fixes (a merge truncates
    > the free tail it creates; cleanup truncates unconditionally) cut that ~**6×**, and a
    > 2026-09-13 fix removed the rest at small scale by skipping a compaction pass whose
    > free space is not yet reusable — a pass run right after a merge would otherwise
    > relocate live data upward and reclaim nothing, since the pages it just freed are
    > still visible to its own transaction.
    >
    > `fts_vacuum` is still useful for a **one-off** tighter reclaim — it always does the
    > full repack, reaching ~3x smaller than the automatic steady state — so it is worth
    > running once after a large initial build or a mass delete. It is not required to
    > prevent growth. Measurements in
    > `bench/DIAG_WORKER_FRAGMENTATION.md`.
    >
    > **Incremental INSERTs can grow the file far beyond the settled index size, if your
    > documents are large.** A pending document is stored **verbatim**, and one that does
    > not fit in an 8 KB page is indexed immediately as its own **one-document segment**.
    > On a Wikipedia corpus 33% of documents exceed that threshold, and inserting 200k
    > rows into a settled 792 MB / 1M-doc index grew the file to **32 GB before any merge
    > ran**; `fts_merge` added only ~7% on top, and `fts_vacuum` then returned it to
    > 971 MB. Measured at two scales (`bench/RESULTS_C2_INGEST_2026-09-11.md`).
    >
    > This is corpus-dependent, not a general rule: it scales with the *fraction of your
    > documents larger than a page*, so a corpus of short documents will not see it.
    > If you bulk-INSERT large documents, merge and `fts_vacuum` periodically rather than
    > accumulating, and provision headroom accordingly.  Compaction rewrites the live data before freeing
    the old copy (write-before-free, for crash safety), so it transiently needs
    free disk space of roughly the live index size -- like VACUUM FULL / CLUSTER
    / pg_repack.  It is interruptible: pg_cancel_backend and statement_timeout
    stop it promptly, and a cancelled (or out-of-disk) run leaves the index
    valid and correct, just not fully compacted.
  * Ranked (<=>/fts_search) results include pending documents and modifier
    matches through an exact heap fallback. Plain merged queries keep WAND.
    Ranking still scores literal query terms: expansion-only matches can score
    zero. Equal scores use TID order, keeping pagination stable.

Vendored dependencies
---------------------

  * sparsemap v5.3.0 (contrib/pg_fts/vendor/), a compressed-bitmap library used
    for the trigram posting sets and per-segment livedocs tombstones.  All its
    public symbols are namespaced to __pg_bm25_* (via SPARSEMAP_PREFIX in
    vendor/sm.c and the pg_fts_sm.h wrapper), so a second copy loaded by another
    extension in the same backend cannot cause dynamic-linker symbol collisions.

Backward compatibility
-----------------------

tsvector, tsquery, @@, ts_rank and the GIN/GiST opclasses are untouched;
pg_fts is purely additive and opt-in.

New `tsquery` casts preserve exact phrase gaps. Existing stored ordered-query
values retain their historical maximum-gap interpretation. Text saved by an
older lossy serializer cannot recover a distance that was already discarded.

Documentation
-------------

User-facing reference documentation is in doc/pg_fts.sgml (rendered in
the "Additional Supplied Modules" appendix as "pg_fts").  This README is the
developer/design overview; doc/CAPABILITIES.md is the production-readiness /
feature matrix (index-AM capability flags, concurrency, replication, and an
honest comparison to tsvector/GIN and ParadeDB pg_search).

Testing
-------

  * sql/pg_fts.sql + expected/pg_fts.out -- the functional regression suite
    (types, query language, the bm25 index, ranking, maintenance, and the
    MVCC/tombstone/oversized-doc correctness edges).
  * sql/legal_proximity.sql -- an independent occurrence-span oracle, including
    nested proximity, exact phrases, expansions, stopwords and query roundtrips.
  * test/query_binary.py -- 46 valid/malformed binary-query checks; run only in
    a disposable server (`pg_virtualenv python3 test/query_binary.py --local`).
  * specs/bm25_concurrency.spec, specs/bm25_cic.spec -- isolation tests: MVCC
    snapshot stability, pending-list visibility, VACUUM/merge invisibility to
    an open scan, delete+reuse tombstone correctness, and CREATE/REINDEX INDEX
    CONCURRENTLY.
  * t/001_crash_recovery.pl -- an immediate crash + WAL replay reproduces exact
    query answers (GenericXLog crash-safety).
  * t/002_replication.pl -- the index replicates to a streaming standby with
    identical results, including tombstoned deletes.
  * bench/ -- reproducible large-scale benchmarks vs tsvector/GIN and pg_search
    (see bench/RESULTS_*.md).

Run with: make installcheck (REGRESS + ISOLATION + TAP_TESTS), or under meson
meson test pg_fts/... (TAP tests require -Dtap_tests=enabled and the IPC::Run
Perl module).
