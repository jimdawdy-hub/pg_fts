/*
 * pg_fts_shdoclen.c -- one shared copy per server of each segment's resident
 * doclen slot array (1.10.0, ROADMAP I6).  #included into pg_fts_am.c, like
 * pg_fts_am_scan.c, so it can use that file's statics.
 *
 * Why
 * ---
 * C1 (1.9.0) made a document's length two array reads by decoding each
 * segment's doclen sidecar into a slot array per BACKEND.  At 2.19M documents a
 * copy is ~4.8 MB, so 64 backends held ~310 MB of identical bytes and their
 * working sets competed for the last-level cache: rare-term throughput fell
 * from 12.7k to 8.8k tps between 16 and 64 clients, all of the extra cost in
 * bm25_doclen_cursor_lookup (bench/PLAN_I6_SHARED_DOCLEN_2026-10-06.md).  Here
 * the first backend to need a segment's array publishes it in dynamic shared
 * memory and every other backend maps the same pages.
 *
 * Visibility
 * ----------
 * Backends with different snapshots can share one copy because the array is a
 * function of the SEGMENT only:
 *   - a segment's sidecar is written once, when the segment is created (build
 *     flush, pending flush, merge, vacuum rewrite), and never modified in
 *     place; it is freed only when the segment is dropped;
 *   - MVCC never consults it.  What a backend may see is decided by the
 *     segment's tombstones and by the heap visibility check after ranking; a
 *     docid's length is the same for every reader;
 *   - a heap TID that VACUUM frees and a new row reuses lands in a NEW segment
 *     with its own sidecar, so keying by segment keeps the old and new lengths
 *     apart (each is reached only through its own segment's cursors and masked
 *     by that segment's tombstones).
 * What differs between backends is WHICH segments exist: a scan that started
 * before a merge keeps reading the dropped segments.  So a copy is keyed by the
 * segment's identity, never "latest for this index", and every scan holds a
 * reference on each copy it uses until the scan's resource owner is released.
 * A copy is freed only when no scan holds it.
 *
 * Identity: (database, index relfilenumber, doclenstart, ndocs, sumdoclen).
 * relfilenumber changes on REINDEX/TRUNCATE/VACUUM FULL.  A freed segment's
 * doclenstart cannot head a NEW segment while any scan that could hold the old
 * copy is alive: bm25_page_recyclable only reuses a freed page once the freeing
 * xid is behind every snapshot (or under AccessExclusiveLock, when no scan can
 * run) -- measured: with a cursor holding the old copies, 6 new segments all
 * started on fresh blocks.  ndocs and sumdoclen are in the key anyway, as
 * defence in depth: they make a reused doclenstart a different key even if that
 * page-reuse guarantee is ever weakened.  (A test cannot tell the two apart for
 * the same reason: the recycle gate keeps the colliding case from occurring.)
 *
 * Shape
 * -----
 * One fixed-size control struct in a DSM registry segment ("pg_fts_shdoclen";
 * no shared_preload_libraries needed): an LWLock and BM25_SHDOCLEN_SLOTS
 * entries.  Each published array is its own pinned DSM segment.  The private
 * per-backend path is always the fallback: no free slot, dsm_create refusing
 * (too many segments, or ENOSPC in /dev/shm), an attach failing, a header
 * mismatch, or a BUILDING entry owned by another backend -- the query then
 * builds or uses a private copy, as 1.9 did.  A query never fails because of
 * this cache.
 */
#include "storage/dsm.h"
#include "storage/dsm_registry.h"
#include "storage/lwlock.h"
#include "storage/proc.h"
#include "storage/procarray.h"
#include "utils/resowner.h"
#include "funcapi.h"
#include "utils/builtins.h"

#define BM25_SHDOCLEN_SLOTS 256
#define BM25_SHDOCLEN_MAGIC 0x46534443	/* "FSDC" */


typedef struct BM25ShDoclenKey
{
	Oid			dbid;
	RelFileNumber relnumber;
	BlockNumber doclenstart;
	double		ndocs;
	double		sumdoclen;
} BM25ShDoclenKey;

typedef enum
{
	SHDL_FREE = 0,
	SHDL_BUILDING,
	SHDL_READY
} BM25ShDoclenState;

typedef struct BM25ShDoclenSlot
{
	BM25ShDoclenKey key;
	BM25ShDoclenState state;
	int			builder_pid;	/* SHDL_BUILDING: who; a dead pid frees it */
	dsm_handle	handle;			/* SHDL_READY: the pinned payload */
	Size		size;
	int			refcnt;			/* scans currently holding this copy */
	uint64		last_used;		/* control->clock at last acquire (LRU) */
	bool		retired;		/* its segment was freed: unpin at refcnt 0 */
} BM25ShDoclenSlot;

typedef struct BM25ShDoclenControl
{
	LWLock		lock;
	uint64		clock;
	BM25ShDoclenSlot slots[BM25_SHDOCLEN_SLOTS];
} BM25ShDoclenControl;

/* Payload header; base[nblk + 1] and byte[nslot] follow, MAXALIGNed. */
typedef struct BM25ShDoclenPayload
{
	uint32		magic;
	BM25ShDoclenKey key;
	BlockNumber minblk;
	uint32		nblk;
	Size		nslot;
	Size		base_off;
	Size		byte_off;
} BM25ShDoclenPayload;

static BM25ShDoclenControl *shdl_ctl = NULL;

/*
 * Per-backend: copies this backend holds a reference on, released when the
 * owning resource owner (the scan's transaction or portal) is released.  A
 * small list, bounded by segments in use x concurrent scans in this backend.
 */
typedef struct BM25ShDoclenRef
{
	int			slot;
	dsm_handle	handle;
	ResourceOwner owner;
} BM25ShDoclenRef;

static BM25ShDoclenRef *shdl_refs = NULL;
static int	shdl_nrefs = 0;
static int	shdl_caprefs = 0;
static bool shdl_callback_registered = false;

#if PG_VERSION_NUM >= 190000
static void
shdl_init_control(void *ptr, void *arg)
{
	BM25ShDoclenControl *c = (BM25ShDoclenControl *) ptr;

	(void) arg;
	memset(c, 0, sizeof(*c));
	LWLockInitialize(&c->lock, LWLockNewTrancheId("pg_fts_shdoclen"));
}
#else
static void
shdl_init_control(void *ptr)
{
	BM25ShDoclenControl *c = (BM25ShDoclenControl *) ptr;

	memset(c, 0, sizeof(*c));
	LWLockInitialize(&c->lock, LWLockNewTrancheId());
}
#endif

/*
 * Run fn(arg) so that an ERROR inside it is swallowed instead of aborting the
 * caller's query or merge.  An ERROR can leave LWLocks, buffer pins or DSM
 * mappings held, and only abort processing releases those, so the call runs
 * in an internal subtransaction (the PL/pgSQL EXCEPTION pattern), which
 * rolls back cleanly.  Not available in a parallel worker or outside a
 * transaction: there it simply returns false (the caller falls back).
 * Returns true if fn ran without error.
 */
static bool
shdl_try(void (*fn) (void *), void *arg)
{
	MemoryContext mcx = CurrentMemoryContext;
	ResourceOwner owner = CurrentResourceOwner;
	volatile bool ok = false;

	if (!IsTransactionState() || IsInParallelMode())
		return false;
	BeginInternalSubTransaction(NULL);
	MemoryContextSwitchTo(mcx);
	PG_TRY();
	{
		fn(arg);
		ReleaseCurrentSubTransaction();
		MemoryContextSwitchTo(mcx);
		CurrentResourceOwner = owner;
		ok = true;
	}
	PG_CATCH();
	{
		MemoryContextSwitchTo(mcx);
		FlushErrorState();
		RollbackAndReleaseCurrentSubTransaction();
		MemoryContextSwitchTo(mcx);
		CurrentResourceOwner = owner;
	}
	PG_END_TRY();
	return ok;
}

static void
shdl_attach_control(void *arg)
{
	bool		found;
	BM25ShDoclenControl **out = (BM25ShDoclenControl **) arg;

#if PG_VERSION_NUM >= 190000
	*out = GetNamedDSMSegment("pg_fts_shdoclen", sizeof(BM25ShDoclenControl),
							  shdl_init_control, &found, NULL);
#else
	*out = GetNamedDSMSegment("pg_fts_shdoclen", sizeof(BM25ShDoclenControl),
							  shdl_init_control, &found);
	LWLockRegisterTranche((*out)->lock.tranche, "pg_fts_shdoclen");
#endif
}

/*
 * Attach the control struct (once per backend).  NULL if unavailable, never
 * an ERROR: GetNamedDSMSegment can fail (out of DSM slots, or /dev/shm full)
 * and neither a query nor a merge may fail because of this cache.  The
 * registry pins its segment for the life of the server, so a successful
 * attach is permanent; a failed one is not retried in this backend.
 */
static bool shdl_ctl_failed = false;

static BM25ShDoclenControl *
shdl_control(void)
{
	BM25ShDoclenControl *c = NULL;

	if (shdl_ctl != NULL)
		return shdl_ctl;
	if (!IsUnderPostmaster || shdl_ctl_failed)
		return NULL;			/* single-user mode / earlier failure: private copies */
	if (!IsTransactionState() || IsInParallelMode())
		return NULL;			/* cannot attach safely here; try again later
								 * (NOT latched: a parallel merge leader must be
								 * able to attach on its next serial call) */
	if (!shdl_try(shdl_attach_control, &c) || c == NULL)
	{
		shdl_ctl_failed = true;
		return NULL;
	}
	shdl_ctl = c;
	return shdl_ctl;
}

static bool
shdl_key_equal(const BM25ShDoclenKey *a, const BM25ShDoclenKey *b)
{
	return a->dbid == b->dbid && a->relnumber == b->relnumber &&
		a->doclenstart == b->doclenstart && a->ndocs == b->ndocs &&
		a->sumdoclen == b->sumdoclen;
}

/*
 * Free a READY slot (control lock held EXCLUSIVE, refcnt == 0) and return its
 * payload handle, to be passed to dsm_unpin_segment AFTER the control lock is
 * released.  Unpinning takes DynamicSharedMemoryControlLock and can ERROR; doing
 * it outside our lock keeps the lock order one-way (ours is never taken while
 * holding PG's) and means no ERROR can leave our lock held.
 */
static dsm_handle
shdl_free_slot(BM25ShDoclenSlot *s)
{
	dsm_handle	h = s->handle;

	s->state = SHDL_FREE;
	s->retired = false;
	s->handle = DSM_HANDLE_INVALID;
	s->refcnt = 0;
	return h;
}

/*
 * Unpin a payload we just freed.  Each handle reaches here exactly once (the
 * slot was cleared under the lock), so it is pinned; a failure would be a bug,
 * but it is still not worth failing a query or a merge over: the segment then
 * lives until restart.
 */
static void
shdl_do_unpin(void *arg)
{
	dsm_unpin_segment(*(dsm_handle *) arg);
}

static void
shdl_unpin(dsm_handle h)
{
	if (h == DSM_HANDLE_INVALID)
		return;
	if (IsInParallelMode())
	{
		/*
		 * No subtransaction in parallel mode (the leader of a parallel merge
		 * frees its inputs before ExitParallelMode).  dsm_unpin_segment on a
		 * handle we just took out of the table is correct by construction;
		 * call it directly rather than leak the segment.
		 */
		dsm_unpin_segment(h);
		return;
	}
	if (!shdl_try(shdl_do_unpin, &h))
		elog(LOG, "pg_fts: could not unpin shared doclen segment %u", (unsigned) h);
}

/* Drop one reference (control lock NOT held on entry).  The last reader of a
 * retired copy frees it. */
static void
shdl_unref_slot(int slot, dsm_handle handle)
{
	BM25ShDoclenControl *c = shdl_ctl;

	if (c == NULL)
		return;
	LWLockAcquire(&c->lock, LW_EXCLUSIVE);
	if (c->slots[slot].state == SHDL_READY && c->slots[slot].handle == handle &&
		c->slots[slot].refcnt > 0)
		c->slots[slot].refcnt--;
	LWLockRelease(&c->lock);
	/*
	 * No unpin here, even for the last reader of a retired copy: this runs in
	 * resource release, including transaction abort, where dsm_unpin_segment
	 * could ERROR with nothing to catch it.  A retired copy with no readers is
	 * reclaimed by the next shdl_get that needs a slot (retired copies are
	 * evicted first) or the next shdl_retire_segment.
	 */
}

/*
 * A segment is being freed (merge, vacuum rewrite): retire its shared copy.
 * Called before the segment's pages are released, so no NEW scan can find the
 * segment afterwards (the directory no longer lists it); scans that already
 * hold the copy keep it until they finish, and the last one frees it.  Without
 * this, dropped segments' copies would sit in /dev/shm until LRU eviction.
 */
static void
shdl_retire_segment(Relation index, const BM25SegMeta *seg)
{
	BM25ShDoclenControl *c = shdl_ctl;
	int			i,
				nfreed = 0;
	dsm_handle	freed[BM25_SHDOCLEN_SLOTS];

	if (seg->doclenstart == InvalidBlockNumber)
		return;
	if (c == NULL)
		c = shdl_control();		/* a merging backend may never have run a ranked
								 * scan while others hold copies; fail-soft */
	if (c == NULL)
		return;
	LWLockAcquire(&c->lock, LW_EXCLUSIVE);
	for (i = 0; i < BM25_SHDOCLEN_SLOTS; i++)
	{
		BM25ShDoclenSlot *s = &c->slots[i];

		if (s->state == SHDL_READY && s->retired && s->refcnt == 0)
		{
			freed[nfreed++] = shdl_free_slot(s);	/* left by its last reader */
			continue;
		}
		if (s->state == SHDL_FREE || s->key.dbid != MyDatabaseId ||
			s->key.relnumber != index->rd_locator.relNumber ||
			s->key.doclenstart != seg->doclenstart || s->key.ndocs != seg->ndocs ||
			s->key.sumdoclen != seg->sumdoclen)
			continue;
		if (s->state == SHDL_READY && s->refcnt == 0)
			freed[nfreed++] = shdl_free_slot(s);
		else
			s->retired = true;	/* BUILDING, or READY with readers */
	}
	LWLockRelease(&c->lock);
	for (i = 0; i < nfreed; i++)
		shdl_unpin(freed[i]);
}

/*
 * Resource-release callback: drop this backend's references owned by the
 * owner being released (end of the scan's transaction or portal; also runs on
 * ERROR and FATAL exits, so a reference is never leaked by an aborted scan).
 * The mapping itself stays (pinned per backend) for reuse by later queries.
 */
static void
shdl_release_callback(ResourceReleasePhase phase, bool isCommit, bool isTopLevel,
					  void *arg)
{
	int			i,
				keep = 0;

	(void) isCommit;
	(void) isTopLevel;
	(void) arg;
	if (phase != RESOURCE_RELEASE_AFTER_LOCKS || shdl_nrefs == 0)
		return;
	for (i = 0; i < shdl_nrefs; i++)
	{
		if (shdl_refs[i].owner == CurrentResourceOwner)
			shdl_unref_slot(shdl_refs[i].slot, shdl_refs[i].handle);
		else
			shdl_refs[keep++] = shdl_refs[i];
	}
	shdl_nrefs = keep;
}

/* Make room for one more reference (may ERROR; call before taking it). */
static void
shdl_reserve_ref(void)
{
	if (!shdl_callback_registered)
	{
		RegisterResourceReleaseCallback(shdl_release_callback, NULL);
		shdl_callback_registered = true;
	}
	if (shdl_nrefs >= shdl_caprefs)
	{
		int			ncap = Max(shdl_caprefs * 2, 16);

		shdl_refs = (BM25ShDoclenRef *) (shdl_refs
										 ? repalloc(shdl_refs, ncap * sizeof(BM25ShDoclenRef))
										 : MemoryContextAlloc(TopMemoryContext,
															  ncap * sizeof(BM25ShDoclenRef)));
		shdl_caprefs = ncap;
	}
}

/* Record a reference (room was reserved: cannot fail). */
static void
shdl_remember(int slot, dsm_handle handle)
{
	Assert(shdl_nrefs < shdl_caprefs);
	shdl_refs[shdl_nrefs].slot = slot;
	shdl_refs[shdl_nrefs].handle = handle;
	shdl_refs[shdl_nrefs].owner = CurrentResourceOwner;
	shdl_nrefs++;
}

/* Map a payload (reusing this backend's mapping), validated against key. */
static const BM25ShDoclenPayload *
shdl_map(dsm_handle handle, const BM25ShDoclenKey *key)
{
	dsm_segment *seg = dsm_find_mapping(handle);
	const BM25ShDoclenPayload *p;

	if (seg == NULL)
	{
		ResourceOwner save = CurrentResourceOwner;

		/* map outside any resource owner: the mapping lives for the backend */
		CurrentResourceOwner = NULL;
		seg = dsm_attach(handle);
		CurrentResourceOwner = save;
		if (seg == NULL)
			return NULL;
		dsm_pin_mapping(seg);
	}
	p = (const BM25ShDoclenPayload *) dsm_segment_address(seg);
	if (p->magic != BM25_SHDOCLEN_MAGIC || !shdl_key_equal(&p->key, key))
		return NULL;
	return p;
}

/* Is a BUILDING entry abandoned (its builder exited)? */
static bool
shdl_builder_gone(int pid)
{
	return pid == 0 || BackendPidGetProc(pid) == NULL;
}

/*
 * Pick a slot for a new copy (control lock held EXCLUSIVE): a free one, an
 * abandoned BUILDING one, or the least-recently-used READY copy nobody holds
 * (its payload is unpinned here; backends still mapping it keep their own
 * mapping until they detach, and none of them holds a reference).  -1 if
 * every slot is in use.
 */
static int
shdl_claim_slot(BM25ShDoclenControl *c, dsm_handle *evicted)
{
	int			i,
				victim = -1;

	for (i = 0; i < BM25_SHDOCLEN_SLOTS; i++)
	{
		BM25ShDoclenSlot *s = &c->slots[i];

		if (s->state == SHDL_FREE ||
			(s->state == SHDL_BUILDING && shdl_builder_gone(s->builder_pid)))
			return i;
		if (s->state == SHDL_READY && s->refcnt == 0 &&
			(victim < 0 || (s->retired && !c->slots[victim].retired) ||
			 (s->retired == c->slots[victim].retired &&
			  s->last_used < c->slots[victim].last_used)))
			victim = i;
	}
	if (victim >= 0)
		*evicted = shdl_free_slot(&c->slots[victim]);
	return victim;
}

/* Builder gave up (ERROR during the decode): free its BUILDING slot. */
static void
shdl_abandon_slot(int slot)
{
	LWLockAcquire(&shdl_ctl->lock, LW_EXCLUSIVE);
	if (shdl_ctl->slots[slot].state == SHDL_BUILDING &&
		shdl_ctl->slots[slot].builder_pid == MyProcPid)
		shdl_ctl->slots[slot].state = SHDL_FREE;
	LWLockRelease(&shdl_ctl->lock);
}

/* Inputs/outputs of shdl_do_publish (run under shdl_try). */
typedef struct ShdlPublish
{
	BM25ShDoclenKey key;
	bool		built;
	uint32	   *base;
	uint8	   *byte;
	BlockNumber minblk;
	uint32		nblk;
	Size		nslot;
	/* out */
	const BM25ShDoclenPayload *p;
	dsm_handle	handle;
	Size		size;
} ShdlPublish;

/*
 * Copy built arrays into a new DSM segment and pin it.  Runs inside a
 * subtransaction: if anything here raises, the subtransaction's resource owner
 * owns the new segment and its abort destroys it -- the segment is created
 * under that owner and detached from it (dsm_pin_mapping) only once it is
 * pinned, so an ERROR can never leave an unpinned, unowned segment behind.
 */
static void
shdl_do_publish(void *arg)
{
	ShdlPublish *pub = (ShdlPublish *) arg;
	Size		hdr = MAXALIGN(sizeof(BM25ShDoclenPayload));
	Size		bsz = MAXALIGN((Size) (pub->nblk + 1) * sizeof(uint32));
	Size		total = hdr + bsz + MAXALIGN(Max(pub->nslot, 1));
	dsm_segment *dseg;
	BM25ShDoclenPayload *np;

	dseg = dsm_create(total, DSM_CREATE_NULL_IF_MAXSEGMENTS);
	if (dseg == NULL)
		return;					/* out of DSM control slots: no copy */
	np = (BM25ShDoclenPayload *) dsm_segment_address(dseg);
	np->magic = BM25_SHDOCLEN_MAGIC;
	np->key = pub->key;
	np->minblk = pub->minblk;
	np->nblk = pub->nblk;
	np->nslot = pub->nslot;
	np->base_off = hdr;
	np->byte_off = hdr + bsz;
	memcpy((char *) np + np->base_off, pub->base, (Size) (pub->nblk + 1) * sizeof(uint32));
	memcpy((char *) np + np->byte_off, pub->byte, pub->nslot);
	dsm_pin_segment(dseg);		/* survives this backend */
	dsm_pin_mapping(dseg);		/* stays mapped here; no longer owned */
	pub->p = np;
	pub->handle = dsm_segment_handle(dseg);
	pub->size = dsm_segment_map_length(dseg);
}

/*
 * Return the shared copy of one segment's slot arrays, building and
 * publishing it if no backend has yet, or NULL (use the private path).  On
 * success *base / *byte / *minblk / *nblk describe the arrays and the caller's
 * resource owner holds a reference until it is released.
 *
 * build_private is the existing per-backend builder for ONE segment; it
 * returns palloc'd arrays (or false: empty or over budget).
 */
typedef bool (*shdl_build_fn) (Relation index, BlockNumber doclenstart,
							   uint32 **base, uint8 **byte, BlockNumber *minblk,
							   uint32 *nblk, Size *nslot);

/*
 * Kept out of line deliberately (pg_noinline).  shdl_get is the cold half of
 * cursor setup: it runs once per (scan, segment), takes an LWLock, may attach
 * DSM, and on a miss builds and publishes a multi-MB array under a
 * subtransaction (PG_TRY/sigsetjmp).  Its only caller,
 * bm25_doclen_cursor_init, sits in front of the per-posting scoring loops in
 * bm25_topk_candidates_range.  Inlined, this body (and its setjmp, which pins
 * locals to the stack) would grow and reshape that hot function for no gain:
 * the call happens a handful of times per query, against ~10^4 doclen lookups.
 * 1.9.1 measured exactly that kind of code-placement effect costing ~5% on a
 * loop whose own code had not changed (see fts_search_dense1), so the cold
 * path is kept out of the hot function's layout on purpose.
 */
pg_noinline static bool
shdl_get(Relation index, const BM25SegMeta *seg, shdl_build_fn build,
		 const uint32 **base, const uint8 **byte, BlockNumber *minblk, uint32 *nblk)
{
	BM25ShDoclenControl *c;
	BM25ShDoclenKey key;
	const BM25ShDoclenPayload *p = NULL;
	int			slot = -1,
				i;
	dsm_handle	handle = DSM_HANDLE_INVALID;
	dsm_handle	evicted = DSM_HANDLE_INVALID;
	bool		mine = false;

	if (!pg_fts_shared_doclen || seg->doclenstart == InvalidBlockNumber ||
		(c = shdl_control()) == NULL)
		return false;

	/* room for the reference BEFORE taking it: nothing between taking the
	 * refcnt and recording it may fail, or the count would leak */
	shdl_reserve_ref();

	memset(&key, 0, sizeof(key));
	key.dbid = MyDatabaseId;
	key.relnumber = index->rd_locator.relNumber;
	key.doclenstart = seg->doclenstart;
	key.ndocs = seg->ndocs;
	key.sumdoclen = seg->sumdoclen;

	LWLockAcquire(&c->lock, LW_EXCLUSIVE);
	for (i = 0; i < BM25_SHDOCLEN_SLOTS; i++)
		if (c->slots[i].state != SHDL_FREE && !c->slots[i].retired &&
			shdl_key_equal(&c->slots[i].key, &key))
			break;
	if (i < BM25_SHDOCLEN_SLOTS)
	{
		if (c->slots[i].state != SHDL_READY)
		{
			/* another backend is building it: don't wait, go private */
			bool		gone = shdl_builder_gone(c->slots[i].builder_pid);

			if (gone)
				c->slots[i].state = SHDL_FREE;
			LWLockRelease(&c->lock);
			return false;
		}
		slot = i;
		handle = c->slots[i].handle;
		c->slots[i].refcnt++;
		c->slots[i].last_used = ++c->clock;
	}
	else
	{
		slot = shdl_claim_slot(c, &evicted);
		if (slot >= 0)
		{
			c->slots[slot].key = key;
			c->slots[slot].state = SHDL_BUILDING;
			c->slots[slot].builder_pid = MyProcPid;
			c->slots[slot].refcnt = 0;
			c->slots[slot].retired = false;
			mine = true;
		}
	}
	LWLockRelease(&c->lock);
	shdl_unpin(evicted);
	if (slot < 0)
		return false;			/* every slot in use: private path */

	if (!mine)
	{
		p = shdl_map(handle, &key);
		if (p == NULL)
		{
			shdl_unref_slot(slot, handle);
			return false;
		}
		shdl_remember(slot, handle);
	}
	else
	{
		ShdlPublish pub;

		/*
		 * Build privately (the 1.9 code: a cancel during the decode is a
		 * normal ERROR), then publish into a new pinned DSM segment.  The DSM
		 * steps run under shdl_try: dsm_create raises ERROR on ENOSPC in
		 * /dev/shm, and that must cost this query its shared copy, not its
		 * answer.
		 */
		memset(&pub, 0, sizeof(pub));
		pub.key = key;
		PG_TRY();
		{
			pub.built = build(index, seg->doclenstart, &pub.base, &pub.byte,
							  &pub.minblk, &pub.nblk, &pub.nslot);
		}
		PG_CATCH();
		{
			shdl_abandon_slot(slot);
			PG_RE_THROW();
		}
		PG_END_TRY();
		if (pub.built && !shdl_try(shdl_do_publish, &pub))
			pub.p = NULL;		/* no DSM: the arrays are discarded below */
		if (pub.base)
			pfree(pub.base);
		if (pub.byte)
			pfree(pub.byte);
		p = pub.p;
		handle = pub.handle;

		LWLockAcquire(&c->lock, LW_EXCLUSIVE);
		if (p != NULL)
		{
			/* READY even if retired meanwhile (the segment was dropped while we
			 * built): this scan holds the only reference, and the copy is
			 * reclaimed once it is released (shdl_claim_slot / retire sweep) */
			c->slots[slot].state = SHDL_READY;
			c->slots[slot].handle = handle;
			c->slots[slot].size = pub.size;
			c->slots[slot].refcnt = 1;
			c->slots[slot].last_used = ++c->clock;
		}
		else
			c->slots[slot].state = SHDL_FREE;	/* empty, over budget, or no DSM */
		LWLockRelease(&c->lock);
		if (p == NULL)
			return false;
		shdl_remember(slot, handle);
	}

	*base = (const uint32 *) ((const char *) p + p->base_off);
	*byte = (const uint8 *) ((const char *) p + p->byte_off);
	*minblk = p->minblk;
	*nblk = p->nblk;
	return true;
}

/*
 * fts_shared_doclen_stats() -> one row per occupied slot of the shared table:
 * (dbid oid, relfilenumber oid, doclenstart bigint, ndocs float8, state text,
 *  refcnt int, retired bool, bytes bigint).  For monitoring and tests; shows
 * what this server has published and who holds it.
 */
PG_FUNCTION_INFO_V1(fts_shared_doclen_stats);

Datum
fts_shared_doclen_stats(PG_FUNCTION_ARGS)
{
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	BM25ShDoclenControl *c;
	BM25ShDoclenSlot snap[BM25_SHDOCLEN_SLOTS];
	int			i;

	InitMaterializedSRF(fcinfo, 0);
	c = shdl_control();
	if (c == NULL)
		PG_RETURN_VOID();
	LWLockAcquire(&c->lock, LW_SHARED);
	memcpy(snap, c->slots, sizeof(snap));
	LWLockRelease(&c->lock);
	for (i = 0; i < BM25_SHDOCLEN_SLOTS; i++)
	{
		Datum		v[8];
		bool		n[8] = {0};

		if (snap[i].state == SHDL_FREE)
			continue;
		v[0] = ObjectIdGetDatum(snap[i].key.dbid);
		v[1] = ObjectIdGetDatum((Oid) snap[i].key.relnumber);
		v[2] = Int64GetDatum((int64) snap[i].key.doclenstart);
		v[3] = Float8GetDatum(snap[i].key.ndocs);
		v[4] = CStringGetTextDatum(snap[i].state == SHDL_READY ? "ready" : "building");
		v[5] = Int32GetDatum(snap[i].refcnt);
		v[6] = BoolGetDatum(snap[i].retired);
		v[7] = Int64GetDatum((int64) snap[i].size);
		tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc, v, n);
	}
	PG_RETURN_VOID();
}
