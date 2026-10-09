# I6: rare-term throughput falls with client count -- cause identified; fix designed, deferred (2026-10-06)

## Measured cause

Rare-term ranked tps falls 12.7k -> 8.8-8.9k from 16 to 64 clients on 1.9.1 (8.6k on 1.9.0).
Evidence (bench/data_i6_2026-10-06/):

- Differential profile, c16 vs c64, cost per transaction by symbol (i6_diff.sh,
  differential_profile.txt): the whole growth (+40.6 of +40.9 units) is
  `bm25_doclen_cursor_lookup`, 13.5 -> 54.1. No other symbol moves more than 1 unit.
  CPU is 98-99% user at both client counts; no lock waits.
- A rare-term query does ~10,245 doclen lookups (uprobe, 512,262 over 50 queries).
- `pg_fts.doclen_cache_mb = 0` (no slot array) is flat (1,883 / 1,880 tps): the drop is
  a property of the C1 slot array, not of the scan.
- Each backend builds a PRIVATE copy of the slot array (~4.8 MB for 2.19M docs over 501k
  heap blocks). 64 backends hold 64 copies, ~310 MB, against a 54 MB L3. pgbench runs
  the same query in every client, so every backend touches the same ~20k lines of its
  own copy: ~1.3 MB per backend, ~84 MB at 64 clients.
- Synthetic model (l3test2.c, the same two-read lookup at the same sizes), 16/32/64
  processes: private copies 142k/131k/128k qps; one shared copy 224k/225k/228k.
- Prototype (i6_proto_DIAGNOSTIC_ONLY.py, never committed to the code: the chunk
  published to /dev/shm and mmapped by every backend): 12.3k/11.1k/8.8k tps private vs
  12.3k/12.5k/12.6k shared, same binary otherwise.
- Ruled out: THP (no change), pgbench thread count, slot-array rebuilds (once per
  backend), lock waits.
- r6id exposes no PMU, so the cache-miss rate itself is unmeasured; the A/B is the proof.

## Fix (designed, not implemented)

One copy of each index's slot arrays per server, in dynamic shared memory, built by the
first backend that needs them at a directory generation; every other backend attaches
read-only. This also removes the per-backend rebuild after every generation bump (the
28 ms decode each backend pays today).

Constraints found while designing it, each of which a naive version gets wrong:

- **DSM control slots.** `GetNamedDSMSegment` creates and pins one DSM segment per
  NAME until restart. A name per (index, generation) leaks a control slot per flush and
  eventually breaks parallel query. Use ONE registry entry for the extension: a fixed
  table of entries {dboid, index oid, relfilenumber, generation, handle, size} under a
  spinlock; a full table falls back to private copies.
- **Keying.** The metapage generation restarts after REINDEX, so the key must include
  the relfilenumber; the payload carries the same key and the per-segment slot layout
  (minblk, nblk, offsets, keyed by doclenstart), validated on attach.
- **Lifetime.** The publisher of a newer generation unpins the old payload exactly once
  (swapped out under the spinlock). A backend detaches its previous mapping for that
  index when it attaches the new one (`dsm_find_mapping` first, so a relcache rebuild
  never attaches twice). An idle backend keeps an old payload mapped until it next runs
  a ranked query on that index or exits -- the same footprint as today's private copy,
  but in /dev/shm.
- **Errors.** `dsm_create(..., DSM_CREATE_NULL_IF_MAXSEGMENTS)` returns NULL on slot
  exhaustion (fall back to private), but ENOSPC in /dev/shm raises the same ERROR
  parallel query raises. Either accept that with a GUC off-switch, or build in a
  subtransaction. Container /dev/shm defaults (64 MB) make this a real case.
- **PG19** changes `GetNamedDSMSegment` (`init_callback(ptr, arg)`, extra `arg`).
- **Gate.** doclen_slots-style equality (shared == private == cursor, every doc) plus a
  TAP test with several backends racing generation bumps (flush/merge/vacuum) and
  REINDEX, and the 16/32/64 A/B.

Deferred because it is a design change (AGENTS.md rule 30), not because it is unclear.
At 64 clients pg_fts 1.9.1 (8.8-8.9k tps) is still ahead of pg_textsearch 1.4.0 (8.2k).
