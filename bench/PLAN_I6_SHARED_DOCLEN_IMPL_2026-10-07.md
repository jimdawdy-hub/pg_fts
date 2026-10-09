# I6 fix: one shared copy of the doclen slot arrays per server (2026-10-07)

Supersedes the design section of `PLAN_I6_SHARED_DOCLEN_2026-10-06.md` (the diagnosis
there stands).

## What must stay correct: visibility

The slot array is a decoded copy of ONE segment's doclen sidecar: for each docid in that
segment, the quantized length of the document stored there. Two backends with different
snapshots must keep getting the same answer they get today. They do:

1. **A segment's sidecar is immutable.** It is written once, when the segment is created
   (build flush, pending flush, or merge), and freed only when the segment is dropped. No
   code path modifies a sidecar page in place (`bm25_write_doclen_sidecar` is the only
   writer; `bm25_free_chain` the only other toucher). Deletes do not touch it: they write
   the segment's *tombstone* map.
2. **MVCC never consults the doclen.** Which documents a backend may see is decided by the
   tombstones (per segment, read at scan start) and by the heap visibility check after
   ranking (`bm25_topk_visible`). The doclen of a docid is a function of (segment, docid)
   only, the same for every reader. A backend that cannot see a document never looks
   its length up, or looks it up and then discards the row at the heap check, exactly as
   with a private copy.
3. **Docid reuse is per segment.** A heap TID freed by VACUUM and reused by a new row lands
   in a NEW segment (with its own sidecar and its own length); the old segment's sidecar
   still holds the old row's length, consulted only through the old segment's cursors and
   masked by that segment's tombstones. Keying the shared array by segment (not by docid
   alone) preserves this.
4. **What differs between backends is WHICH SEGMENTS exist**, i.e. the directory
   generation. A long-running scan holds a snapshot of the old directory and may still be
   reading segments a merge has since dropped. So the shared copy is keyed by the
   segment's identity and a backend must use the copy that matches the segment IT is
   reading -- never "the latest". Each scan pins the copies it uses until it ends.

So the shared array needs no per-transaction variant. It needs: content-addressing by
segment identity, refcounted lifetime so a copy outlives every scan that uses it, and
no reuse of an identity for different content.

## Identity of a segment's sidecar

`(database oid, index relfilenumber, doclenstart block, segment ndocs, segment sumdoclen)`.

- relfilenumber changes on REINDEX / TRUNCATE / VACUUM FULL, so a rebuilt index never
  matches a stale copy.
- doclenstart alone is not enough: after a merge frees a segment, its sidecar pages can be
  recycled into a NEW segment's sidecar starting at the same block. ndocs and sumdoclen
  (exact, from the segment's metapage entry) make an accidental match require a different
  segment with the same first block, the same doc count and the same total length.
- And the copy is validated on attach against the reader's own `BM25SegMeta` (all five
  fields) plus the block range it decoded; a mismatch falls back to the private path.

The metapage generation is deliberately NOT in the key: an unrelated flush bumps the
generation without changing an existing segment's sidecar, and keying by segment means
those copies survive (this also removes the per-backend 28 ms rebuild after every flush).

## Shared memory layout

One DSM registry entry for the extension (`GetNamedDSMSegment("pg_fts_doclen", ...)`,
fixed size, created on first use; no `shared_preload_libraries` needed). It holds:

- an LWLock (tranche from `LWLockNewTrancheId` / registered per backend), and
- a fixed table of `BM25_SHDOCLEN_SLOTS` (256) entries:
  `{key, dsm_handle, size, refcnt, last_used, state}`.

Each payload lives in its own DSM segment created with `DSM_CREATE_NULL_IF_MAXSEGMENTS`
and pinned (`dsm_pin_segment`) so it survives its creator. Content: header (key, nslots,
nblk, minblk, checksum of the arrays) + `base[]` + `byte[]`, the bytes the private builder
produces.

## Protocol

Lookup for one segment, at the point the private builder would decode it:

1. Take the table lock SHARED, find the key. If READY: increment refcnt (under the lock
   in EXCLUSIVE; refcnt changes only under EXCLUSIVE), remember the handle, release.
   Attach with `dsm_find_mapping` then `dsm_attach`; validate header == key. Use it.
2. If absent: take EXCLUSIVE, re-check, claim a free slot (or evict an entry with refcnt
   0, least recently used), mark it BUILDING with our pid, release. Build the arrays
   privately (exactly today's code), create + fill + pin the DSM payload, then EXCLUSIVE:
   set handle, READY, refcnt 1. Concurrent backends that find BUILDING simply use their
   own private copy for this scan (no waiting, no thundering herd; at most a handful of
   duplicate builds during the first seconds).
3. On any failure (no free slot, `dsm_create` returned NULL, attach failed, header
   mismatch, an ERROR inside the build) the slot is released and the backend uses its
   private copy. A query never errors because of the shared cache.

Release: at the end of the scan (resource-owner callback, so it runs on ERROR too) each
pinned entry's refcnt is decremented. An entry is only evicted, and its payload unpinned,
when refcnt == 0 -- so no scan can lose a copy it is reading. Mappings stay attached per
backend (`dsm_pin_mapping`) for reuse across queries; a backend detaches a mapping whose
entry has been evicted when it next looks.

Eviction happens when a builder needs a slot and all are taken: least recently used with
refcnt 0. Dropped segments' copies age out the same way; nothing has to be told about a
merge.

## Failure modes considered

- **ENOSPC in /dev/shm**: `dsm_create` raises ERROR (posix_fallocate). Wrapped: the build
  step runs under PG_TRY; on ERROR we release the slot, mark it free, and re-throw only if
  the error was not ours (we catch only during dsm_create via a flag). Implementation
  uses a subtransaction-free pattern: we pre-check `dsm_create(size,
  DSM_CREATE_NULL_IF_MAXSEGMENTS)` and keep the PG_TRY around it; FlushErrorState and
  fall back. (Same as how other extensions treat DSM as optional.)
- **Backend killed mid-build**: the slot stays BUILDING with a dead pid. A builder that
  needs a slot treats BUILDING entries whose pid is not alive (`kill(pid, 0)` / ProcArray)
  as free.
- **Crash restart**: all DSM is reset; the registry is recreated empty.
- **PG19**: `GetNamedDSMSegment` gained an `arg` parameter and the init callback takes
  `(ptr, arg)`. Wrapped behind `PG_VERSION_NUM >= 190000`.
- **Parallel workers**: workers are separate backends; they use the shared copy like any
  other backend (no new handle passing needed).
- **Hot standby**: read-only, same code; DSM works on a standby.

## GUC

`pg_fts.shared_doclen` (bool, default on, PGC_SUSET). Off = 1.9.1 private copies.
`pg_fts.doclen_cache_mb` keeps its meaning as the per-index budget for building a copy.

## Tests

- `doclen_slots` extended: scores with shared on == shared off == cursor path (0 MB),
  every doc, after deletes / merges / new segments, and after REINDEX (relfilenumber).
- TAP `t/011_shared_doclen.pl`: several sessions; one holds an open REPEATABLE READ scan
  cursor on the old directory while another merges (segment dropped, pages recycled into a
  new segment's sidecar); the old cursor finishes with correct scores, the new session
  gets the new segment's lengths; refcnt returns to 0; no leaked DSM segments
  (`pg_dynamic_shared_memory` / pg_shmem_allocations); `pg_terminate_backend` of a builder
  mid-build leaves a usable cache.
- A/B on aarch64 Debian (Graviton): 16/32/64 clients, shared on vs off, 2 passes.
