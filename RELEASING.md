# Releasing pg_fts

Releases are **tag-triggered**. The version lives in `META.json` and
`pg_fts.control` (and the `pg_fts--<version>.sql` filename); the git tag is
`v<version>` (e.g. `v0.1.0`).

## Cut a release

0. **Gate first, every time.** All of these green before anything else:
   `nix build .#checks.x86_64-linux.{installcheck-pg17,installcheck-pg18,tap-pg17,tap-pg18}`,
   `bash ci/check-alloc.sh`, `make check-ascii`, `bash test/fuzz/run.sh` (prints
   `== ALL CLEAN ==`), and the SGML re-rendered (`doc/build-html.sh`) with no
   undefined-entity errors.  Local green means nothing for the delete/merge path:
   any release touching tombstones, merge or vacuum also needs an at-scale run on
   EC2 (`bench/` harnesses; the P0 shipped through a green local gate twice).
1. Bump the version everywhere it appears and land it on `main`:
   - `pg_fts.control` `default_version`
   - `META.json` (`version` in two places; leave `meta-spec.version` = 1.0.0)
   - `git mv pg_fts--<old>.sql pg_fts--<new>.sql` and update `Makefile`
     `DATA`, `meson.build`, `flake.nix`, and the `CREATE EXTENSION ... VERSION`
     line in `sql/pg_fts.sql` + `expected/pg_fts.out`.  **The `git mv` is the
     point: the old base script must not remain tracked.** 31 dead base scripts
     accumulated in the root before this was written down.
   - add the upgrade edge `pg_fts--<old>--<new>.sql` and `git add` it (new files
     are invisible to the nix build until tracked)
   - verify the version graph: every prior version must reach `<new>` through
     the edge files (a 10-line Python walk; see any recent release commit)
   - add a `CHANGELOG.md` entry.  Anything you previously published that this
     release shows to be wrong goes under a **"Retracted"** heading, stated
     plainly.  The project's credibility rests on that heading existing.
   - **if `bench/BENCHMARK_SUMMARY.md` changed, the README comparison paragraph
     changes in the same commit.**  It drifted once to claim a lead the table
     contradicts.
2. **If the release changes the on-disk index format, provide an in-place
   upgrade path (see "On-disk format changes" below) — do NOT ship a
   format change that forces a REINDEX unless it is genuinely impossible to
   migrate in place.**  1.5.0 (v3 -> v4) is the worked precedent: an optional
   per-segment pointer, dual-read of old segments, convergence as merges run.
3. **If the release adds a TAP test, it goes in two places**: `flake.nix`
   `PROVE_TESTS` and `.github/workflows/ci.yml`.  `t/010` (the P1 regression
   test) ran only in the nix gate for a week before this was written down.
4. **Known issues ship as known issues** -- a CHANGELOG entry with a reproduction
   and the measured size of the problem -- never silently carried, and never
   "fixed" by a design change rushed into a correctness release.
5. Tag, then push **main before the tag, and to GitHub directly -- never via the
   mirror**:
   ```sh
   git tag -a vX.Y.Z -m "pg_fts X.Y.Z -- <summary>"
   git push origin main   && git push github main      # commit exists everywhere first
   git push origin vX.Y.Z && git push github vX.Y.Z    # then the tag that points at it
   git ls-remote github 'refs/tags/vX.Y.Z^{}'          # MUST print the release commit
   ```
   (`github` = `git@github.com:gburd/pg_fts.git`; add it with `git remote add`.)

   **Why the mirror is off the release path (2026-09-27, twice in one day).** The
   Codeberg->GitHub mirror is not a race that resolves in seconds; on v1.8.5 it pushed
   the tag and then stalled on `main` for over two hours. GitHub therefore had a
   `v1.8.5` tag pointing at v1.8.4's commit, the release job ran **that commit's
   workflow** (which predates the checkout guard, so the guard could not fire), built
   `pg_fts-1.8.4.zip`, and only a filename mismatch stopped it publishing 1.8.4's code
   as 1.8.5. **No in-workflow check can defend against this**, because a stale tag
   selects a stale workflow. Pushing `main` then the tag directly makes "GitHub has
   the commit before it sees the tag" true by construction. The in-workflow guard
   stays as defence in depth.

## Storage / WAL / crash-recovery review checklist (per release)

pg_fts is a single-author project; this checklist is the standing "second set of
eyes" for any change that touches the storage, WAL, crash-recovery, page-recycle,
or concurrency paths.  Work through it before tagging a release that modifies
any of `pg_fts_am.c` / `pg_fts_am_scan.c` / `pg_fts_customscan.c` /
`pg_fts_migrate.c` or the on-disk structures in `pg_fts_am.h` / `pg_fts_for.h`.
A change confined to analysis/query-parse/ranking value code (no page or catalog
effect) can skip it.

- [ ] **All page mutations go through `GenericXLog`.** No new
      `log_newpage`/`XLogInsert`/`smgrwrite`/direct buffer flush; no custom
      resource manager.  (`grep -nE 'log_newpage|XLogInsert|smgrwrite' *.c` is
      empty.)
- [ ] **Atomic publish point preserved.** A built/flushed/merged segment is
      written while invisible and published by a single metapage record; a
      crash leaves the old state or the new state, never a torn structure.
- [ ] **Standby-safe page recycling.** A freed page is not reused until its
      free-XID horizon has passed (`bm25_page_recyclable`); any new recycle site
      honors the gate, and any gate bypass is justified by an exclusive lock
      (`CheckRelationLockedByMe(..., AccessExclusiveLock)`).
- [ ] **No write path runs during recovery.** New SQL-callable functions that
      write WAL call the recovery guard (`RecoveryInProgress()` &rarr; error);
      AM callbacks are exempt (core never invokes them in recovery).
- [ ] **Privilege check on any function that opens an index by OID or exposes
      indexed content.** Maintenance functions require index ownership; content
      functions are revoked from `PUBLIC` in the install + upgrade SQL.
- [ ] **Bounded miss, never crash.** Any new decode of page-derived bytes
      bounds-checks lengths against the page before trusting them, and degrades
      to a bounded wrong-count rather than an out-of-bounds read; a
      corresponding fuzz/property case exists.
- [ ] **Cancellation.** Every new long loop polls `CHECK_FOR_INTERRUPTS()` with
      no lock held across the yield.
- [ ] **Corpus statistics count only live documents** (build callback gates
      `ndocs`/`sumdoclen` on `tupleIsAlive`; merge accumulation uses
      `ndocs - ndeleted`).
- [ ] **On-disk format change?** If yes, bump `BM25MetaPageData.version`, read
      both old and new formats, ship as a MINOR release with a real old-format
      TAP test, and add the upgrade path (see below).  A forced REINDEX is a
      release blocker.
- [ ] **Full gate green on the supported majors (17, 18):** `installcheck`,
      isolation, TAP (incl. crash-recovery `t/001`, replication `t/002`,
      pinned-horizon `t/009`), `make check-ascii`, `make check-alloc`, the fuzz
      harness (`== ALL CLEAN ==`), and coverage &ge; 90% of pg_fts-own sources.
- [ ] **Concurrency/traversal-core change?** Get a second review (a reviewer
      sub-agent or a human) and, for anything scale-sensitive, an A/B on real
      hardware before shipping &mdash; do not ship a plausible-but-unproven
      concurrency fix (a crash is worse than the bug it claims to fix).

## On-disk format changes (MANDATORY upgrade path)

**Rule: any release that changes the on-disk index format MUST ship an upgrade
path that preserves existing indexes built by the immediately-preceding minor
version. A format change that forces users to `REINDEX` (drop + rebuild) is not
acceptable** — for a large index (the field's is ~84 GB, ~48 min to build) a
forced rebuild is an outage and a data-availability risk (needs a second full
copy on disk). Treat "users must REINDEX" as a release blocker, not a footnote.

What counts as a format change: anything that alters the bytes a *previously
built* index has on disk or how they are interpreted — the metapage struct
(`BM25MetaPageData`), the segment descriptor (`BM25SegMeta`), the block header
(`BM25BlockHdr`), the dictionary entry (`BM25DictEntry`), the pending-item
layout, the FOR/varint posting encoding, the sparsemap serialization
(`vendor/sm`), or the meaning of any persisted field. A change that only adds a
new C function, fixes a query/merge/build code path, or appends a field AFTER
the fixed `segs[]` array (which older readers ignore) is **not** a format
change and needs only the usual no-op `--OLD--NEW.sql`.

When a format change is unavoidable, do ALL of:

1. **Bump `version` in the metapage** (`BM25MetaPageData.version`, currently
   read by `bm25_check_meta`) so the code can tell old from new on sight.
2. **Read both formats.** Every reader/writer path must detect the metapage
   version and handle the old layout — either by interpreting the old bytes
   directly, or by transparently migrating a page/segment on first write. An
   old index opened by the new code must return correct results with NO manual
   step.
3. **Migrate lazily and in place** where possible (upgrade a segment/page when
   it is next merged/vacuumed), so the cost is amortized and no second full
   copy is needed. `fts_merge()`/`VACUUM` should converge an old-format index
   to the new format over time.
4. **Make it a minor release** (`X.Y+1.0`), and say plainly in the CHANGELOG
   and release notes: which format changed, that existing indexes keep working
   without a REINDEX, and (if applicable) that running `fts_merge()`/`VACUUM`
   completes the migration.
5. **Test the upgrade with a real old-format index**: build an index on the
   previous release, `ALTER EXTENSION pg_fts UPDATE`, load the new `.so`, and
   assert queries still return correct results and that a merge/vacuum migrates
   it cleanly. Add this as a TAP test so it is gated, not a one-off check.

The extension-SQL upgrade script (`pg_fts--OLD--NEW.sql`) only migrates SQL
objects; on-disk index bytes are migrated by the C code per the above, never by
the SQL script. A C-only format change therefore still ships a no-op
`--OLD--NEW.sql` PLUS the version-aware read/migrate code.

## What the tag triggers

- **GitHub** (`.github/workflows/release.yml`), the only pipeline that runs:
  build + `installcheck`, `make dist`, a GitHub Release with `pg_fts-X.Y.Z.zip`,
  the **PGXN upload**, and the postgresql.org announcement (`ci/announce.sh`).
  PGXN rejects a duplicate version, so a re-run of a published tag reports 409
  and continues.

**Codeberg is the origin remote and mirror source, not a CI or release host.**
It provides no shared Actions runners, so the `.forgejo/` workflows that used to
live here queued 115 runs from v0.1.0 to v1.8.2 and executed none of them.
Because PGXN publishing had been placed only there, **PGXN was frozen at 0.2.0
for 45 releases** and the README pointed users at it.  The workflows were
deleted on 2026-09-17 and every channel moved to GitHub.  If a Codeberg release
page is ever wanted, register a self-hosted Forgejo runner first and confirm a
run reaches `started_at` before trusting it with anything.

The release artifact is a **source distribution** (`make dist` → a PGXN-layout
`pg_fts-X.Y.Z.zip` via `git archive`), not a compiled binary: a PGXS C
extension is built from source per PostgreSQL major / OS / arch by the user
(`make PG_CONFIG=...`). `.gitattributes export-ignore` keeps CI/dev/bench files
out of the zip.

## Required CI secrets

| Secret | Where | Purpose |
|--------|-------|---------|
| `PGXN_USER` / `PGXN_PASSWORD` | GitHub repo secrets | PGXN Manager upload (skipped with a warning if unset) |
| `PGORG_USER` / `PGORG_PASSWORD` | GitHub repo secrets | postgresql.org news submission (skipped if unset) |

`PGXN_USER`/`PGXN_PASSWORD` are set on the GitHub repo and verified working
(2026-09-17: `v1.8.2` re-published via `workflow_dispatch`, HTTP 303, PGXN now
at 1.8.2).  `PGORG_*` is not set; the announce step skips cleanly without it.

**The mirror race, and why the workflow checks the checkout.** Codeberg mirrors `main`
and a new tag to GitHub as separate ref updates, and GitHub's tag-push event can fire
while `refs/tags/vX.Y.Z` there still resolves to the *previous* release's commit. On
v1.8.4 the job checked out 1.8.3, built `pg_fts-1.8.3.zip`, and failed only because the
filename did not match the tag -- had it matched, 1.8.3's code would have been published
as 1.8.4. The workflow now refetches the tag until the checked-out `META.json` version
equals the tag's version (bounded, 2 min) and **refuses to build** otherwise. The mirror also
**double-fires** the tag-push event -- once at the racy resolution, once when it corrects
the tag -- so a failed first run is normally followed by a successful second one within
~10 minutes, and a manual re-dispatch then gets a benign `409 already published`. Read
each run's own log; do not grep across runs. If a release fails at "Verify checkout
matches the tag" and no second run appears, use the manual trigger below; do not touch
the tag. Confirm on `api.pgxn.org` and diff the PGXN zip against the GitHub asset -- the
1.8.4 artifacts were verified byte-identical (`sha256 dd836069...`).

**If GitHub already has a WRONG tag** (points at a commit whose `META.json` is not the
tag's version): this is the one case where deleting and re-pushing a tag is correct --
it never pointed at what it claimed, and the annotated object on Codeberg is
authoritative. Delete the empty Release the failed run created, then
`git push github :refs/tags/vX.Y.Z && git push github vX.Y.Z`, then verify with
`ls-remote ... '^{}'`. Done for v1.8.5; PGXN then received the right bytes
(sha256 verified identical to the GitHub asset).

**To re-publish an existing tag** (e.g. after a workflow fix), do not re-tag --
that rewrites published history.  Use the manual trigger:

    gh workflow run Release --repo gburd/pg_fts -f tag=vX.Y.Z

It checks out that tag and runs the *current* workflow definition against it.
`gh run rerun` would not: it re-executes the definition the tag was pushed under.

## Dependency-update automation

- **GitHub:** Dependabot (`.github/dependabot.yml`) opens weekly PRs bumping the
  GitHub Actions pins.
- `renovate.json` remains for anyone who runs Renovate against the repo; with
  the `.forgejo/` workflows gone it has nothing Codeberg-specific left to pin.

## Manual PGXN upload (fallback)

If CI can't publish, upload by hand at <https://manager.pgxn.org/upload> (log
in, attach the `make dist` zip), or:

```sh
make dist PG_CONFIG=$(command -v pg_config)
curl --user "$PGXN_USER:$PGXN_PASSWORD" \
  -F "archive=@pg_fts-X.Y.Z.zip;type=application/zip" \
  https://manager.pgxn.org/upload
```
