/*-------------------------------------------------------------------------
 *
 * pg_fts_am.c
 *		The "bm25" index access method for pg_fts.
 *
 * A segmented inverted index over an ftsdoc column, answering the @@@ operator
 * (boolean / phrase / NEAR / prefix / fuzzy / regex) and the <=> ordering
 * operator (block-max WAND / MaxScore top-k), plus a fast fts_count() path.
 * It maintains the corpus statistics BM25 needs (document count N, sum of
 * document lengths, per-term document frequency) and scores index-only.
 *
 * On-disk layout (the Lucene/Tantivy-style segmented design):
 *
 *	 block 0            metapage: N, sum(doclen), a directory of segments, and
 *							the pending write buffer pointers
 *	 per segment        a term dictionary (+ sparse block index), FOR-packed
 *							128-doc posting blocks with per-block max-tf/min-|D|
 *							impacts, a trigram index, and a livedocs tombstone
 *							bitmap
 *	 pending pages      newly inserted docs stored verbatim, searched directly
 *							until folded into a new segment by a flush
 *
 * Inserts append to the pending buffer and are immediately visible; a flush
 * (fts_merge() or VACUUM cleanup) folds pending docs into a new segment, and a
 * size-tiered merge compacts segments (dropping tombstoned docs).  Deletes are
 * recorded as per-segment livedocs tombstones by ambulkdelete.  All page writes
 * go through GenericXLog, so the index is crash-safe and replicated without a
 * custom resource manager.
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 *
 * IDENTIFICATION
 *	  pg_fts_am.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "pg_fts.h"
#include "pg_fts_am.h"
#include "pg_fts_sm.h"			/* namespaced sparsemap (tombstones, trigrams) */
#include <math.h>
#include "access/genam.h"
#include "access/generic_xlog.h"
#include "access/transam.h"		/* ReadNextTransactionId (recycle gate) */
#include "access/xlog.h"			/* RecoveryInProgress (maintenance-fn guard) */
#include "access/parallel.h"
#include "access/reloptions.h"
#include "access/relscan.h"
#include "access/table.h"
#include "access/tableam.h"
#include "access/visibilitymap.h"
#include "catalog/index.h"
#include "catalog/pg_am.h"
#include "catalog/pg_type.h"
#include "catalog/pg_collation.h"
#include "regex/regex.h"
#include "utils/varlena.h"
#include "utils/builtins.h"
#include "commands/defrem.h"
#include "commands/vacuum.h"
#include "executor/tuptable.h"
#include "executor/executor.h"
#include "executor/instrument.h"
#include "funcapi.h"
#include "miscadmin.h"
#include "nodes/pathnodes.h"
#include "nodes/tidbitmap.h"
#include "optimizer/cost.h"
#include "optimizer/optimizer.h"
#include "pgstat.h"
#include "storage/bufmgr.h"
#include "storage/buffile.h"
#include "portability/instr_time.h"
#include "catalog/storage.h"
#include "storage/condition_variable.h"
#include "storage/freespace.h"
#include "storage/indexfsm.h"
#include "storage/lmgr.h"
#include "storage/spin.h"
#include "tcop/tcopprot.h"
#include "utils/array.h"
#include "utils/acl.h"			/* object_ownercheck, aclcheck_error (maintenance-fn guard) */
#include "utils/lsyscache.h"	/* get_rel_name (maintenance-fn guard) */
#include "utils/memutils.h"
#include "utils/rel.h"
#include "utils/snapmgr.h"
#include "utils/selfuncs.h"

/* palloc/repalloc that transparently use the Huge variants past MaxAllocSize.
 * Build-time posting arrays for a very high-df term (e.g. tokens present in
 * millions of JSON-log lines) can exceed 1 GB, especially when the final merge
 * concatenates a term's postings across several segments before dedup.
 *
 * Note: this only lifts the *byte-size* ceiling (>1 GB). The element
 * counts (nposts/npos, int) still cap at INT_MAX (~2.1 G postings/positions
 * per term); a single term that common would overflow the int counters (and
 * their doubling) first. Not hit even at 20M diverse docs; widen these counts
 * to int64 if a term ever approaches that df. */
#define FTS_ALLOC_MAYBE_HUGE(sz) \
	(((Size) (sz)) > MaxAllocSize \
	 ? MemoryContextAllocHuge(CurrentMemoryContext, (sz)) \
	 : palloc((sz)))
#define FTS_REALLOC_MAYBE_HUGE(p, sz) \
	(((Size) (sz)) > MaxAllocSize \
	 ? repalloc_huge((p), (sz)) \
	 : repalloc((p), (sz)))

/*
 * bm25_page_data_end -- validated end of a page's filled area.
 *
 * Every reader that walks a page's contents needs pd_lower, and pd_lower is data
 * READ OFF THE PAGE: a recycled, torn or corrupt page can report anything.  Two
 * things go wrong if it is trusted:
 *
 *   - the walk runs past the page and interprets adjacent memory as entries, which
 *     at field scale produced "invalid memory alloc request size 3406063183" from
 *     the merge's dict walk (~142M entries where a page holds a few hundred) and
 *     made every merge, autovacuum cleanup and fts_vacuum fail permanently;
 *   - forming `page + pd_lower` at all is undefined behaviour for an absurd value,
 *     which UBSan flags ("pointer index expression ... overflowed") -- so the
 *     validation must happen in the INTEGER domain, before the pointer exists.
 *
 * Returns the contents start (i.e. an empty range) for any out-of-range pd_lower,
 * so callers degrade to "this page has nothing to read" rather than misbehaving.
 */
static inline char *
bm25_page_data_end(Page page)
{
	Size		contents = (Size) ((char *) PageGetContents(page) - (char *) page);
	uint32		lower = ((PageHeader) page)->pd_lower;

	if ((Size) lower > (Size) BLCKSZ || (Size) lower < contents)
		return (char *) page + contents;
	return (char *) page + lower;
}

PG_FUNCTION_INFO_V1(fts_handler);

/*
 * Reloptions for the bm25 index.  Only one knob: `positions` -- whether to
 * store per-token positions in the postings so phrase/NEAR is answered
 * directly from the index (no heap recheck).  Registered once from _PG_init.
 */
typedef struct BM25Options
{
	int32		vl_len_;		/* varlena header (do not touch directly!) */
	bool		positions;		/* store token positions in postings (default off) */
	bool		trigrams;		/* store the per-segment trigram index (default off).
								 * The trigram index accelerates ONLY regex and
								 * over-long fuzzy terms; plain/boolean/ranked/phrase
								 * /prefix/short-fuzzy do not use it (fuzzy walks the
								 * dictionary with a Levenshtein automaton directly, and
								 * regex/long-fuzzy fall back to a full dictionary scan
								 * when it is absent -- correct, just slower).  It is ~18%
								 * of the index, so it is OFF by default; turn it on with
								 * WITH (trigrams=on) for regex/long-fuzzy-heavy workloads. */
	bool		doclen_sidecar; /* store doclen in the per-segment quantized sidecar
								 * (v4, default on); OFF stores doclen inline in each
								 * posting (the pre-1.5 layout) -- an escape hatch for a
								 * workload that wants the pre-sidecar ranked-scan
								 * behavior.  Both are read by the same self-describing
								 * decoder, so an index can mix sidecar and inline
								 * segments and needs no REINDEX to change the option
								 * (new segments follow the current setting). */
} BM25Options;

static relopt_kind bm25_relopt_kind;

void		bm25_init_reloptions(void);
static bool bm25_index_wants_positions(Relation index);
static bool bm25_index_wants_trigrams(Relation index);
static bool bm25_index_wants_doclen_sidecar(Relation index);

void
bm25_init_reloptions(void)
{
	bm25_relopt_kind = add_reloption_kind();
	add_bool_reloption(bm25_relopt_kind, "positions",
					   "store token positions in postings for index-only phrase/NEAR",
					   false, AccessExclusiveLock);
	add_bool_reloption(bm25_relopt_kind, "trigrams",
					   "store the per-segment trigram index for regex/long-fuzzy acceleration",
					   false, AccessExclusiveLock);
	add_bool_reloption(bm25_relopt_kind, "doclen_sidecar",
					   "store doclen in a per-segment quantized sidecar (on) or inline in postings (off)",
					   true, AccessExclusiveLock);
}

/* ----- build: collect postings from the heap ----- */

typedef struct BuildTerm
{
	char	   *term;
	int			len;
	/* postings for this term */
	ItemPointerData *tids;
	uint32	   *tfs;
	uint32	   *doclens;
	/* token positions for this term, when the index carries positions.  Flat
	 * arena of all postings' positions; posting i owns positions[posoff[i] ..
	 * posoff[i]+tfs[i]).  Never reordered (postings are sorted by copying these
	 * offsets into the sort struct), so posoff stays valid across the sort. */
	uint32	   *positions;
	uint32	   *posoff;		/* per-posting start index into positions[] */
	uint32	   *poscnt;		/* per-posting stored position count (0 if dropped;
								 * may be < tf when a source block dropped positions) */
	int			npos;		/* total positions stored (== Sum poscnt) */
	int			maxpos;
	int			nposts;
	int			maxposts;
	uint32		max_tf;		/* max tf across postings; set by bm25_write_postings
								 * so bm25_write_dictionary reads it instead of
								 * rescanning tfs[] -- lets a streaming merge keep
								 * only term metadata (no tfs[] body) and still write
								 * a correct max_tf */
	int			next;			/* next BuildTerm sharing the same hash key, or -1 */
} BuildTerm;

typedef struct BM25BuildState
{
	MemoryContext ctx;
	BuildTerm  *terms;			/* sorted-on-flush; kept in a simple array */
	int			nterms;
	int			maxterms;
	bool		want_positions;	/* index built WITH (positions=on): carry token
								 * positions through build/merge into the postings */
	bool		want_trigrams;	/* index built WITH (trigrams=on): write the
								 * per-segment trigram index (regex/long-fuzzy accel) */
	bool		want_sidecar;	/* index built WITH (doclen_sidecar=on, the default):
								 * write doclen to the per-segment quantized sidecar and
								 * omit the inline posting column.  false = inline doclen. */
	/* build-time term list: an unsorted array collected during the heap scan,
	 * sorted once before the dictionary is written */
	double		ndocs;
	double		sumdoclen;
	Size		flush_budget;	/* current in-memory budget before a segment is
								 * flushed; grows as this participant flushes more,
								 * so the flush count stays far under
								 * BM25_MAX_SEGMENTS (0 = use the default) */
	int			nflushes;		/* segments this participant has flushed so far */
} BM25BuildState;

static int
cmp_buildterm(const void *a, const void *b)
{
	const BuildTerm *ta = (const BuildTerm *) a;
	const BuildTerm *tb = (const BuildTerm *) b;
	int			min = Min(ta->len, tb->len);
	int			c = memcmp(ta->term, tb->term, min);

	if (c != 0)
		return c;
	return ta->len - tb->len;
}

/*
 * Find or create a BuildTerm for (term,len).  We use a dynahash keyed by a
 * fixed-size padded copy of the term to avoid an O(n^2) linear scan.  Terms
 * longer than the key buffer fall back to exact comparison via the stored
 * BuildTerm, which is correct though it may hash-collide slightly; term length
 * is bounded by MAXSTRLEN in practice.
 */
#include "utils/hsearch.h"

#define BM25_TERMKEYLEN 64

typedef struct TermKey
{
	char		key[BM25_TERMKEYLEN];
} TermKey;

typedef struct TermHashEntry
{
	TermKey		key;			/* must be first: dynahash key */
	int			termidx;		/* head of a chain of BuildTerms sharing this key */
} TermHashEntry;

static HTAB *build_ht;

/*
 * (Re)initialize the build hash table that maps a term key to its BuildTerm
 * index.  Created in bs->ctx so it is freed when that context is reset between
 * segment flushes during a large build.
 */
static void
bm25_build_ht_init(BM25BuildState *bs)
{
	HASHCTL		ctl;

	ctl.keysize = sizeof(TermKey);
	ctl.entrysize = sizeof(TermHashEntry);
	ctl.hcxt = bs->ctx;
	build_ht = hash_create("bm25 build terms", 1024, &ctl,
						   HASH_ELEM | HASH_BLOBS | HASH_CONTEXT);
}

static void
make_termkey(TermKey *k, const char *term, int len)
{
	int			n = len;

	/* defensive: `len` ultimately derives from an on-disk/pending entries[].len
	 * (a uint32 read into an int).  A corrupt value could be negative or absurd;
	 * clamp to [0, BM25_TERMKEYLEN] so this fixed-size key copy can never turn
	 * into a wild memcpy (a _FORTIFY_SOURCE abort).  Callers validate the doc
	 * first (fts_doc_is_valid); this is the last line of defense. */
	if (n < 0)
		n = 0;
	memset(k, 0, sizeof(TermKey));
	memcpy(k->key, term, Min(n, BM25_TERMKEYLEN));
	/* fold length into the tail so different-length terms sharing a prefix do
	 * not collide on the key */
	if (n < BM25_TERMKEYLEN)
		k->key[n] = '\1';
}

static void
add_posting(BM25BuildState *bs, const char *term, int len,
			ItemPointer tid, uint32 tf, uint32 doclen,
			const uint32 *pos, int npos)
{
	TermKey		key;
	TermHashEntry *entry;
	bool		found;
	BuildTerm  *bt = NULL;
	int			idx;

	make_termkey(&key, term, len);
	entry = (TermHashEntry *) hash_search(build_ht, &key, HASH_ENTER, &found);

	/*
	 * On a hash hit, walk the chain of BuildTerms sharing this key and pick the
	 * truly-equal one.  The key is a padded/length-folded prefix, so two DISTINCT
	 * terms >= BM25_TERMKEYLEN bytes sharing that prefix can land on the same
	 * key; chaining keeps them as separate BuildTerms instead of clobbering the
	 * entry (which previously fragmented a term's postings across unreachable
	 * dictionary entries).
	 */
	if (found)
	{
		for (idx = entry->termidx; idx >= 0; idx = bs->terms[idx].next)
		{
			BuildTerm  *cand = &bs->terms[idx];

			if (cand->len == len && memcmp(cand->term, term, len) == 0)
			{
				bt = cand;
				break;
			}
		}
	}

	if (bt == NULL)
	{
		if (bs->nterms >= bs->maxterms)
		{
			bs->maxterms = bs->maxterms ? bs->maxterms * 2 : 1024;
			if (bs->terms == NULL)
				bs->terms = (BuildTerm *) FTS_ALLOC_MAYBE_HUGE(bs->maxterms * sizeof(BuildTerm));
			else
				bs->terms = (BuildTerm *) FTS_REALLOC_MAYBE_HUGE(bs->terms,
														   bs->maxterms * sizeof(BuildTerm));
		}
		bt = &bs->terms[bs->nterms];
		bt->term = (char *) palloc(len);
		memcpy(bt->term, term, len);
		bt->len = len;
		bt->maxposts = 4;
		bt->nposts = 0;
		bt->max_tf = 0;			/* filled by bm25_write_postings */
		bt->tids = (ItemPointerData *) FTS_ALLOC_MAYBE_HUGE(bt->maxposts * sizeof(ItemPointerData));
		bt->tfs = (uint32 *) FTS_ALLOC_MAYBE_HUGE(bt->maxposts * sizeof(uint32));
		bt->doclens = (uint32 *) FTS_ALLOC_MAYBE_HUGE(bt->maxposts * sizeof(uint32));
		bt->positions = NULL;
		bt->posoff = NULL;
		bt->poscnt = NULL;
		bt->npos = 0;
		bt->maxpos = 0;
		if (bs->want_positions)
		{
			bt->posoff = (uint32 *) FTS_ALLOC_MAYBE_HUGE(bt->maxposts * sizeof(uint32));
			bt->poscnt = (uint32 *) FTS_ALLOC_MAYBE_HUGE(bt->maxposts * sizeof(uint32));
			bt->maxpos = 8;
			bt->positions = (uint32 *) palloc(bt->maxpos * sizeof(uint32));	/* alloc-ok: seed=8, grown huge-safe below; one term in a budget-bounded segment */
		}
		/* push onto the head of this key's chain (-1 = end of chain) */
		bt->next = found ? entry->termidx : -1;
		entry->termidx = bs->nterms;
		bs->nterms++;
	}

	if (bt->nposts >= bt->maxposts)
	{
		bt->maxposts *= 2;
		bt->tids = (ItemPointerData *) FTS_REALLOC_MAYBE_HUGE(bt->tids,
												bt->maxposts * sizeof(ItemPointerData));
		bt->tfs = (uint32 *) FTS_REALLOC_MAYBE_HUGE(bt->tfs, bt->maxposts * sizeof(uint32));
		bt->doclens = (uint32 *) FTS_REALLOC_MAYBE_HUGE(bt->doclens, bt->maxposts * sizeof(uint32));
		if (bt->posoff != NULL)
		{
			bt->posoff = (uint32 *) FTS_REALLOC_MAYBE_HUGE(bt->posoff, bt->maxposts * sizeof(uint32));
			bt->poscnt = (uint32 *) FTS_REALLOC_MAYBE_HUGE(bt->poscnt, bt->maxposts * sizeof(uint32));
		}
	}
	bt->tids[bt->nposts] = *tid;
	bt->tfs[bt->nposts] = tf;
	bt->doclens[bt->nposts] = doclen;
	/*
	 * Carry positions when the index wants them and the caller supplied a full
	 * set (npos == tf).  A per-(term,doc) position count is bounded by the
	 * analyzer's MAXENTRYPOS cap, so appending tf values here cannot blow up a
	 * single posting; the segment total is bounded by the build memory budget
	 * (checked between tuples in bm25_build_callback), which flushes before the
	 * arena grows unbounded -- so this never materializes the whole corpus'
	 * positions in one array.
	 */
	if (bs->want_positions && pos != NULL && npos == (int) tf && tf > 0)
	{
		if (bt->npos + (int) tf > bt->maxpos)
		{
			while (bt->npos + (int) tf > bt->maxpos)
				bt->maxpos *= 2;
			bt->positions = (uint32 *) FTS_REALLOC_MAYBE_HUGE(bt->positions,
												bt->maxpos * sizeof(uint32));
		}
		bt->posoff[bt->nposts] = (uint32) bt->npos;
		bt->poscnt[bt->nposts] = tf;
		memcpy(bt->positions + bt->npos, pos, tf * sizeof(uint32));
		bt->npos += (int) tf;
	}
	else if (bt->posoff != NULL)
	{
		/* want positions but this posting has none (tf==0, or a source block
		 * dropped them on a prior write): record an empty run + zero count so
		 * posoff stays aligned with the posting index and the writer knows this
		 * posting stores no positions (it will drop the block's positions). */
		bt->posoff[bt->nposts] = (uint32) bt->npos;
		bt->poscnt[bt->nposts] = 0;
	}
	bt->nposts++;
}

/* forward decls: segment writers are defined later; the build flush uses them */
static void bm25_write_segment(Relation index, BM25BuildState *bs, BM25SegMeta *seg);
static void bm25_meta_from_page(Page page, BM25MetaPageData *out);
static void bm25_meta_upcast_page(Page page);
static bool bm25_meta_add_segment(Relation index, const BM25SegMeta *seg);
static void bm25_add_segment_with_room(Relation index, const BM25SegMeta *seg);
static void bm25_free_page(Relation index, BlockNumber blk);
static bool bm25_page_recyclable(Relation index, Page page);

/*
 * Memory budget for the in-memory build state before it is flushed to a
 * segment.  A very large CREATE INDEX would otherwise accumulate the whole
 * corpus's terms + postings in bs->ctx and exhaust memory; instead, once the
 * build context grows past this, we write the accumulated terms as a segment
 * and start fresh.  Derived from maintenance_work_mem (bounded so a small
 * setting still makes progress).  The later size-tiered merge compacts the
 * resulting segments.
 */
static Size
bm25_build_mem_budget(void)
{
	Size		budget = (Size) maintenance_work_mem * (Size) 1024;

	if (budget < (Size) 32 * 1024 * 1024)
		budget = (Size) 32 * 1024 * 1024;	/* floor: 32MB */
	return budget;
}

/*
 * Ceiling the per-participant flush budget may grow to.  Default (GUC == 0) is
 * 2 * maintenance_work_mem -- the memory-safe cap from 1.0.6 that prevents a
 * geometrically-doubling budget from driving a parallel build into swap death.
 * When pg_fts.build_mem_ceiling_mb > 0 the operator raises the ceiling to trade
 * RAM for fewer, larger segments (so a huge build stays under the segment cap);
 * peak build memory is ~(workers+1) * ceiling.  Never below 2*mwm so setting a
 * small value can't make the build flush more often than the default.
 */
static Size
bm25_build_mem_ceiling(void)
{
	Size		default_ceiling = (Size) 2 *bm25_build_mem_budget();
	Size		guc_ceiling;

	if (pg_fts_build_mem_ceiling_mb <= 0)
		return default_ceiling;
	guc_ceiling = (Size) pg_fts_build_mem_ceiling_mb * 1024 * 1024;
	return guc_ceiling > default_ceiling ? guc_ceiling : default_ceiling;
}

/*
 * Bound a build participant's flush-segment count without merging mid-build.
 *
 * Each participant (the serial builder, or the leader + each parallel worker)
 * flushes an in-memory segment every time its accumulator reaches the flush
 * budget, plus one residual at the end.  All participants append into the same
 * fixed BM25_MAX_SEGMENTS metapage directory, so a large build could otherwise
 * overflow it (bm25_meta_add_segment errors) even though the data is fine and
 * merges to a single segment at the end.  A parallel worker cannot merge
 * mid-build to reclaim slots -- it runs while IsInParallelMode() and the
 * metapage swap is single-writer only -- so instead each participant caps its
 * own flush count by DOUBLING its budget every BM25_BUILD_FLUSHES_PER_TIER
 * flushes, UP TO A CEILING of 2 * maintenance_work_mem.  The doubling keeps the
 * flush (segment) count low on a huge build; the ceiling keeps peak MEMORY
 * bounded -- memory is the hard limit (exhausting it degrades the host),
 * segment-count overflow is a clean error backstopped by BM25_MAX_SEGMENTS.
 * With the cap a participant of total in-memory volume V flushes about
 *   V / (2 * maintenance_work_mem) + O(BM25_BUILD_FLUSHES_PER_TIER) rampup
 * segments, which stays well under the cap for realistic corpora, while peak
 * memory is bounded to (max_parallel_maintenance_workers + 1) * 2 * mwm.  An
 * UNcapped budget (2GB->4->8->16->32GB ...) instead let a participant grow to
 * tens of GB before flushing, driving a real 1.8M-doc / 19GB build into swap
 * death several hours in.  This needs no up-front size estimate (the in-memory
 * arena / heap-bytes ratio varies with the data), touches only this
 * participant's own state (parallel-safe), and never falls below the operator's
 * maintenance_work_mem for the first tier.  BM25_MAX_SEGMENTS stays as the hard
 * backstop.
 */
#define BM25_BUILD_FLUSHES_PER_TIER 8


/*
 * Flush the current in-memory build state as one immutable segment and reset
 * the state (freeing bs->ctx) so the heap scan can continue within a bounded
 * memory footprint.  A document's terms are always fully accumulated before a
 * flush (we only flush between tuples), so no document is split across
 * segments and each segment's ndocs/sumdoclen are self-consistent.
 */

static void
bm25_build_flush_segment(Relation index, BM25BuildState *bs)
{
	BM25SegMeta seg;

	if (bs->nterms == 0)
		return;
	if (bs->nterms > 1)
		qsort(bs->terms, bs->nterms, sizeof(BuildTerm), cmp_buildterm);

	/*
	 * Serialize index-page writes across parallel-build participants.  During a
	 * parallel build several backends flush segments into the same index
	 * concurrently; pg_fts appends pages (bm25_new_buffer -> ReadBuffer(P_NEW)),
	 * and overlapping appenders race on relation extension ("unexpected data
	 * beyond EOF").  Holding the relation extension lock around the whole
	 * segment write makes each participant's page additions atomic w.r.t. the
	 * others.  The expensive part of the build -- heap scan + tsearch analysis
	 * -- runs fully parallel, and the segment write appends pages via
	 * bm25_new_buffer(), which now serializes only the P_NEW extension itself
	 * (per page) rather than the whole write -- so participants write
	 * concurrently.  In a serial build IsInParallelMode() is false and no
	 * extension lock is taken at all.
	 */
	bm25_write_segment(index, bs, &seg);

	/*
	 * Install the descriptor without ever failing on a full directory.  In a
	 * PARALLEL build several participants flush concurrently and re-entering the
	 * merge machinery here risks the finalize wedge that 1.1.2 fixed, so a
	 * parallel participant uses the plain add and leaves compaction to the
	 * serial finalize; the build's flush-budget ceiling keeps its own segment
	 * count well under the cap.  Every other path (serial build, and especially
	 * live INSERT/pending-flush on a visible index) uses the room-ensuring add
	 * so a write is never refused because merging fell behind.
	 */
	if (IsInParallelMode())
	{
		if (!bm25_meta_add_segment(index, &seg))
			ereport(ERROR,
					(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
					 errmsg("bm25 index \"%s\" reached the maximum of %d segments during a parallel build",
							RelationGetRelationName(index), BM25_MAX_SEGMENTS),
					 errhint("Raise pg_fts.build_mem_ceiling_mb (fewer, larger segments) or lower max_parallel_maintenance_workers.")));
	}
	else
		bm25_add_segment_with_room(index, &seg);

	/*
	 * Progress signal for a large build.  A high-vocabulary, heavy-tailed corpus
	 * (long email bodies, quoted chains, code/patches) makes the per-document
	 * text analysis (parse + stem) the dominant cost, so a serial build can run
	 * for many minutes between flushes while it accumulates a budget's worth of
	 * documents -- with nothing written and the segment count unchanged, which
	 * looks indistinguishable from a hang.  Emit a LOG line at each flush so an
	 * operator can see the build advancing (documents indexed, segments so far).
	 */
	elog(LOG, "pg_fts build: index \"%s\": flushed segment (%d terms, %.0f docs); %d segments so far",
		 RelationGetRelationName(index), bs->nterms, bs->ndocs, bs->nflushes + 1);

	/*
	 * Grow the flush budget geometrically so this participant's flush count
	 * stays far under BM25_MAX_SEGMENTS on a huge build, but CAP it at
	 * 2 * maintenance_work_mem so peak build memory stays bounded.  The cap is
	 * the hard limit: memory exhaustion crashes/degrades the host, whereas
	 * exceeding the segment count is a clean error (bm25_meta_add_segment) with
	 * the end-of-build merge collapsing to one segment.  Uncapped doubling
	 * (2GB -> 4 -> 8 -> 16 -> 32GB ...) let bs->ctx grow to tens of GB before a
	 * flush; with the leader + max_parallel_maintenance_workers each holding its
	 * own budget, peak memory is (workers+1) * budget, so an uncapped budget
	 * drove a real 1.8M-doc / 19GB build into swap death several hours in (once
	 * participants crossed into the 16GB+ tier).  At the 2*mwm cap a
	 * per-participant build of accumulated in-memory volume V flushes about
	 * V/(2*mwm) + a few rampup segments; for realistic corpora that stays well
	 * under BM25_MAX_SEGMENTS, and peak memory is bounded to
	 * (workers+1) * 2 * maintenance_work_mem.
	 *
	 * Note: peak build memory is (max_parallel_maintenance_workers + 1) times
	 * this budget -- size maintenance_work_mem with that multiplier in mind.
	 */
	if (bs->flush_budget == 0)
		bs->flush_budget = bm25_build_mem_budget();
	bs->nflushes++;
	if (bs->nflushes % BM25_BUILD_FLUSHES_PER_TIER == 0 &&
		bs->flush_budget < bm25_build_mem_ceiling())
		bs->flush_budget *= 2;

	/* reset: free everything in the build context and start a fresh segment */
	MemoryContextReset(bs->ctx);
	bs->terms = NULL;
	bs->nterms = 0;
	bs->maxterms = 0;
	bs->ndocs = 0;
	bs->sumdoclen = 0;
	bm25_build_ht_init(bs);
}

/* per-heap-tuple callback */
static void
bm25_build_callback(Relation index, ItemPointer tid, Datum *values,
					bool *isnull, bool tupleIsAlive, void *state)
{
	BM25BuildState *bs = (BM25BuildState *) state;
	FtsDoc		doc;
	FtsTermEntry *entries;
	uint32		i;
	MemoryContext old;

	if (isnull[0])
		return;

	/*
	 * Bound build memory: if the accumulated segment has grown past the budget,
	 * flush it as a segment and continue with a fresh build state.  Checked
	 * between tuples so a document's terms are never split across segments.
	 *
	 * Recurse into child contexts (the `true`): the term dynahash (build_ht) is
	 * created with hcxt = bs->ctx, so dynahash puts its bucket directory and all
	 * TermHashEntry entries in a CHILD context of bs->ctx.  Counting only bs->ctx
	 * itself (the old `false`) missed the hash-table memory entirely, so on a
	 * huge-vocabulary corpus (e.g. long email/body text: quoted chains, patches,
	 * code -> millions of distinct terms) the flush undercounted the real working
	 * set and fired far too late, letting the build's memory grow for hours
	 * instead of settling at ~maintenance_work_mem.  bs->ctx and its children are
	 * exactly what MemoryContextReset frees at flush, so `true` counts precisely
	 * the reclaimable footprint the budget is meant to bound.
	 */
	if (bs->nterms > 0 &&
		MemoryContextMemAllocated(bs->ctx, true) >=
		(bs->flush_budget ? bs->flush_budget : bm25_build_mem_budget()))
		bm25_build_flush_segment(index, bs);

	old = MemoryContextSwitchTo(bs->ctx);

	doc = (FtsDoc) PG_DETOAST_DATUM(values[0]);
	entries = FTS_DOC_ENTRIES(doc);

	for (i = 0; i < doc->nterms; i++)
	{
		const uint32 *pos = NULL;
		int			npos = 0;

		if (bs->want_positions && FTS_DOC_HAS_POS(doc))
		{
			pos = FTS_DOC_TERMPOS(doc, &entries[i]);
			npos = (int) entries[i].tf;
		}
		add_posting(bs, FTS_DOC_TERMTEXT(doc, &entries[i]), entries[i].len,
					tid, entries[i].tf, doc->doclen, pos, npos);
	}

	/*
	 * Corpus statistics (BM25 IDF + length normalization) must count only LIVE
	 * documents.  During CREATE INDEX/REINDEX/VACUUM FULL, PostgreSQL surfaces
	 * recently-dead tuples (deleted but not yet past the global horizon -- routine
	 * whenever any snapshot pins the horizon, e.g. a standby's feedback) to this
	 * callback with tupleIsAlive = false.  Such a tuple MUST still be indexed (an
	 * old snapshot may reach it via the index -- so the add_posting loop above
	 * runs unconditionally) but MUST NOT contribute to ndocs/sumdoclen: counting
	 * it biases IDF and average-document-length scoring and over-reports the
	 * document count.  Gate only the statistics on liveness.
	 */
	if (tupleIsAlive)
	{
		bs->ndocs += 1.0;
		bs->sumdoclen += doc->doclen;
	}

	/*
	 * Coarse progress heartbeat.  On a heavy corpus the per-document analysis
	 * dominates and a whole budget of documents accumulates between segment
	 * flushes (minutes of apparent silence); a periodic LOG line shows the scan
	 * is advancing rather than wedged.  A process-local counter is sufficient
	 * (serial build = one process; a parallel worker logs its own share).
	 */
	{
		static long	built = 0;

		if ((++built % 250000) == 0)
			elog(LOG, "pg_fts build: index \"%s\": ~%ld documents analyzed",
				 RelationGetRelationName(index), built);
	}

	MemoryContextSwitchTo(old);
}

/* ----- posting compression (delta + varint) ----- */

/*
 * Pack/unpack a heap TID into a monotonic 48-bit docid so that ascending TIDs
 * yield ascending docids and small gaps.  MaxHeapTuplesPerPage bounds the
 * offset, so block*factor+offset is monotonic in (block, offset).
 */
#define BM25_OFFSET_FACTOR ((uint64) MaxHeapTuplesPerPage)

static inline uint64
bm25_tid_to_docid(ItemPointer tid)
{
	return (uint64) ItemPointerGetBlockNumber(tid) * BM25_OFFSET_FACTOR +
		(uint64) ItemPointerGetOffsetNumber(tid);
}

static inline void
bm25_docid_to_tid(uint64 docid, ItemPointer tid)
{
	BlockNumber blk = (BlockNumber) (docid / BM25_OFFSET_FACTOR);
	OffsetNumber off = (OffsetNumber) (docid % BM25_OFFSET_FACTOR);

	ItemPointerSet(tid, blk, off);
}

/*
 * FOR (frame-of-reference) bit-packing of a block's three columns.  The codec
 * (bm25_bitwidth / bm25_for_pack / bm25_for_unpack / bm25_for_bytelen /
 * bm25_for_get) lives in pg_fts_for.h as pure standalone C so the standalone
 * property tests (test/hegel/) share this exact copy -- single source of truth.
 */
#include "pg_fts_for.h"

/*
 * Decode exactly one term's postings from the shared posting chain: start at
 * (firstblk, firstoff) and decode consecutive blocks -- following nextblk
 * across pages -- until `df` postings have been read.  A term's blocks are
 * written contiguously, so its run is delimited purely by df.  Returns the
 * count (== df on a consistent index); *out (and *blockmax if non-NULL) are
 * palloc'd.  `off` on pages after the first is the contents start.
 *
 * When want_positions is true and a block carries a positions column
 * (posbytelen>0), each posting's `pos` is set to point into a single palloc'd
 * positions arena (*posarena, returned so the caller can free it); the pointer
 * is valid until that arena is freed.  When want_positions is false the
 * positions column is SKIPPED with a pointer add (posbytelen) and never
 * decoded -- so plain BM25/AND/count queries pay ~zero for positions existing,
 * mirroring the tf/doclen bytelen-skip.
 *
 * When docids_only is true the caller wants ONLY the matching TIDs (a TidSet):
 * we still decode the gaps (docids) column and honor every corruption guard,
 * but SKIP the tf and doclen bm25_for_unpack calls (about 2/3 of the per-block
 * decode work) and never decode positions.  posts[].tf/.doclen/.pos are left 0/
 * NULL, so a docids_only caller MUST NOT read them.  This is the count / set-
 * membership fast path (bm25_collect_matches and the docid-only dict walks);
 * the ranked scan scores via the WAND cursor (bm25_for_get), not this decoder,
 * so it is unaffected.  docids_only forces want_positions off internally.
 */
static int
bm25_decode_term(Relation index, BlockNumber firstblk, uint32 firstoff,
				 uint32 df, BM25Posting **out, uint32 **blockmax,
				 bool want_positions, uint32 **posarena, bool docids_only,
				 bool has_doclen_col)
{
	BM25Posting *posts;
	uint32	   *bmax = NULL;
	uint32	   *parena = NULL;
	int		   *pos_start = NULL;	/* per-posting arena offset (fixed to ptr below) */
	int			parena_n = 0;
	int			parena_cap = 0;
	int			n = 0;
	BlockNumber blk = firstblk;
	uint32		off = firstoff;

	/*
	 * docids_only implies positions are irrelevant: force want_positions off so
	 * the whole positions-column decode/arena path below is skipped along with
	 * the tf/doclen unpack.
	 */
	if (docids_only)
		want_positions = false;

	/*
	 * Clamp df to a sane ceiling before sizing the allocation.  df is read from
	 * a dictionary entry on a page pinned only BUFFER_LOCK_SHARE; a concurrent
	 * merge/vacuum can free this segment's pages while a concurrent insert
	 * recycles and overwrites them (pg_fts recycles freed pages with no
	 * deletion-xid gate), so a scan that snapshotted the directory before that
	 * can read a recycled dict page whose "df" is arbitrary -- which turned
	 * the posting allocation below into an "invalid memory alloc request size"
	 * (a multi-gigabyte request) and aborted a live query.
	 *
	 * The ceiling must be a bound no LEGITIMATE df can exceed, or we truncate
	 * real postings.  A term's df counts documents at index time, so it can
	 * exceed the current LIVE corpus size once rows are tombstoned -- the live
	 * metapage ndocs is therefore the WRONG bound (it under-counts and drops
	 * postings for a term whose docs were partly deleted).  The correct bound is
	 * the total documents ever recorded across all segments INCLUDING tombstoned
	 * ones (BM25SegMeta.ndocs is defined as docs incl. tombstones), i.e. the sum
	 * of seg.ndocs; no term appears in more documents than exist.  A garbage df
	 * is clamped to that; the block loop then decodes only the real posting
	 * chain (delimited by nextblk), and the scan's generation re-check detects
	 * the stale read and restarts.  The metapage is effectively always resident.
	 */
	{
		BM25MetaPageData cmeta;
		double		total = 0;
		uint32		maxdf;
		uint32		s;
		Buffer		mb = ReadBuffer(index, BM25_METAPAGE_BLKNO);

		LockBuffer(mb, BUFFER_LOCK_SHARE);
		bm25_meta_from_page(BufferGetPage(mb), &cmeta);
		UnlockReleaseBuffer(mb);
		for (s = 0; s < cmeta.nsegments && s < BM25_MAX_SEGMENTS; s++)
			total += cmeta.segs[s].ndocs;	/* incl. tombstoned */
		total += cmeta.npending;		/* unmerged docs can match too */
		maxdf = (total >= (double) UINT32_MAX) ? UINT32_MAX : (uint32) total;
		if (maxdf < 1)
			maxdf = 1;
		if (df > maxdf)
			df = maxdf;
	}

	posts = (BM25Posting *) ((Size) df * sizeof(BM25Posting) > MaxAllocSize
							 ? MemoryContextAllocHuge(CurrentMemoryContext,
													 Max(df, 1u) * sizeof(BM25Posting))
							 : palloc(Max(df, 1u) * sizeof(BM25Posting)));	/* alloc-ok: huge branch of the > MaxAllocSize ternary above */
	if (blockmax)
		bmax = (uint32 *) ((Size) df * sizeof(uint32) > MaxAllocSize
						   ? MemoryContextAllocHuge(CurrentMemoryContext, Max(df, 1u) * sizeof(uint32))
						   : palloc(Max(df, 1u) * sizeof(uint32)));	/* alloc-ok: huge branch of the > MaxAllocSize ternary above */
	if (want_positions)
		pos_start = (int *) ((Size) df * sizeof(int) > MaxAllocSize
							 ? MemoryContextAllocHuge(CurrentMemoryContext, Max(df, 1u) * sizeof(int))
							 : palloc(Max(df, 1u) * sizeof(int)));	/* alloc-ok: huge branch of the > MaxAllocSize ternary above */

	while (blk != InvalidBlockNumber && n < (int) df)
	{
		Buffer		buf = ReadBuffer(index, blk);
		Page		page;
		char	   *p,
				   *pend;
		BlockNumber next;

		LockBuffer(buf, BUFFER_LOCK_SHARE);
		page = BufferGetPage(buf);
		pend = bm25_page_data_end(page);
		next = BM25PageGetOpaque(page)->nextblk;
		p = (char *) page + off;
		while (p + sizeof(BM25BlockHdr) <= pend && n < (int) df)
		{
			BM25BlockHdr *bh = (BM25BlockHdr *) p;
			const unsigned char *stream = (const unsigned char *) (bh + 1);
			uint64		docid = ((uint64) bh->first_docid_hi << 32) | bh->first_docid_lo;
			uint64		gaps[BM25_BLOCK_SIZE];
			uint64		tfs[BM25_BLOCK_SIZE];
			uint64		dls[BM25_BLOCK_SIZE];
			int			cnt = (int) bh->count;
			int			pos = 0;
			int			i;

			if (cnt == 0)
				break;

			/*
			 * Never trust the on-disk block header's own count/lengths: a torn
			 * page, a stale-format image, or any producing bug could give a
			 * count > BM25_BLOCK_SIZE (which would overflow the fixed gaps/tfs/
			 * dls stack arrays via bm25_for_unpack) or a bytelen/posbytelen that
			 * runs the FOR columns past the page (an out-of-bounds read).  Clamp
			 * the count (as the WAND block loader already does) and stop
			 * decoding this term at the first block whose declared payload does
			 * not fit within the page -- returning the postings decoded so far
			 * rather than reading off the end.  A corrupt block is thus a
			 * bounded, non-crashing miss; REINDEX rebuilds it from the heap.
			 *
			 * bh->count is uint32: test the unsigned value (a >2^31 count would
			 * cast to a negative int and slip past a `cnt > BM25_BLOCK_SIZE`
			 * check).  Anything not in [1, BM25_BLOCK_SIZE] is a corrupt block.
			 */
			if (bh->count == 0 || bh->count > (uint32) BM25_BLOCK_SIZE)
				cnt = BM25_BLOCK_SIZE;
			if (stream + (Size) bh->bytelen + (Size) bh->posbytelen > (const unsigned char *) pend)
			{
				ereport(WARNING,
						(errcode(ERRCODE_DATA_CORRUPTED),
						 errmsg("pg_fts: truncated posting block in index \"%s\"; stopping term decode",
								RelationGetRelationName(index)),
						 errhint("REINDEX the index to rebuild it from the heap.")));
				UnlockReleaseBuffer(buf);
				goto done;
			}

			/*
			 * The three FOR columns must fit within the block's own declared
			 * bytelen (which the guard above proved fits within the page).
			 * bm25_for_unpack consumes a byte count driven by the on-disk width
			 * byte; a corrupt width could otherwise read past the page even with
			 * a small bytelen.  Sum the three columns' declared consumption and
			 * reject the block if it overruns bytelen, before decoding any of it.
			 */
			{
				int			gl = bm25_for_bytelen(stream, cnt);
				int			tl = (gl <= (int) bh->bytelen)
					? bm25_for_bytelen(stream + gl, cnt) : 0;
				int			dl;

				/*
				 * Column count is SELF-DESCRIBING from bytelen: a v3 block packs
				 * three FOR columns (docid|tf|doclen) so bytes remain after gl+tl;
				 * a v4 block packs two (docid|tf, doclen is in the segment sidecar)
				 * so gl+tl == bytelen exactly.  Detecting it here -- rather than
				 * trusting the caller's has_doclen_col -- is robust across every
				 * decode path (build/merge/scan/count) and mixed v3+v4 segments.
				 */
				has_doclen_col = (gl + tl < (int) bh->bytelen);
				dl = (has_doclen_col && gl + tl <= (int) bh->bytelen)
					? bm25_for_bytelen(stream + gl + tl, cnt) : 0;

				if ((Size) gl + tl + dl > (Size) bh->bytelen)
				{
					ereport(WARNING,
							(errcode(ERRCODE_DATA_CORRUPTED),
							 errmsg("pg_fts: corrupt posting block (columns overrun bytelen) in index \"%s\"; stopping term decode",
									RelationGetRelationName(index)),
							 errhint("REINDEX the index to rebuild it from the heap.")));
					UnlockReleaseBuffer(buf);
					goto done;
				}
			}
			pos += bm25_for_unpack(stream + pos, cnt, gaps);
			if (!docids_only)
			{
				/*
				 * docids_only: skip the tf and doclen columns entirely.  The
				 * bytelen/column-overrun guards above already ran on all three
				 * columns, and nothing downstream in docids_only mode consumes
				 * `pos` past this point (positions use stream+bh->bytelen and the
				 * block advance uses bh->bytelen+bh->posbytelen), so leaving the
				 * tf/dl bytes undecoded is safe.  posts[].tf/.doclen stay 0.
				 */
				pos += bm25_for_unpack(stream + pos, cnt, tfs);
				if (has_doclen_col)
					pos += bm25_for_unpack(stream + pos, cnt, dls);	/* v3: inline doclen */
				else
					memset(dls, 0, sizeof(uint64) * cnt);	/* v4: caller fills from sidecar */
			}

			if (want_positions && bh->posbytelen > 0)
			{
				/* the positions column packs Sum(tf) delta values over the whole
				 * block; decode them once, then un-delta per posting below.  n0
				 * is the first posting index of this block. */
				const unsigned char *pstream = stream + bh->bytelen;
				uint64		deltas[BM25_BLOCK_SIZE * 4];
				uint64	   *dbuf = deltas;
				int			sumtf = 0;
				int			n0 = n;
				int			j;

				for (i = 0; i < cnt; i++)
					sumtf += (int) tfs[i];

				/*
				 * Sanity-bound sumtf against the declared positions bytes before
				 * trusting it: the positions column is one FOR block of sumtf
				 * values at width pstream[0], occupying exactly
				 *   width==0 ? 1 : 1 + ceil(sumtf*width/8)   bytes.
				 * A corrupt/inflated tfs[] (each value in range, but summing huge)
				 * can push sumtf far above what posbytelen actually encodes;
				 * without this check bm25_for_unpack would read past the block and
				 * we would size a bogus multi-GB arena.  The existing bh->count /
				 * FOR-column guards do not catch an inflated tfs[].  Compute the
				 * exact required length in 64-bit Size arithmetic (NOT via
				 * bm25_for_bytelen, whose int n*width would itself overflow on a
				 * corrupt sumtf); comparing the exact length avoids false positives
				 * on a legitimate width-0 (all-zero-delta) block with large sumtf.
				 * pstream[0] is in-bounds: the guard above proved
				 * stream+bytelen+posbytelen <= pend and posbytelen>0 here.
				 */
				{
					unsigned int pw = pstream[0];	/* FOR width byte */
					Size		need;

					if (sumtf < 0)
						need = MaxAllocSize + 1;	/* overflow -> force reject */
					else
						need = (pw == 0) ? 1
							: (Size) 1 + (((Size) sumtf * pw + 7) / 8);

					if (need > (Size) bh->posbytelen)
					{
						ereport(WARNING,
								(errcode(ERRCODE_DATA_CORRUPTED),
								 errmsg("pg_fts: corrupt posting block (positions count exceeds declared bytes) in index \"%s\"; stopping term decode",
										RelationGetRelationName(index)),
								 errhint("REINDEX the index to rebuild it from the heap.")));
						UnlockReleaseBuffer(buf);
						goto done;
					}
				}

				/*
				 * A legitimately huge sumtf (a term repeated very many times in
				 * one document) needs a huge-safe alloc: a plain palloc throws
				 * "invalid memory alloc request size" once sumtf*8 crosses
				 * MaxAllocSize, aborting any decode caller (scan/merge/bulkdelete/
				 * CIC validation).  Mirrors the write-side guard in
				 * bm25_write_postings.
				 */
				if (sumtf > (int) (sizeof(deltas) / sizeof(deltas[0])))
					dbuf = (uint64 *) FTS_ALLOC_MAYBE_HUGE((Size) sumtf * sizeof(uint64));
				(void) bm25_for_unpack(pstream, sumtf, dbuf);

				/* grow the arena to hold this block's positions.  parena_cap*4 is
				 * likewise huge-safe (accumulated across the term's blocks). */
				if (parena_n + sumtf > parena_cap)
				{
					parena_cap = Max(parena_cap * 2, parena_n + sumtf);
					parena = parena == NULL
						? (uint32 *) FTS_ALLOC_MAYBE_HUGE((Size) parena_cap * sizeof(uint32))
						: (uint32 *) FTS_REALLOC_MAYBE_HUGE(parena, (Size) parena_cap * sizeof(uint32));
				}

				/* un-delta each posting's run (delta reset at posting boundaries) */
				j = 0;
				for (i = 0; i < cnt; i++)
				{
					int			tf = (int) tfs[i];
					uint32		run = 0;
					int			t;

					if (n0 + i < (int) df)
						pos_start[n0 + i] = parena_n;
					for (t = 0; t < tf; t++)
					{
						run += (uint32) dbuf[j++];
						parena[parena_n++] = run;
					}
				}
				if (dbuf != deltas)
					pfree(dbuf);
			}
			else if (want_positions)
			{
				/* positions absent for this block (posbytelen==0: a page-overflow
				 * block dropped them).  Mark each posting -1 so the pointer
				 * conversion yields NULL -- NOT a valid arena offset, which would
				 * alias another block's positions and misread adjacency. */
				for (i = 0; i < cnt && n + i < (int) df; i++)
					pos_start[n + i] = -1;
			}

			for (i = 0; i < cnt && n < (int) df; i++)
			{
				docid += gaps[i];
				bm25_docid_to_tid(docid, &posts[n].tid);
				/* docids_only: tfs/dls were not unpacked; leave tf/doclen 0 */
				posts[n].tf = docids_only ? 0 : (uint32) tfs[i];
				posts[n].doclen = docids_only ? 0 : (uint32) dls[i];
				posts[n].pos = NULL;
				if (bmax)
					bmax[n] = bh->max_tf;
				n++;
			}
			/* skip past the three columns AND the positions column (posbytelen)
			 * -- a non-positions reader never touches the blob, only adds it */
			p = (char *) (bh + 1) + bh->bytelen + bh->posbytelen;
			p = (char *) MAXALIGN(p);
		}
		UnlockReleaseBuffer(buf);
		blk = next;
		off = MAXALIGN(SizeOfPageHeaderData);	/* later pages: contents start */
	}
done:
	/* convert per-posting arena offsets to stable pointers now the arena is final */
	if (want_positions)
	{
		int			k;

		for (k = 0; k < n; k++)
			posts[k].pos = (parena != NULL && posts[k].tf > 0 && pos_start[k] >= 0)
				? parena + pos_start[k] : NULL;
		if (pos_start)
			pfree(pos_start);
	}
	*out = posts;
	if (blockmax)
		*blockmax = bmax;
	if (posarena)
		*posarena = parena;
	else if (parena)
		pfree(parena);
	return n;
}

/* ----- writing the index pages ----- */

/*
 * Low-page-biased allocation context.  Normally bm25_new_buffer() hands out
 * whatever free page the FSM offers (unordered), then extends.  During a
 * space-reclaiming compaction we instead want to pack live pages toward the
 * FRONT of the file so the dead tail can be truncated.  A
 * BM25_ALLOC_LOWFIRST scope gathers all currently-free blocks, sorts them
 * ascending, and bm25_new_buffer() hands them out low-first; when the list is
 * exhausted it falls back to the ordinary FSM/extend path.  The context is a
 * single backend-scoped struct (compaction is single-writer) with a scoped
 * lifetime -- see BM25AllocCtx below.
 */
/*
 * The allocator context is ONE struct with a SCOPED lifetime, not a set of
 * independent globals.  This is deliberate and it is the fix for a real bug:
 * in the 1.7.1 work, code read the low-free cursor and flipped extend-only
 * without owning the state -- outside any begin/end pair -- and handed out
 * garbage block numbers from a dangling pointer ("could not open file ...
 * target block 829694001: previous segment is only 527 blocks").  Only
 * t/007_segment_cap.pl caught it.
 *
 * So the state is reachable only through bm25_alloc_scope_enter() /
 * bm25_alloc_scope_exit(), which nest by returning the previous context, and
 * bm25_new_buffer() asserts a scope is active before consulting it.  The
 * failure mode that bit is now an assertion, not a test's job to notice.
 *
 * lowfree/n/i: the ascending free-block list gathered by a low-first
 * (compacting) scope; NULL when the scope is extend-only or plain.
 * extend_only: skip ALL free-page reuse (low-free list AND FSM) and only
 * extend, so a rewrite lands on fresh high blocks.  Used by the compactor's
 * "vacate" phase and by the merge loop while a merge is reading its inputs
 * (merge N+1 must not recycle a page merge N still threads a chain through).
 */
typedef struct BM25AllocCtx
{
	BlockNumber *lowfree;
	int			lowfree_n;
	int			lowfree_i;
	bool		extend_only;
	bool		no_fsm;			/* SNAPSHOT mode: skip the live-FSM fallback */
	bool		active;			/* a scope has been entered */
} BM25AllocCtx;

static BM25AllocCtx bm25_alloc = {NULL, 0, 0, false, false, false};

typedef enum BM25AllocMode
{
	BM25_ALLOC_PLAIN,			/* FSM reuse then extend (the default) */
	BM25_ALLOC_LOWFIRST,		/* gather free blocks, hand out lowest first, then FSM, then extend */
	BM25_ALLOC_SNAPSHOT,		/* gather free blocks ONCE at entry; hand out only those, then extend;
								 * never re-consult the live FSM (see bm25_merge_segments) */
	BM25_ALLOC_EXTEND_ONLY		/* never reuse; extend only */
} BM25AllocMode;

/* GUC: build finalizes to one segment only when total index <= this many MB;
 * above it the build stops at a bounded tiered set so it always converges.
 * Defined here, registered in _PG_init (pg_fts_customscan.c). */
int			pg_fts_build_collapse_max_mb = 4096;

/* GUC: per-participant flush-budget growth ceiling, in MB.  0 = keep the safe
 * default ceiling of 2 * maintenance_work_mem (unchanged behavior).  When set
 * larger, a build lets each participant's flush budget grow up to this, so a
 * large corpus flushes FEWER, LARGER segments and the live segment count stays
 * well under BM25_MAX_SEGMENTS (which would otherwise abort a very large
 * parallel build).  Peak build memory is about (max_parallel_maintenance_workers
 * + 1) * this ceiling -- size it against available RAM.  Defined here,
 * registered in _PG_init (pg_fts_customscan.c). */
int			pg_fts_build_mem_ceiling_mb = 0;

static int
cmp_blocknumber(const void *a, const void *b)
{
	BlockNumber x = *(const BlockNumber *) a;
	BlockNumber y = *(const BlockNumber *) b;

	return (x < y) ? -1 : (x > y) ? 1 : 0;
}

/*
 * Gather all free blocks (via a linear FSM probe) into an ascending array so
 * subsequent bm25_new_buffer() calls reuse the lowest blocks first.  Single
 * writer only.  Cheap relative to the segment rewrite it precedes.
 */
/*
 * Enter an allocator scope of the given mode.  Returns the PREVIOUS context so
 * the caller can restore it with bm25_alloc_scope_exit() -- scopes nest (the
 * vacuum compactor calls the merge, which opens its own scope), and the
 * save/restore that two call sites used to do by hand is now the mechanism.
 *
 * Always pair with bm25_alloc_scope_exit() in PG_FINALLY.  A LOWFIRST scope
 * gathers all currently-free blocks (linear FSM probe, O(nblocks), cheap next
 * to the rewrite it precedes) into an ascending array.
 */
static BM25AllocCtx
bm25_alloc_scope_enter(Relation index, BM25AllocMode mode)
{
	BM25AllocCtx prev = bm25_alloc;

	bm25_alloc.lowfree = NULL;
	bm25_alloc.lowfree_n = 0;
	bm25_alloc.lowfree_i = 0;
	bm25_alloc.extend_only = (mode == BM25_ALLOC_EXTEND_ONLY);
	bm25_alloc.no_fsm = (mode == BM25_ALLOC_SNAPSHOT);
	bm25_alloc.active = true;

	if (mode == BM25_ALLOC_LOWFIRST || mode == BM25_ALLOC_SNAPSHOT)
	{
		BlockNumber nblocks = RelationGetNumberOfBlocks(index);
		BlockNumber blk;

		if (nblocks > 1)
		{
			bm25_alloc.lowfree = (BlockNumber *) palloc(sizeof(BlockNumber) * nblocks);
			for (blk = 1; blk < nblocks; blk++)	/* block 0 = metapage, never free */
				if (GetRecordedFreeSpace(index, blk) >= BLCKSZ / 2)
					bm25_alloc.lowfree[bm25_alloc.lowfree_n++] = blk;
			if (bm25_alloc.lowfree_n > 1)
				qsort(bm25_alloc.lowfree, bm25_alloc.lowfree_n,
					  sizeof(BlockNumber), cmp_blocknumber);
		}
	}
	return prev;
}

/* Leave the current scope, freeing its list, and restore the previous one. */
static void
bm25_alloc_scope_exit(BM25AllocCtx prev)
{
	if (bm25_alloc.lowfree)
		pfree(bm25_alloc.lowfree);
	bm25_alloc = prev;
}

static Buffer
bm25_new_buffer(Relation index)
{
	Buffer		buffer;

	/*
	 * The invariant that bit in 1.7.1, now enforced: if the context carries a
	 * low-free list or the extend-only flag, some scope MUST own it.  A stale
	 * list from a scope that already exited is exactly the dangling pointer that
	 * produced garbage block numbers.  (A plain, unscoped allocation -- ordinary
	 * insert -- has neither and is fine.)  An elog, not an Assert: the release
	 * gate is not a cassert build, and a check that only fires in a build nobody
	 * ships is documentation, not enforcement.  One predictable branch per
	 * allocation is nothing next to the page read that follows.
	 */
	if (unlikely(!bm25_alloc.active &&
				 (bm25_alloc.lowfree != NULL || bm25_alloc.extend_only)))
		elog(ERROR, "pg_fts: allocator context used outside an allocation scope");

	/*
	 * Low-bias reuse: during a compaction, prefer the lowest free block so
	 * live pages pack at the front of the file.
	 */
	while (!bm25_alloc.extend_only && bm25_alloc.lowfree &&
		   bm25_alloc.lowfree_i < bm25_alloc.lowfree_n)
	{
		BlockNumber blk = bm25_alloc.lowfree[bm25_alloc.lowfree_i++];

		buffer = ReadBuffer(index, blk);
		if (ConditionalLockBuffer(buffer))
		{
			if (!bm25_page_recyclable(index, BufferGetPage(buffer)))
			{
				/* a scan may still reference this just-freed page; leave it in
				 * the FSM for a later allocation once its horizon passes */
				LockBuffer(buffer, BUFFER_LOCK_UNLOCK);
				ReleaseBuffer(buffer);
				RecordFreeIndexPage(index, blk);
				continue;
			}
			RecordUsedIndexPage(index, blk);
			return buffer;
		}
		ReleaseBuffer(buffer);
	}

	/* Try to reuse a page freed by a previous merge before extending.  Skipped
	 * in SNAPSHOT mode: the live FSM may now hold pages THIS operation freed a
	 * moment ago while a reader chain of ours still threads through them. */
	while (!bm25_alloc.extend_only && !bm25_alloc.no_fsm)
	{
		BlockNumber blk = GetFreeIndexPage(index);

		if (blk == InvalidBlockNumber)
			break;				/* no free page; extend below */
		buffer = ReadBuffer(index, blk);
		if (ConditionalLockBuffer(buffer))
		{
			if (!bm25_page_recyclable(index, BufferGetPage(buffer)))
			{
				/* not yet safe to reuse (a concurrent scan could still be
				 * reading it); re-record so it is handed out later, and try the
				 * next free page.  Terminates: extension is the backstop when no
				 * currently-recyclable free page exists. */
				LockBuffer(buffer, BUFFER_LOCK_UNLOCK);
				ReleaseBuffer(buffer);
				RecordFreeIndexPage(index, blk);
				break;
			}
			return buffer;		/* got it */
		}
		/* someone else is using it; try the next free page */
		ReleaseBuffer(buffer);
	}

	/*
	 * Extend the relation.  The relation extension lock MUST be held around the
	 * P_NEW extension whenever ANY other backend might extend the same index
	 * concurrently -- not just parallel-build participants.  A live index is
	 * extended by several unrelated, non-parallel backends at once: an INSERT
	 * flushing its pending buffer into a new segment, fts_merge() writing merged
	 * output, and VACUUM/bulkdelete rewriting.  Without the lock, two such
	 * backends race on ReadBuffer(P_NEW) and one trips "unexpected data beyond
	 * EOF in block N" (a reader/extender hitting a block past its cached EOF
	 * while another backend extends).  A field report hit exactly this running
	 * fts_merge() concurrently with live ingestion.  (This used to be gated on
	 * IsInParallelMode(), which covered only the parallel-build case and left
	 * concurrent serial extenders racing.)  The lock is held ONLY around the
	 * single P_NEW call, not the whole segment write, so concurrent writers
	 * still write their pages in parallel -- only the one-block extend
	 * serializes, which is how heap and every core index AM extend.
	 */
	LockRelationForExtension(index, ExclusiveLock);
	buffer = ReadBuffer(index, P_NEW);
	LockBuffer(buffer, BUFFER_LOCK_EXCLUSIVE);
	UnlockRelationForExtension(index, ExclusiveLock);
	return buffer;
}

static void
bm25_init_page(Page page, uint16 flags)
{
	BM25PageOpaque opaque;

	PageInit(page, BLCKSZ, sizeof(BM25PageOpaqueData));
	opaque = BM25PageGetOpaque(page);
	opaque->flags = flags;
	opaque->nextblk = InvalidBlockNumber;
	/* start item area at the (MAXALIGN'd) contents offset used by readers */
	((PageHeader) page)->pd_lower = (char *) PageGetContents(page) - (char *) page;
}

/*
 * Version-aware metapage read (the 1.5.0 dual-read fix).
 *
 * 1.5.0 added BlockNumber doclenstart to BM25SegMeta, which GREW the struct
 * (v3 48 bytes -> v4 56 bytes with padding).  BM25SegMeta is stored INLINE in
 * the metapage's segs[] array, so a v3 metapage lays segs[] out at the 48-byte
 * stride and places `generation` right after segs[128] at the v3 offset.  A v4
 * build that cast the page straight to BM25MetaPageData read segs[1..] and
 * generation from the wrong offsets -> garbage livedocslen (palloc(-1)) and
 * garbage dictstart (wild block seek): the two upgrade regressions.
 *
 * This deserializes EITHER version into an in-memory v4 BM25MetaPageData.  For
 * a v3 page it copies the fixed head, then expands each v3-stride segmeta into
 * the v4 struct and sets doclenstart = InvalidBlockNumber (segment carries
 * inline doclen), and reads `generation` from the v3 offset.  A v4 page is a
 * straight copy.  ALL readers use this instead of casting the page directly.
 */
typedef struct BM25SegMetaV3
{
	BlockNumber dictstart;
	BlockNumber trgmstart;
	BlockNumber livedocs;
	double		ndocs;
	double		sumdoclen;
	uint32		nterms;
	uint32		ndeleted;
	uint32		livedocslen;
	BlockNumber dictindexstart;
} BM25SegMetaV3;

/* v3 metapage layout: same head as v4 up to segs[], then v3-stride segs[], then
 * generation.  We only need the head fields + segs[] + generation. */
typedef struct BM25MetaPageDataV3
{
	uint32		magic;
	uint32		version;
	double		ndocs;
	double		sumdoclen;
	uint32		nsegments;
	BlockNumber pendinghead;
	BlockNumber pendingtail;
	uint32		npending;
	BM25SegMetaV3 segs[BM25_MAX_SEGMENTS];
	uint32		generation;
} BM25MetaPageDataV3;

static void
bm25_meta_from_page(Page page, BM25MetaPageData *out)
{
	const BM25MetaPageData *raw = BM25PageGetMeta(page);

	/*
	 * Layout contract (the 1.5.0 dual-read fix): the v3 read-struct and the
	 * live v4 struct MUST agree on every field up to and including segs[0], so a
	 * v3 metapage's head + first segment are read at identical offsets; only the
	 * segs[] STRIDE (48 vs 56 bytes) and the position of `generation` differ,
	 * which bm25_meta_from_page handles explicitly.  These asserts fail the build
	 * if a future field insertion silently breaks that contract again.
	 */
	StaticAssertStmt(offsetof(BM25MetaPageDataV3, segs) == offsetof(BM25MetaPageData, segs),
					 "v3/v4 metapage head layout diverged");
	StaticAssertStmt(offsetof(BM25SegMetaV3, dictindexstart) == offsetof(BM25SegMeta, dictindexstart),
					 "v3/v4 segmeta head layout diverged");

	if (raw->version >= BM25_VERSION_DOCLEN_SIDECAR)
	{
		memcpy(out, raw, sizeof(BM25MetaPageData));
		return;
	}
	/* v3 page: expand v3-stride segs[] into the v4 in-memory struct */
	{
		const BM25MetaPageDataV3 *v3 = (const BM25MetaPageDataV3 *) raw;
		uint32		s;

		MemSet(out, 0, sizeof(BM25MetaPageData));
		out->magic = v3->magic;
		out->version = v3->version;
		out->ndocs = v3->ndocs;
		out->sumdoclen = v3->sumdoclen;
		out->nsegments = v3->nsegments;
		out->pendinghead = v3->pendinghead;
		out->pendingtail = v3->pendingtail;
		out->npending = v3->npending;
		out->generation = v3->generation;
		for (s = 0; s < v3->nsegments && s < BM25_MAX_SEGMENTS; s++)
		{
			out->segs[s].dictstart = v3->segs[s].dictstart;
			out->segs[s].trgmstart = v3->segs[s].trgmstart;
			out->segs[s].livedocs = v3->segs[s].livedocs;
			out->segs[s].ndocs = v3->segs[s].ndocs;
			out->segs[s].sumdoclen = v3->segs[s].sumdoclen;
			out->segs[s].nterms = v3->segs[s].nterms;
			out->segs[s].ndeleted = v3->segs[s].ndeleted;
			out->segs[s].livedocslen = v3->segs[s].livedocslen;
			out->segs[s].dictindexstart = v3->segs[s].dictindexstart;
			out->segs[s].doclenstart = InvalidBlockNumber;	/* v3: inline doclen */
		}
	}
}

/*
 * Upcast a v3 metapage to the v4 in-place layout under the caller's exclusive
 * lock, via GenericXLog, so subsequent in-place struct writes are correct.
 * Idempotent: a no-op if the page is already v4.  MUST be called (under the
 * metapage's exclusive lock, before read-modify-writing it) by every path that
 * mutates the metapage in place (add-segment, merge, bulkdelete livedocs swap).
 * `page` is a GenericXLog-registered writable copy.
 */
static void
bm25_meta_upcast_page(Page page)
{
	BM25MetaPageData tmp;
	BM25MetaPageData *m;

	if (BM25PageGetMeta(page)->version >= BM25_VERSION_DOCLEN_SIDECAR)
		return;

	bm25_meta_from_page(page, &tmp);	/* read v3 into a v4-shaped temp */
	tmp.version = BM25_VERSION;
	m = BM25PageGetMeta(page);
	MemSet(m, 0, sizeof(BM25MetaPageData));
	memcpy(m, &tmp, sizeof(BM25MetaPageData));
	((PageHeader) page)->pd_lower =
		((char *) m + sizeof(BM25MetaPageData)) - (char *) page;
}

static void
bm25_init_metapage(Relation index)
{
	Buffer		buffer;
	GenericXLogState *state;
	Page		page;
	BM25MetaPageData *meta;

	buffer = bm25_new_buffer(index);
	Assert(BufferGetBlockNumber(buffer) == BM25_METAPAGE_BLKNO);

	state = GenericXLogStart(index);
	page = GenericXLogRegisterBuffer(state, buffer, GENERIC_XLOG_FULL_IMAGE);
	bm25_init_page(page, BM25_META);
	meta = BM25PageGetMeta(page);
	MemSet(meta, 0, sizeof(BM25MetaPageData));
	meta->magic = BM25_MAGIC;
	meta->version = BM25_VERSION;
	meta->ndocs = 0;
	meta->sumdoclen = 0;
	meta->nsegments = 0;
	meta->pendinghead = InvalidBlockNumber;
	meta->pendingtail = InvalidBlockNumber;
	meta->npending = 0;
	((PageHeader) page)->pd_lower =
		((char *) meta + sizeof(BM25MetaPageData)) - (char *) page;
	GenericXLogFinish(state);
	UnlockReleaseBuffer(buffer);
}

/*
 * Validate a metapage's magic and format version before trusting its contents.
 * Guards against a pg_fts shared library reading an index written by an
 * incompatible on-disk format (e.g. a .so upgraded/downgraded out of step with
 * the physical index) — the classic ".so vs catalog/on-disk skew".  Callers
 * pass the metapage of an index being opened for scan/insert/maintenance; a
 * mismatch raises a clear, actionable error rather than silently misreading
 * bytes.
 */
static void
bm25_check_meta(Page page, Relation index)
{
	BM25MetaPageData *meta = BM25PageGetMeta(page);

	if (meta->magic != BM25_MAGIC)
		ereport(ERROR,
				(errcode(ERRCODE_INDEX_CORRUPTED),
				 errmsg("index \"%s\" is not a valid pg_fts index",
						RelationGetRelationName(index)),
				 errdetail("Metapage magic 0x%08X does not match the expected 0x%08X.",
						   meta->magic, BM25_MAGIC)));

	if (meta->version < BM25_VERSION_DOCLEN_INLINE || meta->version > BM25_VERSION)
		ereport(ERROR,
				(errcode(ERRCODE_INDEX_CORRUPTED),
				 errmsg("index \"%s\" has pg_fts on-disk format version %u, but this build supports versions %u..%u",
						RelationGetRelationName(index),
						meta->version, BM25_VERSION_DOCLEN_INLINE, BM25_VERSION),
				 errhint("REINDEX the index to rebuild it in the current format.")));
}

/*
 * Write all postings for one term into the segment's shared posting-page chain
 * via a BM25PostWriter, returning the term's first block + byte offset.
 * Postings are docid-sorted and packed into 128-doc FOR blocks (BM25BlockHdr +
 * three frame-of-reference bit-packed columns: docid-gaps, tfs, doclens), which
 * compresses the common case of many clustered docids into a few bits each.
 */
typedef struct BM25PostingSort
{
	uint64		docid;
	uint32		tf;
	uint32		doclen;
	uint32		posoff;			/* start index into bt->positions (valid iff bt->positions) */
	uint32		poscnt;			/* stored position count (<= tf; 0 if dropped) */
	ItemPointerData tid;
}			BM25PostingSort;

static int
cmp_posting_docid(const void *a, const void *b)
{
	uint64		da = ((const BM25PostingSort *) a)->docid;
	uint64		db = ((const BM25PostingSort *) b)->docid;

	if (da < db)
		return -1;
	if (da > db)
		return 1;
	return 0;
}

/* ---- doclen sidecar (format v4) --------------------------------------------
 *
 * One quantized length byte per document, on a BM25_DOCLEN page chain ordered
 * by ascending segment-local docid, in 128-doc blocks: a FOR-packed docid-gap
 * column then `count` raw length bytes.  Replaces the per-posting doclen FOR
 * column (once per doc x term) with one byte per doc.  A reader binary-locates
 * the block by first_docid then indexes the byte.
 *
 * The collector is a docid->byte hash so the map is built in O(ndocs) memory
 * regardless of Sum(df) (the P1 build-OOM was a flat Sum(df) array).  Callers
 * feed (docid, doclen) as they already iterate postings; duplicates (a doc seen
 * once per term) collapse in the hash.
 */
typedef struct DoclenEntry
{
	uint64		docid;			/* hash key */
	uint8		byte;			/* quantized doclen */
} DoclenEntry;

typedef struct DoclenCollector
{
	HTAB	   *ht;				/* docid -> DoclenEntry */
	MemoryContext ctx;
} DoclenCollector;

/* One doclen-sidecar block header: count docs, first docid for binary locate,
 * and the FOR-packed gap column length. The `count` length bytes follow the
 * gap column. */
typedef struct BM25DoclenBlockHdr
{
	uint32		count;			/* docs in this block (<= BM25_BLOCK_SIZE) */
	uint32		first_docid_hi;
	uint32		first_docid_lo;
	uint32		gapbytes;		/* FOR-packed docid-gap column length */
} BM25DoclenBlockHdr;

static void
doclen_collector_init(DoclenCollector *c, MemoryContext ctx, long nhint)
{
	HASHCTL		ctl;

	MemSet(&ctl, 0, sizeof(ctl));
	ctl.keysize = sizeof(uint64);
	ctl.entrysize = sizeof(DoclenEntry);
	ctl.hcxt = ctx;
	c->ctx = ctx;
	c->ht = hash_create("pg_fts doclen sidecar", Max(nhint, 1024), &ctl,
						HASH_ELEM | HASH_BLOBS | HASH_CONTEXT);
}

/* Record one doc's length (idempotent per docid: the byte is a function of the
 * length, identical across a doc's term postings). */
static inline void
doclen_collector_add(DoclenCollector *c, uint64 docid, uint32 doclen)
{
	bool		found;
	DoclenEntry *e = (DoclenEntry *) hash_search(c->ht, &docid, HASH_ENTER, &found);

	if (!found)
		e->byte = fts_doclen_to_byte(doclen);
}

static int
cmp_doclen_entry(const void *a, const void *b)
{
	uint64		da = ((const DoclenEntry *) a)->docid;
	uint64		db = ((const DoclenEntry *) b)->docid;

	return (da < db) ? -1 : (da > db) ? 1 : 0;
}

/*
 * Write the collected docid->byte map to a BM25_DOCLEN page chain and return
 * the first page (Invalid if empty).  Defined after the posting-page writer
 * (BM25PostWriter) it reuses; forward-declared here.
 */
static BlockNumber bm25_write_doclen_sidecar(Relation index, DoclenCollector *c);


/*
 * Shared posting-page writer.  All terms in a segment append their blocks into
 * ONE chain of posting pages, so a rare term (a handful of postings) costs a
 * few dozen bytes instead of a whole 8 KB page -- critical for a Zipfian
 * vocabulary where most terms are tiny.  Each term records its start (block +
 * byte offset); the reader decodes blocks from there, counting postings until
 * it has read the term's df, following nextblk across page boundaries.
 */
typedef struct BM25PostWriter
{
	Relation	index;
	Buffer		buffer;
	GenericXLogState *state;
	Page		page;
	bool		no_doclen_col;	/* v4: omit the per-posting doclen FOR column
									 * (it lives in the segment doclen sidecar); the
									 * block header still carries min_doclen for the
									 * block-max WAND bound. */
} BM25PostWriter;

static void
pw_begin(BM25PostWriter *pw, Relation index)
{
	pw->index = index;
	pw->buffer = InvalidBuffer;
	pw->state = NULL;
	pw->page = NULL;
	pw->no_doclen_col = false;
}

static void
pw_finish(BM25PostWriter *pw)
{
	if (pw->buffer != InvalidBuffer)
	{
		GenericXLogFinish(pw->state);
		UnlockReleaseBuffer(pw->buffer);
		pw->buffer = InvalidBuffer;
	}
}

/*
 * Append one term's postings to the shared writer.  Returns the block and byte
 * offset where the term's first block begins (for its dictionary entry).
 */
static void
bm25_write_postings(BM25PostWriter *pw, BuildTerm *bt,
					BlockNumber *firstblk, uint32 *firstoff)
{
	Relation	index = pw->index;
	BM25PostingSort *sorted;
	int			i;
	bool		start_recorded = false;
	uint32		term_max_tf = 0;

	*firstblk = InvalidBlockNumber;
	*firstoff = 0;

	sorted = (BM25PostingSort *) ((Size) bt->nposts * sizeof(BM25PostingSort) > MaxAllocSize
								  ? MemoryContextAllocHuge(CurrentMemoryContext,
													  Max(bt->nposts, 1) * sizeof(BM25PostingSort))
								  : palloc(Max(bt->nposts, 1) * sizeof(BM25PostingSort)));	/* alloc-ok: huge branch of the > MaxAllocSize ternary above */
	for (i = 0; i < bt->nposts; i++)
	{
		sorted[i].docid = bm25_tid_to_docid(&bt->tids[i]);
		sorted[i].tf = bt->tfs[i];
		sorted[i].doclen = bt->doclens[i];
		sorted[i].posoff = bt->positions ? bt->posoff[i] : 0;
		sorted[i].poscnt = bt->positions ? bt->poscnt[i] : 0;
		sorted[i].tid = bt->tids[i];
	}
	if (bt->nposts > 1)
		qsort(sorted, bt->nposts, sizeof(BM25PostingSort), cmp_posting_docid);

	i = 0;
	while (i < bt->nposts)
	{
		uint64		gaps[BM25_BLOCK_SIZE];
		uint64		tfs[BM25_BLOCK_SIZE];
		uint64		dls[BM25_BLOCK_SIZE];
		unsigned char scratch[3 * (1 + (BM25_BLOCK_SIZE * 64 + 7) / 8)];
		int			sclen = 0;
		uint32		blk_max_tf = 0;
		uint32		blk_min_dl = UINT32_MAX;
		uint64		blk_first_docid = sorted[i].docid;
		uint64		prev_docid = sorted[i].docid;
		int			bcount = 0;
		int			blk_first = i;
		int			poslen = 0;
		uint64	   *posdeltas = NULL;
		unsigned char *posbuf = NULL;
		char	   *pageend;
		Size		need;
		Size		usable;
		char	   *dst;
		BM25BlockHdr *bh;

		/* gather up to BM25_BLOCK_SIZE postings into columns (SoA) */
		while (i < bt->nposts && bcount < BM25_BLOCK_SIZE)
		{
			gaps[bcount] = sorted[i].docid - prev_docid;	/* first gap is 0 */
			tfs[bcount] = sorted[i].tf;
			dls[bcount] = sorted[i].doclen;
			if (sorted[i].tf > blk_max_tf)
				blk_max_tf = sorted[i].tf;
			if (sorted[i].tf > term_max_tf)
				term_max_tf = sorted[i].tf;
			if (sorted[i].doclen < blk_min_dl)
				blk_min_dl = sorted[i].doclen;
			prev_docid = sorted[i].docid;
			bcount++;
			i++;
		}

		sclen += bm25_for_pack(gaps, bcount, scratch + sclen);
		sclen += bm25_for_pack(tfs, bcount, scratch + sclen);
		if (!pw->no_doclen_col)
			sclen += bm25_for_pack(dls, bcount, scratch + sclen);	/* v3: inline doclen */

		/*
		 * Build the positions blob for this block (WITH positions=on).  It packs
		 * Sum(tf) delta values -- each posting's positions delta-coded from 0 and
		 * reset at the posting boundary.  Sum(tf) per block is unbounded in
		 * principle (P1's build-alloc trap), so size the scratch from the ACTUAL
		 * Sum(tf) with a huge-safe alloc, never a fixed stack array.  If the
		 * resulting block would not fit even an empty page, write the block WITH
		 * NO positions (posbytelen=0) -- decode then yields NULL positions for
		 * these postings and phrase eval correctly falls back to recheck for
		 * those docids (bounded, and only for pathological Sum(tf)).
		 */
		usable = BLCKSZ - MAXALIGN(SizeOfPageHeaderData) - MAXALIGN(sizeof(BM25PageOpaqueData));
		if (bt->positions)
		{
			int64		sumtf = 0;
			int			k;
			int			j = 0;
			bool		all_pos = true;

			/* only build the positions blob if EVERY posting in this block has a
			 * complete position set (poscnt == tf).  A posting whose positions
			 * were dropped on a prior write (poscnt < tf) cannot contribute tf
			 * deltas, so drop the whole block's positions (posbytelen=0) and let
			 * phrase fall back to recheck for these docids. */
			for (k = 0; k < bcount; k++)
			{
				sumtf += (int64) tfs[k];
				if (sorted[blk_first + k].poscnt != (uint32) tfs[k])
					all_pos = false;
			}
			if (sumtf > 0 && all_pos)
			{
				Size		dlbytes = (Size) sumtf * sizeof(uint64);
				Size		pbbytes = 1 + ((Size) sumtf * 32 + 7) / 8;	/* FOR worst case */

				posdeltas = (uint64 *) (dlbytes > MaxAllocSize
										? MemoryContextAllocHuge(CurrentMemoryContext, dlbytes)
										: palloc(dlbytes));
				posbuf = (unsigned char *) (pbbytes > MaxAllocSize
											? MemoryContextAllocHuge(CurrentMemoryContext, pbbytes)
											: palloc(pbbytes));
				for (k = 0; k < bcount; k++)
				{
					const uint32 *pp = bt->positions + sorted[blk_first + k].posoff;
					uint32		tf = (uint32) tfs[k];
					uint32		prev = 0;
					uint32		t;

					for (t = 0; t < tf; t++)
					{
						/* positions are ascending within a posting; delta-code,
						 * reset prev to 0 at each posting boundary.  The index posting
						 * positions carry only the ORDINAL (low 30 bits); the weight
						 * label lives in the heap ftsdoc value and a field-restricted
						 * (term:LABEL) query applies the label filter via the heap
						 * recheck path, so the on-disk posting format is UNCHANGED from
						 * v3 (no reindex).  Mask the label defensively in case a v4
						 * value ever reaches the build with labels set. */
						uint32		ord = FTS_POS_ORD(pp[t]);

						posdeltas[j++] = (uint64) (ord - prev);
						prev = ord;
					}
				}
				poslen = bm25_for_pack(posdeltas, (int) sumtf, posbuf);
			}
		}

		need = MAXALIGN(sizeof(BM25BlockHdr) + sclen + poslen);
		if (poslen > 0 && need > usable)
		{
			/* positions push the block past a whole page: drop them for this
			 * block (recheck fallback keeps phrase correct for these docids) */
			poslen = 0;
			need = MAXALIGN(sizeof(BM25BlockHdr) + sclen);
		}

		/* need a page with room for this block? */
		if (pw->buffer != InvalidBuffer)
		{
			pageend = (char *) pw->page + BLCKSZ - MAXALIGN(sizeof(BM25PageOpaqueData));
			if ((char *) pw->page + ((PageHeader) pw->page)->pd_lower + need > pageend)
			{
				Buffer		next = bm25_new_buffer(index);
				BlockNumber nextblk = BufferGetBlockNumber(next);

				BM25PageGetOpaque(pw->page)->nextblk = nextblk;
				GenericXLogFinish(pw->state);
				UnlockReleaseBuffer(pw->buffer);
				pw->buffer = next;
				pw->state = GenericXLogStart(index);
				pw->page = GenericXLogRegisterBuffer(pw->state, pw->buffer, GENERIC_XLOG_FULL_IMAGE);
				bm25_init_page(pw->page, BM25_POSTING);
			}
		}
		if (pw->buffer == InvalidBuffer)
		{
			pw->buffer = bm25_new_buffer(index);
			pw->state = GenericXLogStart(index);
			pw->page = GenericXLogRegisterBuffer(pw->state, pw->buffer, GENERIC_XLOG_FULL_IMAGE);
			bm25_init_page(pw->page, BM25_POSTING);
		}

		/* record the term's start at its first block */
		if (!start_recorded)
		{
			*firstblk = BufferGetBlockNumber(pw->buffer);
			*firstoff = (uint32) ((PageHeader) pw->page)->pd_lower;
			start_recorded = true;
		}

		dst = (char *) pw->page + ((PageHeader) pw->page)->pd_lower;
		bh = (BM25BlockHdr *) dst;
		bh->count = (uint32) bcount;
		bh->max_tf = blk_max_tf;
		bh->min_doclen = (blk_min_dl == UINT32_MAX ? 0 : blk_min_dl);
		bh->first_docid_hi = (uint32) (blk_first_docid >> 32);
		bh->first_docid_lo = (uint32) (blk_first_docid & 0xFFFFFFFF);
		bh->bytelen = (uint32) sclen;
		bh->posbytelen = (uint32) poslen;
		memcpy((char *) (bh + 1), scratch, sclen);
		if (poslen > 0)
			memcpy((char *) (bh + 1) + sclen, posbuf, poslen);
		((PageHeader) pw->page)->pd_lower += need;
		if (posdeltas)
			pfree(posdeltas);
		if (posbuf)
			pfree(posbuf);
	}

	pfree(sorted);
	bt->max_tf = term_max_tf;	/* dictionary reads this; no tfs[] rescan */
}

/*
 * Write the collected docid->byte map to a BM25_DOCLEN page chain and return
 * the first page (Invalid if empty).  Reuses BM25PostWriter and the same
 * page-fit idiom as bm25_write_postings.
 */
static BlockNumber
bm25_write_doclen_sidecar(Relation index, DoclenCollector *c)
{
	HASH_SEQ_STATUS seq;
	DoclenEntry *e;
	DoclenEntry *arr;
	long		n = hash_get_num_entries(c->ht);
	long		idx = 0;
	long		i;
	BM25PostWriter pw;
	BlockNumber first = InvalidBlockNumber;
	bool		start_recorded = false;

	if (n == 0)
		return InvalidBlockNumber;

	arr = (DoclenEntry *) FTS_ALLOC_MAYBE_HUGE((Size) n * sizeof(DoclenEntry));	/* alloc-ok: n = ndocs (per-doc), not Sum(df) */
	hash_seq_init(&seq, c->ht);
	while ((e = (DoclenEntry *) hash_seq_search(&seq)) != NULL)
		arr[idx++] = *e;
	qsort(arr, n, sizeof(DoclenEntry), cmp_doclen_entry);

	pw_begin(&pw, index);
	i = 0;
	while (i < n)
	{
		uint64		gaps[BM25_BLOCK_SIZE];
		uint8		bytes[BM25_BLOCK_SIZE];
		unsigned char gapscratch[1 + (BM25_BLOCK_SIZE * 64 + 7) / 8];
		uint64		first_docid = arr[i].docid;
		uint64		prev = arr[i].docid;
		int			bcount = 0;
		int			gapbytes;
		Size		need;
		char	   *pageend;
		char	   *dst;
		BM25DoclenBlockHdr *bh;

		while (i < n && bcount < BM25_BLOCK_SIZE)
		{
			gaps[bcount] = arr[i].docid - prev;	/* first gap 0 */
			bytes[bcount] = arr[i].byte;
			prev = arr[i].docid;
			bcount++;
			i++;
		}
		gapbytes = bm25_for_pack(gaps, bcount, gapscratch);
		need = MAXALIGN(sizeof(BM25DoclenBlockHdr) + gapbytes + bcount);

		if (pw.buffer != InvalidBuffer)
		{
			pageend = (char *) pw.page + BLCKSZ - MAXALIGN(sizeof(BM25PageOpaqueData));
			if ((char *) pw.page + ((PageHeader) pw.page)->pd_lower + need > pageend)
			{
				Buffer		next = bm25_new_buffer(index);
				BlockNumber nextblk = BufferGetBlockNumber(next);

				BM25PageGetOpaque(pw.page)->nextblk = nextblk;
				GenericXLogFinish(pw.state);
				UnlockReleaseBuffer(pw.buffer);
				pw.buffer = next;
				pw.state = GenericXLogStart(index);
				pw.page = GenericXLogRegisterBuffer(pw.state, pw.buffer, GENERIC_XLOG_FULL_IMAGE);
				bm25_init_page(pw.page, BM25_DOCLEN);
			}
		}
		if (pw.buffer == InvalidBuffer)
		{
			pw.buffer = bm25_new_buffer(index);
			pw.state = GenericXLogStart(index);
			pw.page = GenericXLogRegisterBuffer(pw.state, pw.buffer, GENERIC_XLOG_FULL_IMAGE);
			bm25_init_page(pw.page, BM25_DOCLEN);
		}
		if (!start_recorded)
		{
			first = BufferGetBlockNumber(pw.buffer);
			start_recorded = true;
		}
		dst = (char *) pw.page + ((PageHeader) pw.page)->pd_lower;
		bh = (BM25DoclenBlockHdr *) dst;
		bh->count = (uint32) bcount;
		bh->first_docid_hi = (uint32) (first_docid >> 32);
		bh->first_docid_lo = (uint32) (first_docid & 0xFFFFFFFF);
		bh->gapbytes = (uint32) gapbytes;
		memcpy((char *) (bh + 1), gapscratch, gapbytes);
		memcpy((char *) (bh + 1) + gapbytes, bytes, bcount);
		((PageHeader) pw.page)->pd_lower += need;
	}
	pw_finish(&pw);
	pfree(arr);
	return first;
}

/* ---- doclen sidecar reader (format v4) -------------------------------------
 *
 * A resident, decoded copy of one segment's sidecar: ascending docids and their
 * quantized length bytes.  Loaded ONCE per (segment, scan) -- like tombstones
 * -- then binary-searched per scored posting.  Callers that need a doc's exact
 * length (scoring, merge) use bm25_doclen_lookup.
 */
typedef struct BM25Doclens
{
	uint64	   *docids;		/* ascending; NULL if the segment is v3 (inline) */
	uint8	   *bytes;			/* parallel to docids */
	int			n;
} BM25Doclens;

/* Load a segment's BM25_DOCLEN chain into a resident array.  doclenstart ==
 * Invalid (a v3 segment) yields an empty map (n=0, docids=NULL) -- the caller
 * then falls back to the inline posting doclen. */
static void
bm25_doclens_load(Relation index, BlockNumber doclenstart, BM25Doclens *d)
{
	BlockNumber blk = doclenstart;
	int			cap = 0;
	BlockNumber nblocks;
	uint32		visited = 0;

	d->docids = NULL;
	d->bytes = NULL;
	d->n = 0;
	if (doclenstart == InvalidBlockNumber)
		return;
	nblocks = RelationGetNumberOfBlocks(index);

	while (blk != InvalidBlockNumber)
	{
		Buffer		buf;
		Page		page;
		char	   *ptr,
				   *end;
		BlockNumber next;

		CHECK_FOR_INTERRUPTS();
		/*
		 * Concurrency guard (the A1 race): a scan reads the sidecar chain under
		 * only per-page SHARE locks off a metapage snapshot, so a concurrent
		 * merge/vacuum can free + recycle these pages mid-walk and leave a
		 * garbage nextblk that points anywhere (a cycle, a non-sidecar page, or
		 * out of range).  The caller discards + retries on a generation change,
		 * but this decode must not crash or spin first.  So: bound the walk to
		 * the relation's block count (no runaway/cycle) and skip any page that
		 * is no longer a BM25_DOCLEN page (a recycled/other-type page ends the
		 * walk).  Bounds inside the block loop already guard a torn page. */
		if (blk >= nblocks || visited++ > nblocks)
			break;
		buf = ReadBuffer(index, blk);
		LockBuffer(buf, BUFFER_LOCK_SHARE);
		page = BufferGetPage(buf);
		if (PageIsNew(page) ||
			!(BM25PageGetOpaque(page)->flags & BM25_DOCLEN))
		{
			UnlockReleaseBuffer(buf);
			break;
		}
		ptr = (char *) page + MAXALIGN(SizeOfPageHeaderData);
		end = bm25_page_data_end(page);
		next = BM25PageGetOpaque(page)->nextblk;

		while (ptr + sizeof(BM25DoclenBlockHdr) <= end)
		{
			BM25DoclenBlockHdr *bh = (BM25DoclenBlockHdr *) ptr;
			uint64		first_docid;
			uint64		gaps[BM25_BLOCK_SIZE];
			uint8	   *bytes;
			uint64		acc;
			int			j;
			char	   *blkend;

			/* bounds-guard a possibly-recycled/corrupt page (same contract as the
			 * dict/posting readers): a bad count/gapbytes must not run past end. */
			if (bh->count == 0 || bh->count > BM25_BLOCK_SIZE)
				break;
			blkend = (char *) (bh + 1) + bh->gapbytes + bh->count;
			if (blkend > end)
				break;
			first_docid = ((uint64) bh->first_docid_hi << 32) | bh->first_docid_lo;
			bm25_for_unpack((unsigned char *) (bh + 1), (int) bh->count, gaps);
			bytes = (uint8 *) ((char *) (bh + 1) + bh->gapbytes);

			if (d->n + (int) bh->count > cap)
			{
				/*
				 * This array holds EVERY docid in the segment, so at field scale it
				 * exceeds MaxAllocSize and plain palloc/repalloc throws "invalid
				 * memory alloc request size".  That is not a soft failure: this runs
				 * from merge_source_open(), so once an index is big enough EVERY
				 * merge, autovacuum cleanup and fts_vacuum fails, and the index can
				 * never be vacuumed or reclaimed again.
				 *
				 * Reproduced at ~1.3 M docs x 1660 terms/doc (the reported field
				 * shape): "invalid memory alloc request size 2550425176" from
				 * fts_vacuum AND from every autovacuum cleanup, matching the field's
				 * "VACUUM/merge do not reclaim bloat" report.  See
				 * CHANGELOG 1.7.0.
				 *
				 * The huge-allocation macros already existed and were used for the
				 * per-term posting arrays; this site was simply missed.
				 */
				cap = Max(cap * 2, d->n + (int) bh->count + 128);
				d->docids = d->docids
					? (uint64 *) FTS_REALLOC_MAYBE_HUGE(d->docids,
														(Size) cap * sizeof(uint64))
					: (uint64 *) FTS_ALLOC_MAYBE_HUGE((Size) cap * sizeof(uint64));
				d->bytes = d->bytes
					? (uint8 *) FTS_REALLOC_MAYBE_HUGE(d->bytes,
													   (Size) cap * sizeof(uint8))
					: (uint8 *) FTS_ALLOC_MAYBE_HUGE((Size) cap * sizeof(uint8));
			}
			acc = first_docid;
			for (j = 0; j < (int) bh->count; j++)
			{
				acc += gaps[j];		/* gaps[0] == 0 */
				d->docids[d->n] = acc;
				d->bytes[d->n] = bytes[j];
				d->n++;
			}
			ptr = (char *) MAXALIGN((char *) (bh + 1) + bh->gapbytes + bh->count);
		}
		UnlockReleaseBuffer(buf);
		blk = next;
	}
}

static void
bm25_doclens_free(BM25Doclens *d)
{
	if (d->docids)
		pfree(d->docids);
	if (d->bytes)
		pfree(d->bytes);
	d->docids = NULL;
	d->bytes = NULL;
	d->n = 0;
}

/* Exact per-doc length for a docid from the resident sidecar, or 0 if absent
 * (a v3 segment's empty map, or a docid not in the sidecar -- caller falls back
 * to the inline posting doclen).  Binary search over ascending docids. */
static inline uint32
bm25_doclen_lookup(const BM25Doclens *d, uint64 docid)
{
	int			lo = 0,
				hi = d->n - 1;

	while (lo <= hi)
	{
		int			mid = (lo + hi) >> 1;

		if (d->docids[mid] < docid)
			lo = mid + 1;
		else if (d->docids[mid] > docid)
			hi = mid - 1;
		else
			return fts_byte_to_doclen(d->bytes[mid]);
	}
	return 0;
}
/* ---- cursored doclen sidecar lookup (scan path) ----------------------------
 *
 * The doclen sidecar (v4) stores one quantized length byte per doc on a
 * BM25_DOCLEN page chain (128-doc blocks).  A ranked scan needs a doc's length
 * to score it, but doclen no longer travels with the posting, so the sidecar
 * must be probed by docid.  Two failed approaches bracket this one:
 *   - per-posting page walk (<=1.5.3): ~1 buffer per scored posting -> whole
 *     chain per query (16,887 buffers on a common term).
 *   - decode the WHOLE segment sidecar once per scan (1.5.4-1.5.7): a fixed
 *     ~18ms tax per ranked scan on a 2.19M-doc segment (534 page reads + a
 *     FOR-unpack of every block) that dwarfs rare/mid-term scoring -- the
 *     1.5.7 5-way regression (rare ranked 25ms vs 1.6ms inline).
 *
 * This is a PAGE-DIRECTORY cursor: a tiny (first_docid, blk) entry per sidecar
 * PAGE, built by walking only page HEADERS (no block decode), cached in the
 * relcache (rd_amcache, ONE contiguous chunk, keyed by metapage generation) so
 * it is built at most once per backend, not per scan.  A lookup binary-searches
 * the directory to the covering page, reads+decodes ONLY that page, and keeps
 * it resident (the WAND scan visits docids ascending, so consecutive lookups
 * usually hit the resident page).  Cost: O(log pages) + ~1 page read per ~128
 * scored docids, with 0 up-front full decode.  A v3 (inline-doclen) segment has
 * no sidecar (start == Invalid); its cursor returns 0 and the caller reads the
 * inline posting doclen.
 */
/*
 * Resident decoded doclen block, SHARED by every cursor of one scan that reads
 * the same segment sidecar.
 *
 * Each (term, segment) gets its own BM25DoclenCursor, but for a multi-term query
 * every cursor sitting at the scored pivot docid looks up THE SAME docid -- so
 * with per-cursor resident blocks an N-term match decoded the same sidecar block
 * N times.  Hoisting the resident block into a per-segment shared slot makes the
 * 2nd..Nth lookup of a docid a pure in-memory binary search.  Single-term scans
 * are unaffected (one cursor, one slot).
 */
typedef struct BM25DoclenResident
{
	BlockNumber blk;			/* block currently decoded, or Invalid */
	uint64	   *docid;			/* docids of the resident block (palloc'd) */
	uint8	   *byte;			/* parallel quantized bytes (palloc'd) */
	int			n;				/* docs decoded in the resident block */
	int			cap;			/* capacity of docid/byte */
	uint64		first;			/* lowest docid in the resident block */
	uint64		last;			/* highest docid in the resident block */
	int			hint;			/* resume index: the scan probes ASCENDING docids, so the
								 * next hit is usually at/just after the previous one */
} BM25DoclenResident;

typedef struct BM25DoclenCursor
{
	Relation	index;
	BlockNumber start;			/* sidecar chain head; Invalid = v3 (inline) */
	const uint64 *dir_docid;	/* per-page first docid, ascending (borrowed) */
	const BlockNumber *dir_blk;	/* per-page block number (parallel) */
	int			dir_n;			/* directory entries (= sidecar pages) */
	int			dir_hint;		/* last page index hit (ascending-resume) */
	BM25DoclenResident *res;	/* SHARED resident block for this segment (borrowed
								 * from the scan's per-segment slot; never freed
								 * by the cursor) */
} BM25DoclenCursor;

/*
 * Relation-level doclen page-directory cache (ONE contiguous chunk, the
 * rd_amcache single-chunk contract).  Layout: header, then for each live
 * sidecar segment its (first_docid[], blk[]) page directory, packed back to
 * back.  Rebuilt only when the metapage `generation` moves.  The whole thing is
 * a few KB (one 12-byte entry per sidecar PAGE, ~534 for a 2.19M-doc segment),
 * so a single palloc satisfies rd_amcache's "single chunk, pfree()d wholesale
 * on relcache invalidation" rule (the 1.5.4 20MB multi-chunk decoded array
 * violated it -- this does not).
 */
typedef struct BM25DoclenDir
{
	BlockNumber start;			/* segment doclenstart this directory describes */
	int			n;				/* number of pages (entries) */
	int			docid_off;		/* uint64 index into the packed docid[] region */
	int			blk_off;		/* BlockNumber index into the packed blk[] region */
} BM25DoclenDir;

typedef struct BM25DoclenDirCache
{
	uint32		generation;		/* metapage generation this cache was built at */
	int			nsegs;
	int			ndocid;			/* total entries across all segs (docid[] len) */
	BM25DoclenDir segs[BM25_MAX_SEGMENTS];
	/* packed regions follow in the SAME allocation: uint64 docid[ndocid] then
	 * BlockNumber blk[ndocid].  Accessed via the *_off indices above. */
	uint64		data[FLEXIBLE_ARRAY_MEMBER];
} BM25DoclenDirCache;

#define BM25_DOCLENDIR_DOCIDS(dc) ((dc)->data)
#define BM25_DOCLENDIR_BLKS(dc)   ((BlockNumber *) ((dc)->data + (dc)->ndocid))

/* Walk ONE segment's sidecar chain reading only page headers, appending a
 * (first_docid, blk) entry per page into docid[]/blk[] starting at *pos.
 * Returns the entry count for this segment. */
static int
bm25_doclendir_scan_seg(Relation index, BlockNumber start,
						uint64 *docid, BlockNumber *blk, int cap, int *pos)
{
	BlockNumber b = start;
	BlockNumber nblocks = RelationGetNumberOfBlocks(index);
	uint32		visited = 0;
	int			n = 0;

	while (b != InvalidBlockNumber && *pos < cap)
	{
		Buffer		buf;
		Page		page;
		char	   *ptr,
				   *end;
		BlockNumber next;

		CHECK_FOR_INTERRUPTS();
		if (b >= nblocks || visited++ > nblocks)
			break;
		buf = ReadBuffer(index, b);
		LockBuffer(buf, BUFFER_LOCK_SHARE);
		page = BufferGetPage(buf);
		if (PageIsNew(page) || !(BM25PageGetOpaque(page)->flags & BM25_DOCLEN))
		{
			UnlockReleaseBuffer(buf);
			break;
		}
		ptr = (char *) page + MAXALIGN(SizeOfPageHeaderData);
		end = bm25_page_data_end(page);
		next = BM25PageGetOpaque(page)->nextblk;
		/* the page's first docid = its first block's first_docid */
		if (ptr + sizeof(BM25DoclenBlockHdr) <= end)
		{
			BM25DoclenBlockHdr *bh = (BM25DoclenBlockHdr *) ptr;

			if (bh->count > 0 && bh->count <= BM25_BLOCK_SIZE)
			{
				docid[*pos] = ((uint64) bh->first_docid_hi << 32) | bh->first_docid_lo;
				blk[*pos] = b;
				(*pos)++;
				n++;
			}
		}
		UnlockReleaseBuffer(buf);
		b = next;
	}
	return n;
}

/* Count sidecar pages in a segment (header-only walk), to size the cache. */
static int
bm25_doclendir_count_seg(Relation index, BlockNumber start)
{
	BlockNumber b = start;
	BlockNumber nblocks = RelationGetNumberOfBlocks(index);
	uint32		visited = 0;
	int			n = 0;

	while (b != InvalidBlockNumber)
	{
		Buffer		buf;
		Page		page;
		BlockNumber next;

		CHECK_FOR_INTERRUPTS();
		if (b >= nblocks || visited++ > nblocks)
			break;
		buf = ReadBuffer(index, b);
		LockBuffer(buf, BUFFER_LOCK_SHARE);
		page = BufferGetPage(buf);
		if (PageIsNew(page) || !(BM25PageGetOpaque(page)->flags & BM25_DOCLEN))
		{
			UnlockReleaseBuffer(buf);
			break;
		}
		next = BM25PageGetOpaque(page)->nextblk;
		n++;
		UnlockReleaseBuffer(buf);
		b = next;
	}
	return n;
}

/*
 * Get the relcache page-directory cache, (re)building it as ONE chunk in
 * CacheMemoryContext if absent or stale (generation moved).  `meta` supplies
 * the live segment doclenstarts + generation.  Returns NULL if no v4 segment
 * has a sidecar (nothing to cache).
 */
static BM25DoclenDirCache *
bm25_doclendir_cache(Relation index, const BM25MetaPageData *meta)
{
	BM25DoclenDirCache *dc = (BM25DoclenDirCache *) index->rd_amcache;
	int			total = 0;
	uint32		s;
	int			pos = 0;
	Size		sz;
	MemoryContext old;

	if (dc != NULL && dc->generation == meta->generation)
		return dc;

	/* stale or absent: drop the old single chunk, rebuild */
	if (dc != NULL)
	{
		pfree(dc);
		index->rd_amcache = NULL;
		dc = NULL;
	}

	/* size: total sidecar pages across all v4 segments (header-only walk) */
	for (s = 0; s < meta->nsegments && s < BM25_MAX_SEGMENTS; s++)
		if (meta->segs[s].doclenstart != InvalidBlockNumber)
			total += bm25_doclendir_count_seg(index, meta->segs[s].doclenstart);
	if (total == 0)
		return NULL;			/* no v4 sidecar segment */

	/* one contiguous allocation: header + uint64 docid[total] + BlockNumber
	 * blk[total] (blk stored in the uint64 tail region, 2 BlockNumbers per
	 * uint64 slot would misalign -- keep it simple: allocate docid[] as uint64
	 * and blk[] as uint64-sized slots too, wasting 4B/entry but trivially small
	 * and single-chunk).  data[] holds total uint64 docids then total uint64
	 * slots each carrying one BlockNumber. */
	sz = offsetof(BM25DoclenDirCache, data) +
		(Size) total *sizeof(uint64) +		/* docid[] */
		(Size) total *sizeof(uint64);		/* blk[] (one BlockNumber per uint64 slot) */
	old = MemoryContextSwitchTo(CacheMemoryContext);
	dc = (BM25DoclenDirCache *) palloc0(sz);
	MemoryContextSwitchTo(old);
	dc->generation = meta->generation;
	dc->ndocid = total;
	dc->nsegs = 0;

	{
		uint64	   *docid = dc->data;
		BlockNumber *blk = (BlockNumber *) (dc->data + total);	/* NB: BlockNumber slots */

		for (s = 0; s < meta->nsegments && s < BM25_MAX_SEGMENTS; s++)
		{
			int			startpos = pos;
			int			n;

			if (meta->segs[s].doclenstart == InvalidBlockNumber)
				continue;
			n = bm25_doclendir_scan_seg(index, meta->segs[s].doclenstart,
										docid, blk, total, &pos);
			dc->segs[dc->nsegs].start = meta->segs[s].doclenstart;
			dc->segs[dc->nsegs].n = n;
			dc->segs[dc->nsegs].docid_off = startpos;
			dc->segs[dc->nsegs].blk_off = startpos;
			dc->nsegs++;
		}
	}
	index->rd_amcache = (void *) dc;
	return dc;
}

static void
bm25_doclen_cursor_init(BM25DoclenCursor *c, Relation index, BlockNumber start,
						BM25DoclenDirCache *dc, BM25DoclenResident *res)
{
	c->index = index;
	c->start = start;
	c->dir_docid = NULL;
	c->dir_blk = NULL;
	c->dir_n = 0;
	c->dir_hint = 0;
	c->res = NULL;

	if (start == InvalidBlockNumber || dc == NULL)
		return;					/* v3 segment (inline doclen) or no cache */

	{
		int			i;

		for (i = 0; i < dc->nsegs; i++)
			if (dc->segs[i].start == start)
			{
				c->dir_docid = BM25_DOCLENDIR_DOCIDS(dc) + dc->segs[i].docid_off;
				c->dir_blk = BM25_DOCLENDIR_BLKS(dc) + dc->segs[i].blk_off;
				c->dir_n = dc->segs[i].n;
				break;
			}
	}
	if (c->dir_n > 0 && res != NULL)
	{
		/* Attach the SHARED resident block for this segment.  Lazily size it to
		 * one 128-doc block (we decode only the block covering the sought docid,
		 * never a whole page). */
		if (res->docid == NULL)
		{
			res->cap = BM25_BLOCK_SIZE;
			res->docid = (uint64 *) palloc(res->cap * sizeof(uint64));
			res->byte = (uint8 *) palloc(res->cap * sizeof(uint8));
			res->blk = InvalidBlockNumber;
			res->n = 0;
			res->first = 0;
			res->last = 0;
			res->hint = 0;
		}
		c->res = res;
	}
}

static void
bm25_doclen_cursor_free(BM25DoclenCursor *c)
{
	/* the directory arrays are borrowed from the relcache cache and the resident
	 * block from the scan's per-segment slot -- nothing here is cursor-owned */
	c->dir_docid = NULL;
	c->dir_blk = NULL;
	c->dir_n = 0;
	c->res = NULL;
}

/* Decode the ONE sidecar block on page `blkno` whose docid range covers `docid`
 * into the cursor's resident arrays.
 *
 * A sidecar page holds many 128-doc blocks (~31 of them, ~4000 docs).  Decoding
 * the WHOLE page per lookup was a large amplification for a scattered rare term:
 * 10,875 postings spread over 2.19M docids touch essentially every sidecar page,
 * and decoding ~4000 entries to answer each lookup meant ~2.2M doc-decodes to
 * score 10,875 postings (~200x amplification; measured as ~7.9 ms of the 10.2 ms
 * rare-term ranked latency).  So: walk only the block HEADERS (first_docid +
 * count + gapbytes -- no FOR-unpack) to find the covering block, then unpack
 * that single block.  Same page read, ~31x less decode work, no format change.
 *
 * `res_first`/`res_last` record the resident block's docid range so the caller's
 * fast path can tell whether a later docid is still covered. */
static void
bm25_doclen_cursor_load_page(BM25DoclenCursor *c, BlockNumber blkno, uint64 docid)
{
	BM25DoclenResident *r = c->res;
	Buffer		buf;
	Page		page;
	char	   *ptr,
			   *end;
	char	   *cand = NULL;		/* best (largest first_docid <= docid) block */

	if (r == NULL)
		return;
	r->n = 0;
	r->blk = blkno;
	r->first = 0;
	r->last = 0;
	r->hint = 0;				/* new block: the ascending-resume hint restarts */
	if (blkno == InvalidBlockNumber || r->docid == NULL ||
		blkno >= RelationGetNumberOfBlocks(c->index))
		return;
	buf = ReadBuffer(c->index, blkno);
	LockBuffer(buf, BUFFER_LOCK_SHARE);
	page = BufferGetPage(buf);
	if (PageIsNew(page) || !(BM25PageGetOpaque(page)->flags & BM25_DOCLEN))
	{
		UnlockReleaseBuffer(buf);
		return;
	}
	end = bm25_page_data_end(page);

	/* pass 1: headers only -- find the last block whose first_docid <= docid */
	ptr = (char *) page + MAXALIGN(SizeOfPageHeaderData);
	while (ptr + sizeof(BM25DoclenBlockHdr) <= end)
	{
		BM25DoclenBlockHdr *bh = (BM25DoclenBlockHdr *) ptr;
		uint64		first;
		char	   *blkend;

		if (bh->count == 0 || bh->count > BM25_BLOCK_SIZE)
			break;
		blkend = (char *) (bh + 1) + bh->gapbytes + bh->count;
		if (blkend > end)
			break;
		first = ((uint64) bh->first_docid_hi << 32) | bh->first_docid_lo;
		if (first <= docid)
			cand = ptr;			/* still a candidate; a later block may be closer */
		else
			break;				/* blocks are docid-ascending: no later block fits */
		ptr = (char *) MAXALIGN(blkend);
	}

	/* pass 2: unpack ONLY the covering block */
	if (cand != NULL)
	{
		BM25DoclenBlockHdr *bh = (BM25DoclenBlockHdr *) cand;
		uint64		gaps[BM25_BLOCK_SIZE];
		uint8	   *bytes;
		uint64		acc;
		int			j;

		bm25_for_unpack((unsigned char *) (bh + 1), (int) bh->count, gaps);
		bytes = (uint8 *) ((char *) (bh + 1) + bh->gapbytes);
		acc = ((uint64) bh->first_docid_hi << 32) | bh->first_docid_lo;
		for (j = 0; j < (int) bh->count && r->n < r->cap; j++)
		{
			acc += gaps[j];		/* gaps[0] == 0 */
			r->docid[r->n] = acc;
			r->byte[r->n] = bytes[j];
			r->n++;
		}
		if (r->n > 0)
		{
			r->first = r->docid[0];
			r->last = r->docid[r->n - 1];
		}
	}
	UnlockReleaseBuffer(buf);
}

/* Exact doclen for docid via the page-directory cursor.  Robust to ANY docid
 * order; the ascending-resume hint makes the common monotone WAND scan land on
 * the resident page.  Returns 0 if absent (v3 cursor, or docid not present). */
static inline uint32
bm25_doclen_cursor_lookup(BM25DoclenCursor *c, uint64 docid)
{
	BM25DoclenResident *r = c->res;
	int			lo,
				hi,
				pg;

	if (c->dir_n == 0 || c->dir_docid == NULL || r == NULL)
		return 0;

	/* Fast path: docid is inside the resident BLOCK's range.  This now also hits
	 * when a DIFFERENT term's cursor of the same segment already decoded the
	 * block for this pivot docid (the multi-term win). */
	if (r->n > 0 && docid >= r->first && docid <= r->last)
	{
		/* fall through to the in-block search below */
	}
	else
	{
		/* binary-search the directory for the page whose first_docid <= docid
		 * (the largest such), with an ascending-resume hint */
		if (c->dir_hint < c->dir_n && c->dir_docid[c->dir_hint] <= docid)
			lo = c->dir_hint;
		else
			lo = 0;
		hi = c->dir_n - 1;
		pg = -1;
		while (lo <= hi)
		{
			int			mid = (lo + hi) >> 1;

			if (c->dir_docid[mid] <= docid)
			{
				pg = mid;
				lo = mid + 1;
			}
			else
				hi = mid - 1;
		}
		if (pg < 0)
			return 0;			/* docid precedes the first page's first docid */
		c->dir_hint = pg;
		bm25_doclen_cursor_load_page(c, c->dir_blk[pg], docid);
	}

	/*
	 * Locate docid within the resident block.  The WAND scan probes docids in
	 * strictly ASCENDING order, so the answer is usually at or just after the
	 * previous hit: try a short linear walk from the resume hint first and only
	 * fall back to a binary search when that misses (a seek, or a new block).
	 * Profiling showed the unconditional binary search here was ~45% of the
	 * common-term ranked query -- 7 branchy iterations per posting, on a term
	 * whose docids are consecutive.
	 */
	{
		int			rlo = 0,
					rhi = r->n - 1;
		int			i = r->hint;
		int			lim;

		if (i < 0 || i >= r->n)
			i = 0;
		lim = i + 8;
		if (lim > r->n)
			lim = r->n;
		for (; i < lim; i++)
		{
			if (r->docid[i] == docid)
			{
				r->hint = i + 1;
				return fts_byte_to_doclen(r->byte[i]);
			}
			if (r->docid[i] > docid)
				break;			/* overshot: docid is absent (gap) or behind us */
		}

		while (rlo <= rhi)
		{
			int			mid = (rlo + rhi) >> 1;

			if (r->docid[mid] < docid)
				rlo = mid + 1;
			else if (r->docid[mid] > docid)
				rhi = mid - 1;
			else
			{
				r->hint = mid + 1;
				return fts_byte_to_doclen(r->byte[mid]);
			}
		}
	}
	return 0;
}

/*
 * Write the dictionary: sorted (term, df, firstposting) entries packed into a
 * chain of dictionary pages.  Returns the first dictionary block, and via
 * *indexstart the first page of the sparse block index (Invalid if empty).
 */
/*
 * One dictionary record streamed into bm25_write_dictionary_iter: the term
 * bytes plus the metadata a BM25DictEntry needs.  `term` need only stay valid
 * until the iterator's next() call.
 */
typedef struct DictRec
{
	const char *term;
	int			len;
	uint32		df;
	uint32		max_tf;
	BlockNumber firstposting;
	uint32		firstoffset;
} DictRec;

/* Iterator: fill *r with the next term in sorted order, return false at end. */
typedef bool (*DictNextFn) (void *state, DictRec *r);

/*
 * Write a segment's on-disk dictionary (dict pages + sparse block index) by
 * pulling terms from an iterator in sorted order.  O(1) caller memory: the only
 * state retained across the stream is the per-DICT-PAGE block-index metadata
 * (one entry per ~8KB page, i.e. index_size/BLCKSZ entries -- tiny), including a
 * copy of each page's first term's bytes so the block-index pass needs no
 * random access back into the (possibly spilled) term stream.
 */
static BlockNumber
bm25_write_dictionary_iter(Relation index, DictNextFn next, void *nstate,
						   BlockNumber *indexstart)
{
	BlockNumber first = InvalidBlockNumber;
	Buffer		buffer = InvalidBuffer;
	GenericXLogState *state = NULL;
	Page		page = NULL;
	DictRec		r;

	/* block index: (blk, first-term bytes) per dict page -- bounded by #pages */
	BlockNumber *pgblk = NULL;
	char	  **pgfirst = NULL;	/* first term bytes of each page (palloc'd) */
	int		   *pgfirstlen = NULL;
	int			npages = 0;
	int			pgcap = 0;
	int			j;

	*indexstart = InvalidBlockNumber;

	while (next(nstate, &r))
	{
		Size		need = MAXALIGN(sizeof(BM25DictEntry) + r.len);
		char	   *dst;
		bool		newpage = false;

		CHECK_FOR_INTERRUPTS();		/* per-term; page-copy semantics keep it safe */

		if (buffer == InvalidBuffer ||
			((PageHeader) page)->pd_lower + need >
			BLCKSZ - sizeof(BM25PageOpaqueData))
		{
			Buffer		nextbuf = bm25_new_buffer(index);
			BlockNumber nextblk = BufferGetBlockNumber(nextbuf);

			if (buffer != InvalidBuffer)
			{
				BM25PageGetOpaque(page)->nextblk = nextblk;
				GenericXLogFinish(state);
				UnlockReleaseBuffer(buffer);
			}
			else
				first = nextblk;

			buffer = nextbuf;
			state = GenericXLogStart(index);
			page = GenericXLogRegisterBuffer(state, buffer, GENERIC_XLOG_FULL_IMAGE);
			bm25_init_page(page, BM25_DICT);
			newpage = true;
		}

		if (newpage)
		{
			if (npages >= pgcap)
			{
				pgcap = Max(pgcap * 2, 64);
				pgblk = pgblk ? repalloc(pgblk, pgcap * sizeof(BlockNumber))
					: palloc(pgcap * sizeof(BlockNumber));
				pgfirst = pgfirst ? repalloc(pgfirst, pgcap * sizeof(char *))
					: palloc(pgcap * sizeof(char *));
				pgfirstlen = pgfirstlen ? repalloc(pgfirstlen, pgcap * sizeof(int))
					: palloc(pgcap * sizeof(int));
			}
			pgblk[npages] = BufferGetBlockNumber(buffer);
			pgfirstlen[npages] = r.len;
			pgfirst[npages] = (char *) palloc(Max(r.len, 1));
			memcpy(pgfirst[npages], r.term, r.len);
			npages++;
		}

		dst = (char *) page + ((PageHeader) page)->pd_lower;
		{
			BM25DictEntry *de = (BM25DictEntry *) dst;

			de->termlen = r.len;
			de->df = r.df;
			de->max_tf = r.max_tf;
			de->firstposting = r.firstposting;
			de->firstoffset = r.firstoffset;
			memcpy(de->term, r.term, r.len);
		}
		((PageHeader) page)->pd_lower += need;
	}

	if (buffer != InvalidBuffer)
	{
		GenericXLogFinish(state);
		UnlockReleaseBuffer(buffer);
	}

	/* write the sparse block index: one entry per dict page, in term order */
	if (npages > 0)
	{
		BlockNumber ifirst = InvalidBlockNumber;
		Buffer		ib = InvalidBuffer;
		Page		ip = NULL;
		GenericXLogState *istate = NULL;

		for (j = 0; j < npages; j++)
		{
			int			flen = pgfirstlen[j];
			Size		need = MAXALIGN(offsetof(BM25DictIndexEntry, term) + flen);
			char	   *dst;
			BM25DictIndexEntry *ie;

			if (ib == InvalidBuffer ||
				((PageHeader) ip)->pd_lower + need >
				BLCKSZ - sizeof(BM25PageOpaqueData))
			{
				Buffer		nextbuf = bm25_new_buffer(index);
				BlockNumber nextblk = BufferGetBlockNumber(nextbuf);

				if (ib != InvalidBuffer)
				{
					BM25PageGetOpaque(ip)->nextblk = nextblk;
					GenericXLogFinish(istate);
					UnlockReleaseBuffer(ib);
				}
				else
					ifirst = nextblk;
				ib = nextbuf;
				istate = GenericXLogStart(index);
				ip = GenericXLogRegisterBuffer(istate, ib, GENERIC_XLOG_FULL_IMAGE);
				bm25_init_page(ip, BM25_DICTINDEX);
			}
			dst = (char *) ip + ((PageHeader) ip)->pd_lower;
			ie = (BM25DictIndexEntry *) dst;
			ie->blk = pgblk[j];
			ie->termlen = flen;
			memcpy(ie->term, pgfirst[j], flen);
			((PageHeader) ip)->pd_lower += need;
		}
		if (ib != InvalidBuffer)
		{
			GenericXLogFinish(istate);
			UnlockReleaseBuffer(ib);
		}
		*indexstart = ifirst;
	}
	for (j = 0; j < npages; j++)
		pfree(pgfirst[j]);
	if (pgblk)
		pfree(pgblk);
	if (pgfirst)
		pfree(pgfirst);
	if (pgfirstlen)
		pfree(pgfirstlen);

	return first;
}

/*
 * Iterator over an in-memory bs->terms[] (the segment-flush path): postings[]/
 * offsets[] carry the firstposting/firstoffset for each term.
 */
typedef struct DictArrayIter
{
	BM25BuildState *bs;
	BlockNumber *postings;
	uint32	   *offsets;
	int			i;
} DictArrayIter;

static bool
dict_array_next(void *st, DictRec *r)
{
	DictArrayIter *it = (DictArrayIter *) st;
	BuildTerm  *bt;

	if (it->i >= it->bs->nterms)
		return false;
	bt = &it->bs->terms[it->i];
	r->term = bt->term;
	r->len = bt->len;
	r->df = bt->nposts;
	r->max_tf = bt->max_tf;
	r->firstposting = it->postings[it->i];
	r->firstoffset = it->offsets[it->i];
	it->i++;
	return true;
}

/* Thin wrapper: write a dictionary from an in-memory bs->terms[] array. */
static BlockNumber
bm25_write_dictionary(Relation index, BM25BuildState *bs,
					  BlockNumber *postings, uint32 *offsets,
					  BlockNumber *indexstart)
{
	DictArrayIter it;

	it.bs = bs;
	it.postings = postings;
	it.offsets = offsets;
	it.i = 0;
	return bm25_write_dictionary_iter(index, dict_array_next, &it, indexstart);
}

/*
 * Iterator over an in-memory bs->terms[] yielding only term bytes (the trigram
 * writer needs term/len + the running ordinal; not postings/offsets).
 */
typedef struct DictTermArrayIter
{
	BM25BuildState *bs;
	int			i;
} DictTermArrayIter;

static bool
dict_term_array_next(void *st, DictRec *r)
{
	DictTermArrayIter *it = (DictTermArrayIter *) st;
	BuildTerm  *bt;

	if (it->i >= it->bs->nterms)
		return false;
	bt = &it->bs->terms[it->i];
	r->term = bt->term;
	r->len = bt->len;
	r->df = bt->nposts;
	r->max_tf = bt->max_tf;
	r->firstposting = InvalidBlockNumber;
	r->firstoffset = 0;
	it->i++;
	return true;
}

/* forward decl: trigram index writer (pg_fts_trgm_index.c, included below) */
static BlockNumber bm25_write_trigrams(Relation index, BM25BuildState *bs);
static BlockNumber bm25_write_trigrams_iter(Relation index, DictNextFn next,
											void *nstate);
/* forward decls: blob read/write live in pg_fts_trgm_index.c (included below) */
static BlockNumber bm25_write_blob(Relation index, const uint8 *data, Size len);
static uint8 *bm25_read_blob(Relation index, BlockNumber blk, Size len);

/*
 * Write one immutable segment (dictionary + postings + trigram index) from a
 * populated build state, filling *seg.  The build state's terms must already
 * be sorted.  livedocs starts empty (no tombstones); segments share the global
 * docid space via heap TIDs.
 */
static void
bm25_write_segment(Relation index, BM25BuildState *bs, BM25SegMeta *seg)
{
	BlockNumber *postings;
	uint32	   *offsets;
	BM25PostWriter pw;
	DoclenCollector dc;
	int			i;

	postings = (BlockNumber *) palloc(Max(bs->nterms, 1) * sizeof(BlockNumber));	/* alloc-ok: bs->nterms is a single build/pending segment, bounded by maintenance_work_mem (the merge path spills to disk instead) */
	offsets = (uint32 *) palloc(Max(bs->nterms, 1) * sizeof(uint32));	/* alloc-ok: see postings[] above */
	doclen_collector_init(&dc, CurrentMemoryContext, (long) bs->ndocs);
	pw_begin(&pw, index);
	pw.no_doclen_col = bs->want_sidecar;	/* v4: doclen -> sidecar; off = inline */
	for (i = 0; i < bs->nterms; i++)
	{
		BuildTerm  *bt = &bs->terms[i];
		int			p;

		/* per-term: safe to cancel here (GenericXLog works on a page copy, so a
		 * throw mid-write leaves on-disk pages untouched; unwind releases the
		 * buffer lock and leaks at most the new segment's pages) */
		CHECK_FOR_INTERRUPTS();
		/* collect each doc's length for the sidecar (idempotent per docid) */
		for (p = 0; p < bt->nposts; p++)
			doclen_collector_add(&dc, bm25_tid_to_docid(&bt->tids[p]), bt->doclens[p]);
		bm25_write_postings(&pw, bt, &postings[i], &offsets[i]);
	}
	pw_finish(&pw);

	MemSet(seg, 0, sizeof(BM25SegMeta));
	seg->dictstart = bm25_write_dictionary(index, bs, postings, offsets, &seg->dictindexstart);
	seg->trgmstart = bs->want_trigrams ? bm25_write_trigrams(index, bs)
		: InvalidBlockNumber;	/* trigrams opt-in (WITH (trigrams=on)); see bm25_index_wants_trigrams */
	seg->doclenstart = bs->want_sidecar ? bm25_write_doclen_sidecar(index, &dc) : InvalidBlockNumber;
	seg->livedocs = InvalidBlockNumber;
	seg->ndocs = bs->ndocs;
	seg->sumdoclen = bs->sumdoclen;
	seg->nterms = bs->nterms;
	seg->ndeleted = 0;
	seg->livedocslen = 0;
	hash_destroy(dc.ht);
	pfree(postings);
	pfree(offsets);
}

/*
 * Append a segment descriptor to the metapage directory and fold its doc stats
 * into the corpus totals.  Returns true on success, false if the fixed-size
 * directory is already full (BM25_MAX_SEGMENTS).  The caller must react to a
 * false return by merging to free a slot and retrying -- see
 * bm25_add_segment_with_room().  A full directory must NEVER become a failed
 * write: this is an index access method, and refusing an INSERT because merging
 * fell behind under load is an outage, not an acceptable limit.  (A field
 * deployment had to disable the index when live ingestion outran merging and
 * hit the old hard error here.)
 */
static bool
bm25_meta_add_segment(Relation index, const BM25SegMeta *seg)
{
	Buffer		buf = ReadBuffer(index, BM25_METAPAGE_BLKNO);
	GenericXLogState *state;
	Page		page;
	BM25MetaPageData *m;

	LockBuffer(buf, BUFFER_LOCK_EXCLUSIVE);
	state = GenericXLogStart(index);
	page = GenericXLogRegisterBuffer(state, buf, 0);
	bm25_meta_upcast_page(page);	/* v3 -> v4 in-place before any struct write */
	m = BM25PageGetMeta(page);
	if (m->nsegments >= BM25_MAX_SEGMENTS)
	{
		GenericXLogAbort(state);
		UnlockReleaseBuffer(buf);
		return false;			/* directory full: caller merges + retries */
	}
	m->segs[m->nsegments] = *seg;
	m->nsegments++;
	m->generation++;			/* directory changed: invalidate concurrent scan snapshots */
	m->ndocs += seg->ndocs;
	m->sumdoclen += seg->sumdoclen;
	GenericXLogFinish(state);
	UnlockReleaseBuffer(buf);
	return true;
}

/* forward decl: bounded merge that reduces the live segment count */
static void bm25_merge_segments(Relation index);
static bool bm25_merge_all(Relation index, bool try_parallel);
/* maintenance serialization (defined in the vacuum/merge section below) */
static inline void bm25_maintenance_lock(Relation index);
static inline void bm25_assert_merge_serialized(Relation index);
static inline bool bm25_maintenance_lock_conditional(Relation index);
static inline void bm25_maintenance_unlock(Relation index);

/*
 * Add a segment, guaranteeing the write cannot fail because the directory is
 * full.  If bm25_meta_add_segment reports no room, merge to free slots and
 * retry.  Merging k>=2 segments into one strictly reduces the count, and a full
 * directory always has >=2 mergeable segments, so a bounded number of merge
 * passes always makes room.  We escalate: the cheap bounded-fan-in
 * bm25_merge_segments first, then the more aggressive collapse if a concurrent
 * flurry of flushes keeps the directory full.  This runs OUTSIDE the metapage
 * lock (merging takes that lock itself), so concurrent inserters serialize
 * naturally on the actual add.
 */
static void
bm25_add_segment_with_room(Relation index, const BM25SegMeta *seg)
{
	int			try;

	if (bm25_meta_add_segment(index, seg))
		return;

	for (try = 0; try < BM25_MAX_SEGMENTS; try++)
	{
		/*
		 * Bounded-fan-in leveled merge first (cheapest); if that did not free a
		 * slot in time (a concurrent flush refilled it, or every level was at
		 * capacity so the leveled selector picked a small batch), fall back to
		 * the smallest-first collapse, which always reduces the count while any
		 * two segments remain.
		 *
		 * UNDER THE MAINTENANCE MUTEX, blocking.  Until 1.8.3 this site merged
		 * without it -- the only merger in the tree that did -- so a full
		 * directory on the insert path could run a merge CONCURRENTLY with
		 * autovacuum's.  Under extend-only allocation that was merely wasteful
		 * (two mergers never touched the same block).  Once merges reused freed
		 * pages, both mergers snapshotted the same free list, handed out the same
		 * block, and deadlocked on its buffer lock (observed: INSERT and
		 * autovacuum both in bm25_decode_term <- bm25_merge_segments_streaming,
		 * waiting on LWLock BufferContent, at row 680 of a 5,000-row round).
		 * Blocking rather than conditional is right here: this insert MUST make
		 * room or fail, and the other merger will free slots when it finishes.
		 */
		bm25_maintenance_lock(index);
		PG_TRY();
		{
			if ((try & 1) == 0)
				bm25_merge_segments(index);
			else
				bm25_merge_all(index, false);
		}
		PG_FINALLY();
		{
			bm25_maintenance_unlock(index);
		}
		PG_END_TRY();
		if (bm25_meta_add_segment(index, seg))
			return;
	}

	/*
	 * Unreachable in practice: a full directory always has >=2 segments to
	 * merge, and each successful merge frees a slot, so one of the retries above
	 * makes room unless another backend is adding segments faster than this one
	 * can merge for BM25_MAX_SEGMENTS passes.  If we somehow get here the data
	 * is intact (this segment simply is not yet in the directory); surface a
	 * clear error rather than silently drop it.
	 */
	ereport(ERROR,
			(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
			 errmsg("bm25 index \"%s\": could not free a segment-directory slot after %d merge passes",
					RelationGetRelationName(index), BM25_MAX_SEGMENTS),
			 errhint("Reduce write concurrency briefly or run fts_merge(), then retry.")));
}


/* ---- bounded, streaming k-way segment merge --------------------------------
 *
 * bm25_read_segment_into (above) decodes an ENTIRE segment's postings into the
 * build state; merging K segments that way buffers all their live postings at
 * once, so the final full compaction of a large index holds the whole index in
 * RAM and can OOM the server.  The streaming merge below bounds peak memory to
 * ONE term's merged postings at a time (plus the per-segment dictionary
 * metadata, which is small relative to the postings).
 *
 * Every segment's dictionary is written term-sorted (bm25_write_dictionary
 * emits bs->terms in cmp_buildterm order), so a merge is a k-way merge of
 * sorted streams: read each source's dictionary METADATA (term/df/firstposting/
 * firstoffset, no posting bodies), then sweep the distinct terms in sorted
 * order; for each term decode ONLY that term's postings from the segments that
 * carry it, tombstone-filter + merge into one single-term build state, write
 * that term's postings immediately, record its dict metadata, and free the
 * term's postings before advancing.  The rare huge stopword is covered by the
 * FTS_ALLOC_MAYBE_HUGE path in add_posting/bm25_write_postings.
 */
typedef struct MergeDictTerm
{
	char	   *term;			/* term bytes (points INTO the pinned dict page) */
	uint32		termlen;
	uint32		df;
	BlockNumber firstposting;
	uint32		firstoffset;
} MergeDictTerm;

/*
 * A merge source is a forward cursor over one segment's term-sorted dictionary.
 * It keeps only the CURRENT dict page pinned (~8KB) and exposes the current
 * term; the k-way merge peeks the current term of each source and advances the
 * ones carrying the smallest.  This keeps the merge's per-source footprint O(1)
 * (one page) instead of loading the segment's entire vocabulary into memory --
 * critical for a large, high-vocabulary corpus where the sum of all input
 * dictionaries would otherwise be many GB, unbounded by maintenance_work_mem.
 *
 * `cur` is valid (points into `curbuf`'s page) iff `valid`; the term bytes it
 * references stay live until the next merge_source_advance() on this source, so
 * the merge must consume/copy them (add_posting does) before advancing.
 */
typedef struct MergeSource
{
	Relation	index;
	BlockNumber nextblk;			/* next dict page to read, or Invalid */
	MergeDictTerm *page;			/* decoded entries of the current page (copied) */
	char	   *pagebytes;			/* backing store for this page's term bytes */
	int			npage;				/* entries in page[] */
	int			pcur;				/* index of current entry within page[] */
	int			pagecap;			/* capacity of page[]/pagebytes reuse */
	Size		bytescap;
	MergeDictTerm cur;				/* current term (points into pagebytes) */
	bool		valid;				/* cur holds a term (source not exhausted) */
	MemoryContext ctx;
	uint8	   *tombbuf;			/* tombstone bitmap blob, or NULL */
	sm_t		tomb;
	bool		hastomb;
	/*
	 * DENSE tombstone bitmap, decoded once from `tomb` when the source is opened.
	 *
	 * A merge walks terms in sorted order and each term's postings ascend from a
	 * low docid, so the docid sequence seen by the tombstone map resets at every
	 * term boundary.  Any sparsemap probe -- sm_contains, a resume cursor, the
	 * 8-way MRU cache, even the batched sm_contains_many -- pays an O(chunks)
	 * walk per term, and with millions of terms that product is what made VACUUM
	 * non-terminating (CHANGELOG 1.6.1).
	 *
	 * The map is READ-ONLY for the whole merge, so decode it once into a flat
	 * bitmap and test each posting in O(1).  Cost is ndocs/8 bytes per source
	 * (~267 KB for a 2.19M-doc segment), which is far cheaper than the walk it
	 * replaces and is bounded by the segment we are already reading.
	 */
	uint8	   *tombdense;			/* 1 bit per docid, NULL if !hastomb */
	uint64		tombdense_n;		/* docid capacity of tombdense (bits) */
	BM25Doclens doclens;			/* v4 source doclen sidecar (empty for v3) */
	bool		has_doclen_col;		/* v3 source: doclen inline in postings */
} MergeSource;

/*
 * Load the next dict page (src->nextblk) into src->page[] / src->pagebytes,
 * copying each entry's metadata and term bytes so the page buffer can be
 * released immediately (no page pin held across posting reads).  Skips empty
 * pages.  Sets src->npage = 0 and returns when the dictionary is exhausted.
 * page[]/pagebytes are sized by ONE page's contents (bounded by BLCKSZ), reused
 * across pages -- so a source's footprint stays O(one page), not O(vocabulary).
 */
static void
merge_source_load_page(MergeSource *src)
{
	MemoryContext old = MemoryContextSwitchTo(src->ctx);

	src->npage = 0;
	src->pcur = 0;

	while (src->npage == 0 && src->nextblk != InvalidBlockNumber)
	{
		Buffer		buffer;
		Page		page;
		char	   *ptr,
				   *end;
		BlockNumber next;
		int			n;
		Size		used;

		CHECK_FOR_INTERRUPTS();		/* between pages, no lock held across yields */
		buffer = ReadBuffer(src->index, src->nextblk);
		LockBuffer(buffer, BUFFER_LOCK_SHARE);
		page = BufferGetPage(buffer);
		ptr = (char *) PageGetContents(page);
		end = bm25_page_data_end(page);
		next = BM25PageGetOpaque(page)->nextblk;

		/*
		 * BOUNDS-GUARD pd_lower before walking, same contract as the posting and
		 * doclen readers.  pd_lower is read off the page and a recycled or corrupt
		 * page can report a bogus value; the walk then runs past the page, counts
		 * garbage entries with untrusted de->termlen, and the doubling below asks for
		 * an absurd allocation.  Observed as "invalid memory alloc request size
		 * 3406063183" (~142 M MergeDictTerm entries, where one 8 kB page can hold at
		 * most a few hundred) raised from this function, which is reached from
		 * bm25_merge_segments_streaming -- so it killed every merge, every autovacuum
		 * cleanup AND fts_vacuum on the affected index, matching the field's
		 * "VACUUM/merge do not reclaim bloat" report.
		 * Isolated with gdb; see CHANGELOG 1.7.0.
		 */
		/* count entries + term bytes on this page (bounded by BLCKSZ) */
		n = 0;
		used = 0;
		while (ptr < end)
		{
			BM25DictEntry *de = (BM25DictEntry *) ptr;
			Size		step;

			/* a truncated trailing entry, or one whose termlen runs past the page
			 * end, means the page is not a well-formed dict page: stop here. */
			if (ptr + offsetof(BM25DictEntry, term) > end)
				break;
			step = MAXALIGN(offsetof(BM25DictEntry, term) + de->termlen);
			if (step == 0 || ptr + step > end)
				break;
			n++;
			used += de->termlen;
			ptr += step;
		}

		if (n > src->pagecap)
		{
			src->pagecap = Max(n, src->pagecap ? src->pagecap * 2 : 256);
			src->page = src->page
				? repalloc(src->page, src->pagecap * sizeof(MergeDictTerm))
				: palloc(src->pagecap * sizeof(MergeDictTerm));
		}
		if (used > src->bytescap || (n > 0 && src->pagebytes == NULL))
		{
			/* floor at BLCKSZ so pagebytes is non-NULL for any n>0 page, even the
			 * degenerate all-zero-length-term case (avoids memcpy(NULL,...,0)) */
			src->bytescap = Max(Max(used, (Size) 1), src->bytescap ? src->bytescap * 2 : (Size) BLCKSZ);
			src->pagebytes = src->pagebytes
				? repalloc(src->pagebytes, src->bytescap)
				: palloc(src->bytescap);
		}

		/*
		 * Second walk MUST apply the identical bounds to the first, or it writes past
		 * the page[]/pagebytes the counting pass sized.  `end` is already clamped
		 * above; repeat the per-entry checks for the same reason.
		 */
		ptr = (char *) PageGetContents(page);
		used = 0;
		n = 0;
		while (ptr < end && n < src->pagecap)
		{
			BM25DictEntry *de = (BM25DictEntry *) ptr;
			MergeDictTerm *mt;
			Size		step;

			if (ptr + offsetof(BM25DictEntry, term) > end)
				break;
			step = MAXALIGN(offsetof(BM25DictEntry, term) + de->termlen);
			if (step == 0 || ptr + step > end)
				break;
			if (used + de->termlen > src->bytescap)
				break;			/* cannot happen given the sizing above; belt-and-braces */

			mt = &src->page[n++];
			mt->termlen = de->termlen;
			mt->df = de->df;
			mt->firstposting = de->firstposting;
			mt->firstoffset = de->firstoffset;
			mt->term = src->pagebytes + used;
			memcpy(mt->term, de->term, de->termlen);
			used += de->termlen;
			ptr += step;
		}
		src->npage = n;
		src->nextblk = next;
		UnlockReleaseBuffer(buffer);
	}

	if (src->npage > 0)
	{
		src->cur = src->page[0];
		src->valid = true;
	}
	else
		src->valid = false;

	MemoryContextSwitchTo(old);
}

/* Advance the cursor to the next term, loading the next page as needed. */
static void
merge_source_advance(MergeSource *src)
{
	src->pcur++;
	if (src->pcur < src->npage)
		src->cur = src->page[src->pcur];
	else
		merge_source_load_page(src);	/* refills page[], sets cur/valid */
}

/*
 * Open a merge source as a forward, page-at-a-time cursor over one segment's
 * term-sorted dictionary metadata (no posting bodies).  Positions it on the
 * first term.  Only one dict page's worth of metadata is resident at a time.
 */
static void
merge_source_open(Relation index, const BM25SegMeta *seg, MergeSource *src,
				  MemoryContext ctx)
{
	MemoryContext old = MemoryContextSwitchTo(ctx);

	src->index = index;
	src->ctx = ctx;
	src->nextblk = seg->dictstart;
	src->page = NULL;
	src->pagebytes = NULL;
	src->npage = 0;
	src->pcur = 0;
	src->pagecap = 0;
	src->bytescap = 0;
	src->valid = false;
	src->tombbuf = NULL;
	src->hastomb = false;

	/* v4 source: doclen lives in the segment sidecar, not the postings.  Load it
	 * once so the merge can re-attach each posting's exact length.  A v3 source
	 * (doclenstart Invalid) keeps has_doclen_col=true and reads it inline. */
	src->has_doclen_col = (seg->doclenstart == InvalidBlockNumber);
	bm25_doclens_load(index, seg->doclenstart, &src->doclens);

	src->tombdense = NULL;
	src->tombdense_n = 0;
	if (seg->livedocs != InvalidBlockNumber && seg->livedocslen > 0)
	{
		src->tombbuf = bm25_read_blob(index, seg->livedocs, seg->livedocslen);
		sm_open(&src->tomb, (uint8_t *) src->tombbuf, seg->livedocslen);
		src->hastomb = true;

		/*
		 * Decode the sparsemap ONCE into a dense bitmap (see the field comment).
		 * sm_next_member walks the map in a single forward pass, so building this
		 * is O(tombstones + chunks) -- paid once per source instead of per term.
		 */
		{
			/*
			 * Size by the LARGEST TOMBSTONED DOCID, not by ndocs: a docid is
			 * heap_block * MaxHeapTuplesPerPage + offset (bm25_tid_to_docid), i.e.
			 * a sparse GLOBAL address, so it is unrelated to a segment's live-doc
			 * count.  Sizing by ndocs would silently drop most tombstones.
			 */
			uint64		mx = sm_maximum(&src->tomb);
			uint64		cap;
			sm_cursor_t cur = SM_CURSOR_INIT;
			uint64		v;

			if (mx == SM_IDX_MAX)
				cap = 0;		/* empty map: nothing to decode */
			else
				cap = mx + 1;
			/* alloc-ok: (max tombstoned docid)/8 bytes, bounded by the heap we are
			 * already streaming; ~8 MB for a 2M-row table's docid space */
			src->tombdense = cap ? (uint8 *) MemoryContextAllocZero(src->ctx,
																	(Size) ((cap + 7) / 8))
				: NULL;
			src->tombdense_n = cap;
			for (v = sm_next_member(&src->tomb, (uint64_t) -1, &cur);
				 v != SM_IDX_MAX;
				 v = sm_next_member(&src->tomb, v, &cur))
			{
				if (v < cap)
					src->tombdense[v >> 3] |= (uint8) (1u << (v & 7));
			}
		}
	}

	merge_source_load_page(src);	/* position on the first term */
	MemoryContextSwitchTo(old);

}

/* Order two term keys the same way cmp_buildterm orders BuildTerms. */
static int
merge_cmp_term(const char *a, uint32 alen, const char *b, uint32 blen)
{
	uint32		min = Min(alen, blen);
	int			c = memcmp(a, b, min);

	if (c != 0)
		return c;
	return (int) alen - (int) blen;
}

/*
 * Dictionary-metadata spill for the streaming merge.  As the k-way merge
 * produces each output term (in sorted order) we append its dict record --
 * term bytes + df/max_tf/firstposting/firstoffset -- to a temp BufFile instead
 * of an in-memory array.  The whole merged VOCABULARY is thus never resident;
 * only one record at a time is, both when writing the spill and when streaming
 * it back into bm25_write_dictionary_iter and the trigram writer.  This is what
 * bounds the merge's memory on a huge, high-vocabulary corpus.
 *
 * Record layout: [int termlen][uint32 df][uint32 max_tf][BlockNumber fp]
 *                [uint32 fo][termlen term bytes].
 */
typedef struct DictSpill
{
	BufFile    *bf;
	char	   *tbuf;			/* reusable read buffer for term bytes */
	int			tcap;
	DictRec		cur;			/* last record read back (term points into tbuf) */
	int			ordinal;		/* ordinal of cur among all spilled records */
} DictSpill;

static void
dict_spill_begin(DictSpill *sp)
{
	sp->bf = BufFileCreateTemp(false);
	sp->tbuf = NULL;
	sp->tcap = 0;
	sp->ordinal = -1;
}

static void
dict_spill_write(DictSpill *sp, const DictRec *r)
{
	BufFileWrite(sp->bf, (void *) &r->len, sizeof(int));
	BufFileWrite(sp->bf, (void *) &r->df, sizeof(uint32));
	BufFileWrite(sp->bf, (void *) &r->max_tf, sizeof(uint32));
	BufFileWrite(sp->bf, (void *) &r->firstposting, sizeof(BlockNumber));
	BufFileWrite(sp->bf, (void *) &r->firstoffset, sizeof(uint32));
	if (r->len > 0)
		BufFileWrite(sp->bf, (void *) r->term, r->len);
}

/* Rewind to the start for a (re)read pass. */
static void
dict_spill_rewind(DictSpill *sp)
{
	if (BufFileSeek(sp->bf, 0, 0, SEEK_SET) != 0)
		ereport(ERROR,
				(errcode(ERRCODE_INTERNAL_ERROR),
				 errmsg("could not rewind pg_fts merge dictionary spill file")));
	sp->ordinal = -1;
}

/* DictNextFn over the spill: reads the next record into sp->cur. */
static bool
dict_spill_next(void *st, DictRec *out)
{
	DictSpill  *sp = (DictSpill *) st;
	size_t		n;

	n = BufFileReadMaybeEOF(sp->bf, &sp->cur.len, sizeof(int), true);
	if (n == 0)
		return false;			/* clean EOF */
	BufFileReadExact(sp->bf, &sp->cur.df, sizeof(uint32));
	BufFileReadExact(sp->bf, &sp->cur.max_tf, sizeof(uint32));
	BufFileReadExact(sp->bf, &sp->cur.firstposting, sizeof(BlockNumber));
	BufFileReadExact(sp->bf, &sp->cur.firstoffset, sizeof(uint32));
	if (sp->cur.len > sp->tcap)
	{
		sp->tcap = Max(sp->cur.len, sp->tcap ? sp->tcap * 2 : 256);
		sp->tbuf = sp->tbuf ? repalloc(sp->tbuf, sp->tcap) : palloc(sp->tcap);
	}
	if (sp->cur.len > 0)
		BufFileReadExact(sp->bf, sp->tbuf, sp->cur.len);
	sp->cur.term = sp->tbuf;
	sp->ordinal++;
	if (out != &sp->cur)
		*out = sp->cur;
	return true;
}

static void
dict_spill_end(DictSpill *sp)
{
	BufFileClose(sp->bf);
	if (sp->tbuf)
		pfree(sp->tbuf);
}


/*
 * Streaming k-way merge of the `chosen` segments into ONE new segment, bounded
 * to one term's postings at a time.  Writes the new segment's pages and fills
 * *seg (dictstart/dictindexstart) plus the corpus totals in bs (ndocs,
 * sumdoclen).  All allocations live in bs->ctx, which the caller owns.
 */
static void
bm25_merge_segments_streaming(Relation index, const BM25SegMeta *chosen,
							  uint32 nsel, BM25BuildState *bs, BM25SegMeta *seg)
{
	MergeSource *srcv;
	BM25PostWriter pw;
	DoclenCollector mergedc;		/* v4: docid->byte for the merged output segment */
	DictSpill	spill;			/* per-output-term dict metadata, spilled to disk */
	uint32		nout = 0;
	uint32		i;
	MemoryContext old = MemoryContextSwitchTo(bs->ctx);

	srcv = (MergeSource *) palloc0(nsel * sizeof(MergeSource));
	for (i = 0; i < nsel; i++)
	{
		bs->sumdoclen += chosen[i].sumdoclen;
		bs->ndocs += chosen[i].ndocs - chosen[i].ndeleted;
		merge_source_open(index, &chosen[i], &srcv[i], bs->ctx);
	}

	dict_spill_begin(&spill);

	pw_begin(&pw, index);
	pw.no_doclen_col = bs->want_sidecar;	/* v4 output: doclen -> sidecar; off = inline */
	doclen_collector_init(&mergedc, CurrentMemoryContext, 65536);

	for (;;)
	{
		const char *smterm = NULL;
		uint32		smlen = 0;
		MemoryContext termctx;
		MemoryContext told;
		BM25BuildState tbs;
		BuildTerm  *bt;
		BlockNumber fb;
		uint32		fo;

		CHECK_FOR_INTERRUPTS();		/* per output term; no lock/window held */

		/* smallest current term across all live cursors */
		for (i = 0; i < nsel; i++)
		{
			MergeSource *s = &srcv[i];

			if (!s->valid)
				continue;
			if (smterm == NULL ||
				merge_cmp_term(s->cur.term, s->cur.termlen,
							   smterm, smlen) < 0)
			{
				smterm = s->cur.term;
				smlen = s->cur.termlen;
			}
		}
		if (smterm == NULL)
			break;				/* all cursors exhausted */

		/* gather this term's postings from every segment that carries it into a
		 * fresh single-term build state in its own child context */
		termctx = AllocSetContextCreate(bs->ctx, "bm25 merge term",
										ALLOCSET_DEFAULT_SIZES);
		told = MemoryContextSwitchTo(termctx);

		/*
		 * Copy the smallest term into termctx-owned memory: smterm points into
		 * one source's page, which merge_source_advance() below overwrites as
		 * cursors advance, so we must not alias it during the gather loop.  Sized
		 * to the real term length (no fixed cap), freed with termctx each pass.
		 */
		{
			char	   *smcopy = (char *) palloc(Max(smlen, 1u));

			memcpy(smcopy, smterm, smlen);
			smterm = smcopy;
		}

		tbs.ctx = termctx;
		tbs.want_positions = bs->want_positions;
		tbs.want_trigrams = bs->want_trigrams;
		tbs.terms = NULL;
		tbs.nterms = 0;
		tbs.maxterms = 0;
		tbs.ndocs = 0;
		tbs.sumdoclen = 0;
		bm25_build_ht_init(&tbs);

		for (i = 0; i < nsel; i++)
		{
			MergeSource *s = &srcv[i];
			MergeDictTerm *mt;
			BM25Posting *post;
			uint32	   *posarena = NULL;
			int			np,
						k;

			if (!s->valid)
				continue;
			mt = &s->cur;
			if (merge_cmp_term(mt->term, mt->termlen, smterm, smlen) != 0)
				continue;		/* this segment lacks the smallest term */

			np = bm25_decode_term(index, mt->firstposting, mt->firstoffset,
								  mt->df, &post, NULL, bs->want_positions,
								  &posarena, false, s->has_doclen_col);
			for (k = 0; k < np; k++)
			{
				uint32		doclen = post[k].doclen;

				/*
				 * O(1) tombstone test against the dense bitmap decoded once when
				 * this source was opened.  Every sparsemap probe -- cursor, MRU
				 * cache, or batched sweep -- costs O(chunks) per term because the
				 * docid sequence restarts at each term boundary, and with millions
				 * of terms that product made VACUUM non-terminating.  See
				 * merge_source_open and CHANGELOG 1.6.1.
				 */
				if (s->hastomb)
				{
					uint64		dv = bm25_tid_to_docid(&post[k].tid);

					if (dv < s->tombdense_n &&
						(s->tombdense[dv >> 3] & (uint8) (1u << (dv & 7))) != 0)
						continue;	/* tombstoned: physically drop */
				}
				/* v4 source: post[k].doclen is 0 (no inline column); recover the
				 * exact length from the source's sidecar so the merged segment
				 * carries correct doclen (and re-quantizes it into its own sidecar). */
				if (!s->has_doclen_col)
					doclen = bm25_doclen_lookup(&s->doclens,
											   bm25_tid_to_docid(&post[k].tid));
				/* feed the merged segment's doclen sidecar (idempotent per docid) --
				 * WITHOUT this the merged sidecar is empty, doclenstart comes back
				 * Invalid, and the merged 2-column postings are then mis-read as
				 * inline (garbage doclen, WAND pruning defeated). */
				doclen_collector_add(&mergedc, bm25_tid_to_docid(&post[k].tid), doclen);
				add_posting(&tbs, mt->term, mt->termlen,
							&post[k].tid, post[k].tf, doclen,
							post[k].pos, post[k].pos ? (int) post[k].tf : 0);
			}
			pfree(post);
			if (posarena)
				pfree(posarena);
			merge_source_advance(s);	/* advance the cursors that matched this term */
		}
		MemoryContextSwitchTo(told);

		/* the term may have been entirely tombstoned away */
		if (tbs.nterms == 0)
		{
			MemoryContextDelete(termctx);
			continue;
		}
		Assert(tbs.nterms == 1);
		bt = &tbs.terms[0];

		/* write this term's postings now (sets bt->max_tf), then spill only its
		 * small dictionary metadata to disk and free the postings arena */
		bm25_write_postings(&pw, bt, &fb, &fo);

		{
			DictRec		rec;

			rec.term = bt->term;
			rec.len = bt->len;
			rec.df = bt->nposts;
			rec.max_tf = bt->max_tf;
			rec.firstposting = fb;
			rec.firstoffset = fo;
			dict_spill_write(&spill, &rec);
		}
		nout++;

		MemoryContextDelete(termctx);	/* frees this term's postings */
	}

	pw_finish(&pw);

	/*
	 * Emit the dictionary and trigram index by streaming the spilled per-term
	 * metadata back from disk -- one record resident at a time, so neither the
	 * merged vocabulary's dict metadata nor the term bytes are ever fully in
	 * memory.  bm25_write_trigrams_iter still accumulates its trigram->ordinal
	 * map (bounded by the vocabulary's trigram content, huge-safe), but no
	 * longer needs a resident bs->terms[] array.
	 */
	bs->nterms = (int) nout;

	MemSet(seg, 0, sizeof(BM25SegMeta));
	seg->doclenstart = bs->want_sidecar ? bm25_write_doclen_sidecar(index, &mergedc) : InvalidBlockNumber;
	hash_destroy(mergedc.ht);
	dict_spill_rewind(&spill);
	seg->dictstart = bm25_write_dictionary_iter(index, dict_spill_next, &spill,
												&seg->dictindexstart);
	if (bs->want_trigrams)
	{
		dict_spill_rewind(&spill);
		seg->trgmstart = bm25_write_trigrams_iter(index, dict_spill_next, &spill);
		/* both passes must consume exactly the nout spilled records; a mismatch would
		 * mean the trigram->term-ordinal mapping diverged from the dict write order */
		Assert(spill.ordinal + 1 == (int) nout);
	}
	else
		seg->trgmstart = InvalidBlockNumber;	/* trigrams opt-in; see bm25_index_wants_trigrams */
	seg->livedocs = InvalidBlockNumber;
	seg->ndocs = bs->ndocs;
	seg->sumdoclen = bs->sumdoclen;
	seg->nterms = bs->nterms;
	seg->ndeleted = 0;
	seg->livedocslen = 0;

	for (i = 0; i < nsel; i++)
		bm25_doclens_free(&srcv[i].doclens);

	dict_spill_end(&spill);
	MemoryContextSwitchTo(old);
}

/*
 * Recycle gate (format-preserving deletion-xid stamp).
 *
 * pg_fts frees a segment's pages to the FSM as soon as a merge/vacuum commits
 * the new directory.  But a concurrent scan (AccessShareLock does NOT conflict
 * with merge/vacuum's ShareUpdateExclusiveLock) may still be walking those
 * pages from a directory snapshot it took before the commit.  If the allocator
 * hands a just-freed page back to a concurrent inserter that overwrites it, the
 * scan reads garbage -> wrong result / "invalid memory alloc" / SIGSEGV (a
 * field-reported crash under concurrent read+insert+merge).
 *
 * Fix, mirroring nbtree's btpo.xact recycle gate: when a page is freed, stamp
 * it with the current next-XID and mark it BM25_FREED, then hand it to the FSM.
 * Before REUSING a free page, require that stamp to be "old enough" that no
 * snapshot which could still reference it remains (GlobalVisCheckRemovableXid);
 * otherwise skip the page and leave it in the FSM for later.  The XID lives in
 * the freed page's nextblk field (dead once the page is off every chain), so
 * the on-disk page layout is unchanged and existing indexes need no REINDEX; a
 * page freed by an older build lacks BM25_FREED and is recyclable at once.
 */
static void
bm25_free_page(Relation index, BlockNumber blk)
{
	Buffer		buf = ReadBuffer(index, blk);
	GenericXLogState *state;
	Page		page;
	BM25PageOpaque op;

	LockBuffer(buf, BUFFER_LOCK_EXCLUSIVE);
	state = GenericXLogStart(index);
	page = GenericXLogRegisterBuffer(state, buf, 0);
	op = BM25PageGetOpaque(page);
	op->flags |= BM25_FREED;
	/* reuse nextblk as the free-time XID horizon (page is now off all chains) */
	op->nextblk = (BlockNumber) ReadNextTransactionId();
	GenericXLogFinish(state);
	UnlockReleaseBuffer(buf);
	RecordFreeIndexPage(index, blk);
}

/*
 * May a page fetched from the free list be reused now?  True if it was not
 * gated by this mechanism (old-format free page, or a brand-new page), or if
 * its free-XID stamp is old enough that no in-progress scan can still hold a
 * directory snapshot referencing it.  `page` must be pinned + locked.
 */
static bool
bm25_page_recyclable(Relation index, Page page)
{
	BM25PageOpaque op;

	if (PageIsNew(page))
		return true;
	/*
	 * The recycle gate protects a CONCURRENT scan from reading a page we free
	 * and hand back to the allocator (the scan holds only AccessShareLock, which
	 * does not conflict with a merge/vacuum's ShareUpdateExclusiveLock).  It is
	 * safe to bypass ONLY when no concurrent scan can exist -- i.e. we hold
	 * AccessExclusiveLock on the index (CIC finalize, or fts_vacuum which now
	 * takes AccessExclusiveLock).  Under ShareUpdateExclusiveLock (autovacuum
	 * cleanup, plain VACUUM) a scan CAN be running, so the gate must stand even
	 * during compaction -- bypassing it there let fts_vacuum recycle a segment's
	 * pages while a concurrent reader was still copying them (e.g. a livedocs
	 * blob), corrupting the read and crashing (a rare SIGSEGV under heavy
	 * read+insert+merge+vacuum churn).  The lowfree/extend-only compaction
	 * state alone is NOT sufficient license to bypass; the LOCK is.
	 */
	op = BM25PageGetOpaque(page);

	/*
	 * LIVENESS FIRST, before any lock-based bypass.  A page without BM25_FREED is
	 * a LIVE page -- part of some segment's chain -- and must never be handed out,
	 * whatever the FSM says about it.  The FSM is a free-SPACE hint, not a
	 * liveness oracle: a partially filled live posting page can carry recorded
	 * free space, and until 1.8.3 this function returned true for exactly that
	 * case ("older free, or in-use race").  Harmless while merges were
	 * extend-only and never consulted the free list; fatal once they did.
	 * Observed: a live posting page (flags=0x4, nextblk=66, mid-chain) handed out
	 * as merge output while the same merge still held it pinned as input --
	 * self-deadlock on its buffer lock at row 1,184 of a 5,000-row churn round.
	 *
	 * Cost of the stricter rule: a page freed by a build older than the FREED
	 * flag is no longer reusable via the free list.  It is still reclaimed by
	 * bm25_truncate_free_tail when it sits in the tail, which is where old
	 * frees accumulate.  Safety over that corner.
	 */
	if (!(op->flags & BM25_FREED))
		return false;

	if ((bm25_alloc.lowfree != NULL || bm25_alloc.extend_only) &&
		CheckRelationLockedByMe(index, AccessExclusiveLock, true))
		return true;
	/*
	 * Is the freeing xid old enough that no snapshot can still reference this
	 * page?  Use the GLOBAL visibility horizon (NULL relation): the per-relation
	 * form wants the HEAP (an index has no xid horizon -- passing the index trips
	 * GlobalVisHorizonKindForRel's relkind assert under --enable-cassert, and is
	 * a latent API misuse in a non-assert build).  The global horizon is a sound
	 * upper bound -- it may keep a page unrecyclable slightly longer than a
	 * heap-scoped horizon would, never shorter -- so it is always safe here.
	 */
	return GlobalVisCheckRemovableXid(NULL, (TransactionId) op->nextblk);
}

/* Recycle a chained page list (dict/trigram/posting/data) to the FSM. */
static void
bm25_free_chain(Relation index, BlockNumber blk)
{
	while (blk != InvalidBlockNumber)
	{
		Buffer		buf = ReadBuffer(index, blk);
		BlockNumber next;

		LockBuffer(buf, BUFFER_LOCK_SHARE);
		next = BM25PageGetOpaque(BufferGetPage(buf))->nextblk;
		UnlockReleaseBuffer(buf);
		bm25_free_page(index, blk);
		blk = next;
	}
}

/* Free all pages of a segment (dict + each term's postings + trigram dir+data). */
static void
bm25_free_segment(Relation index, const BM25SegMeta *seg)
{
	BlockNumber blk = seg->dictstart;
	BlockNumber postchain = InvalidBlockNumber;

	/* dictionary pages; capture the shared posting chain's first block */
	while (blk != InvalidBlockNumber)
	{
		Buffer		buf = ReadBuffer(index, blk);
		Page		page;
		char	   *ptr,
				   *end;
		BlockNumber next;

		LockBuffer(buf, BUFFER_LOCK_SHARE);
		page = BufferGetPage(buf);
		ptr = (char *) PageGetContents(page);
		end = bm25_page_data_end(page);
		next = BM25PageGetOpaque(page)->nextblk;
		while (ptr < end)
		{
			BM25DictEntry *de = (BM25DictEntry *) ptr;
			Size		esize = MAXALIGN(offsetof(BM25DictEntry, term) + de->termlen);

			/* all terms share ONE posting chain; the first term names its head */
			if (postchain == InvalidBlockNumber)
				postchain = de->firstposting;
			ptr += esize;
		}
		UnlockReleaseBuffer(buf);
		bm25_free_page(index, blk);
		blk = next;
	}
	if (postchain != InvalidBlockNumber)
		bm25_free_chain(index, postchain);	/* free the shared posting chain once */

	/* trigram directory pages (+ their data blobs) */
	blk = seg->trgmstart;
	while (blk != InvalidBlockNumber)
	{
		Buffer		buf = ReadBuffer(index, blk);
		Page		page;
		char	   *ptr,
				   *end;
		BlockNumber next;

		LockBuffer(buf, BUFFER_LOCK_SHARE);
		page = BufferGetPage(buf);
		ptr = (char *) PageGetContents(page);
		end = bm25_page_data_end(page);
		next = BM25PageGetOpaque(page)->nextblk;
		while (ptr < end)
		{
			BM25TrgmEntry *te = (BM25TrgmEntry *) ptr;

			bm25_free_chain(index, te->firstdata);
			ptr += MAXALIGN(sizeof(BM25TrgmEntry));
		}
		UnlockReleaseBuffer(buf);
		bm25_free_page(index, blk);
		blk = next;
	}

	if (seg->livedocs != InvalidBlockNumber)
		bm25_free_chain(index, seg->livedocs);
	if (seg->dictindexstart != InvalidBlockNumber)
		bm25_free_chain(index, seg->dictindexstart);
	if (seg->doclenstart != InvalidBlockNumber)
		bm25_free_chain(index, seg->doclenstart);	/* v4 doclen sidecar */
}

/*
 * Size-tiered segment merge (a Lucene TieredMergePolicy in miniature).
 *
 * Rather than merging the whole directory into one segment on every trigger
 * (O(index) write amplification under steady inserts), we merge only a RUN of
 * similarly-sized segments at a time: sort the live segments by size (live doc
 * count) and, if the smallest ones fall within a size factor of each other,
 * merge just those into one new segment.  Small flushes coalesce cheaply while
 * large segments are rarely rewritten.  We loop until no tier qualifies and the
 * count is within budget, so query cost stays O(nsegments) small.  Tombstoned
 * docs are dropped as segments are read.  Called after a flush, from build, and
 * from VACUUM.
 */
#define BM25_MERGE_THRESHOLD 8		/* keep the live segment count at or below this */

/*
 * Leveled (HanoiDB/LSM-style) merge parameters.  A segment's LEVEL is derived
 * from its live size: level = floor(log_FANOUT(size)) (size in live docs).  Each
 * level holds up to BM25_MERGE_FANOUT runs; when a level fills, its runs are
 * merged into one that lands in the next level.  This bounds the fan-in of any
 * single merge to ~FANOUT segments -- unlike the old size-tiered selector, which
 * merged an entire same-size run at once (all ~N segments when a build produced
 * many near-equal segments), i.e. one giant single-backend pass over the whole
 * index.  Bounded fan-in gives O(N log N) total merge work with bounded write
 * amplification and small, discrete, observable merges.  Level is COMPUTED from
 * size (not stored), so there is no on-disk format change.
 */
#define BM25_MERGE_FANOUT 8			/* runs per level before it compacts + promotes */
#define BM25_MAX_LEVELS 24			/* FANOUT^24 = 8^24 docs -- far beyond any real corpus */

/* Derive a segment's level from its live doc count (level 0 = smallest). */
static int
bm25_seg_level(double livesize)
{
	double		s = livesize < 1.0 ? 1.0 : livesize;
	int			level = 0;
	double		cap = (double) BM25_MERGE_FANOUT;

	/* level L covers sizes [FANOUT^L, FANOUT^(L+1)); clamp to BM25_MAX_LEVELS-1 */
	while (s >= cap && level < BM25_MAX_LEVELS - 1)
	{
		cap *= (double) BM25_MERGE_FANOUT;
		level++;
	}
	return level;
}

/* segment (index,size) pair for sorting merge candidates by size */
typedef struct MergeCand
{
	uint32		idx;
	double		size;
}			MergeCand;

static int
cmp_mergecand(const void *a, const void *b)
{
	double		sa = ((const MergeCand *) a)->size;
	double		sb = ((const MergeCand *) b)->size;

	return (sa < sb) ? -1 : (sa > sb) ? 1 : 0;
}

/*
 * Merge one selected set of segments (by directory index) into a single new
 * segment, rewrite the metapage directory to drop the merged ones (preserving
 * the order of the rest) and append the new segment, then recycle the merged
 * segments' pages.  Returns true on success, false if the directory changed
 * underneath (caller stops).
 */
/*
 * Merge a specific set of segment descriptors (by CONTENT, not directory index)
 * into one new segment, writing its pages but NOT touching the metapage
 * directory.  Returns the new descriptor in *out.  Safe to run concurrently
 * with other callers merging DISJOINT descriptor sets: page appends are
 * serialized by the relation extension lock (in bm25_build_flush_segment's
 * peer path we lock explicitly; here bm25_write_segment appends under the same
 * discipline when IsInParallelMode()).  The caller (leader) removes the
 * consumed descriptors and installs *out in a single metapage update.
 */
static void
bm25_merge_group_to_seg(Relation index, const BM25SegMeta *group, uint32 ngroup,
						BM25SegMeta *out)
{
	BM25BuildState bs;

	bs.ctx = AllocSetContextCreate(CurrentMemoryContext, "bm25 merge group",
								   ALLOCSET_DEFAULT_SIZES);
	bs.want_positions = bm25_index_wants_positions(index);
	bs.want_trigrams = bm25_index_wants_trigrams(index);
	bs.want_sidecar = bm25_index_wants_doclen_sidecar(index);
	bs.terms = NULL;
	bs.nterms = 0;
	bs.maxterms = 0;
	bs.ndocs = 0;
	bs.sumdoclen = 0;

	/* Streaming k-way merge (bounded memory); page appends are serialized
	 * per-page inside bm25_new_buffer under the extension lock. */
	bm25_merge_segments_streaming(index, group, ngroup, &bs, out);
	out->ndocs = bs.ndocs;
	out->sumdoclen = bs.sumdoclen;

	MemoryContextDelete(bs.ctx);
}

static bool
bm25_merge_selected(Relation index, const uint32 *sel, uint32 nsel)
{
	BM25MetaPageData meta;
	BM25BuildState bs;
	BM25SegMeta newseg;
	BM25SegMeta chosen[BM25_MAX_SEGMENTS];
	uint32		i;
	double		indocs = 0;
	instr_time	t0;

	INSTR_TIME_SET_CURRENT(t0);

	{
		Buffer		mb = ReadBuffer(index, BM25_METAPAGE_BLKNO);

		LockBuffer(mb, BUFFER_LOCK_SHARE);
		bm25_meta_from_page(BufferGetPage(mb), &meta);
		UnlockReleaseBuffer(mb);
	}
	for (i = 0; i < nsel; i++)
	{
		if (sel[i] >= meta.nsegments)
			return false;		/* directory changed under us */
		chosen[i] = meta.segs[sel[i]];
		indocs += chosen[i].ndocs - chosen[i].ndeleted;
	}

	elog(DEBUG1, "pg_fts merge: index \"%s\": merging %u of %u segments (%.0f live docs) into one",
		 RelationGetRelationName(index), nsel, meta.nsegments, indocs);

	bs.ctx = AllocSetContextCreate(CurrentMemoryContext, "bm25 merge segs",
								   ALLOCSET_DEFAULT_SIZES);
	bs.want_positions = bm25_index_wants_positions(index);
	bs.want_trigrams = bm25_index_wants_trigrams(index);
	bs.want_sidecar = bm25_index_wants_doclen_sidecar(index);
	bs.terms = NULL;
	bs.nterms = 0;
	bs.maxterms = 0;
	bs.ndocs = 0;
	bs.sumdoclen = 0;

	/* Streaming k-way merge: bounded to one term's postings at a time, so a
	 * full compaction of a large index does not buffer the whole index in RAM
	 * (see bm25_merge_segments_streaming). */
	bm25_merge_segments_streaming(index, chosen, nsel, &bs, &newseg);
	newseg.ndocs = bs.ndocs;
	newseg.sumdoclen = bs.sumdoclen;

	{
		instr_time	t1;

		INSTR_TIME_SET_CURRENT(t1);
		INSTR_TIME_SUBTRACT(t1, t0);
		elog(DEBUG1, "pg_fts merge: index \"%s\": wrote merged segment (%d terms, %.0f docs) in %.1f s",
			 RelationGetRelationName(index), bs.nterms, bs.ndocs,
			 INSTR_TIME_GET_DOUBLE(t1));
	}

	{
		Buffer		mb = ReadBuffer(index, BM25_METAPAGE_BLKNO);
		GenericXLogState *state;
		Page		mp;
		BM25MetaPageData *m;
		bool		allfound = true;
		bool		consumed[BM25_MAX_SEGMENTS];

		LockBuffer(mb, BUFFER_LOCK_EXCLUSIVE);
		state = GenericXLogStart(index);
		mp = GenericXLogRegisterBuffer(state, mb, 0);
		bm25_meta_upcast_page(mp);	/* v3 -> v4 before struct write */
		m = BM25PageGetMeta(mp);

		/*
		 * Re-locate each chosen input segment by CONTENT (not by its old
		 * positional index) in the current directory.  A concurrent flush during
		 * this (possibly long) merge appends new segments and changes nsegments
		 * and shifts positions -- but our chosen inputs are immutable until we
		 * free them, so they are still present.  Matching by content lets the
		 * merge COMMIT alongside newly-flushed segments instead of aborting on
		 * any directory change (which, on a large corpus where each merge takes
		 * minutes and the scan keeps flushing, caused the merge to discard its
		 * output and re-read forever -- never converging).  We only abort if a
		 * chosen input is genuinely gone (another merge already consumed it).
		 */
		{
			uint32		j;

			memset(consumed, 0, sizeof(bool) * m->nsegments);
			for (i = 0; i < nsel; i++)
			{
				bool		found = false;

				for (j = 0; j < m->nsegments; j++)
				{
					if (!consumed[j] &&
						memcmp(&m->segs[j], &chosen[i], sizeof(BM25SegMeta)) == 0)
					{
						consumed[j] = true;	/* claim this slot for this input */
						found = true;
						break;
					}
				}
				if (!found)
				{
					allfound = false;
					break;
				}
			}
		}

		if (allfound)
		{
			BM25SegMeta kept[BM25_MAX_SEGMENTS];
			uint32		nkept = 0;
			uint32		j;

			/* keep every segment NOT consumed as an input, preserving order
			 * (this retains any segment a concurrent flush appended) */
			for (j = 0; j < m->nsegments; j++)
				if (!consumed[j])
					kept[nkept++] = m->segs[j];
			kept[nkept++] = newseg;	/* append the merged segment */
			memcpy(m->segs, kept, nkept * sizeof(BM25SegMeta));
			m->nsegments = nkept;
			m->generation++;	/* directory changed: invalidate concurrent scan snapshots */
			/* corpus totals unchanged (same docs, tombstones already excluded) */
			GenericXLogFinish(state);
			UnlockReleaseBuffer(mb);
			for (i = 0; i < nsel; i++)
				bm25_free_segment(index, &chosen[i]);
			IndexFreeSpaceMapVacuum(index);
			MemoryContextDelete(bs.ctx);
			return true;
		}
		else
		{
			/* an input was already consumed by another merge; abandon (the new
			 * segment leaks until the next merge/REINDEX -- rare) */
			GenericXLogAbort(state);
			UnlockReleaseBuffer(mb);
			MemoryContextDelete(bs.ctx);
			return false;
		}
	}
}

/*
 * Merge ALL live segments into a single segment (explicit full compaction).
 * Used by fts_merge() so an on-demand call actually produces an optimal,
 * single-segment index (the tiered bm25_merge_segments only coalesces
 * same-size tiers and may deliberately leave several segments).  Merges in
 * bounded batches (BM25_MAX_SEGMENTS worth of selection at a time is fine since
 * a build/merge never exceeds the cap) and loops until one segment remains.
 * Returns true if it changed anything.
 */
/* ---- parallel merge (compact many segments into few, in parallel) ----
 *
 * The leader partitions the live segments into W disjoint groups; each worker
 * merges ONE group into one new segment (bm25_merge_group_to_seg -- writes
 * pages only, no directory touch) and reports the new descriptor via DSM.  The
 * leader then performs a SINGLE metapage update: drop all the consumed source
 * descriptors and install the W new ones.  This confines the expensive
 * decode/re-encode to parallel workers and keeps the directory swap serial and
 * atomic (no concurrent-swap race).  Result: W segments; caller may run a
 * final (cheap, W-way) pass if it wants exactly one.
 *
 * Future work: Level-2 could recurse the parallel merge (W -> W/2 -> ... -> 1) so
 * even the final combine parallelizes; deferred -- one parallel pass already
 * removes the dominant per-segment decode cost from the serial path.
 */
#define PARALLEL_KEY_BM25_MERGE		UINT64CONST(0xB250000000000010)

typedef struct BM25MergeShared
{
	Oid			heaprelid;
	Oid			indexrelid;
	int			ngroups;		/* number of worker groups */
	int			nsrc;			/* total source segments */
	slock_t		mutex;
	/* filled by workers: the merged-segment descriptor per group */
	BM25SegMeta outseg[BM25_MAX_SEGMENTS];
	bool		outvalid[BM25_MAX_SEGMENTS];
	/* group layout: src[groupoff[g] .. groupoff[g+1]) are group g's sources */
	int			groupoff[BM25_MAX_SEGMENTS + 1];
	BM25SegMeta src[BM25_MAX_SEGMENTS];
}			BM25MergeShared;

static void bm25_merge_one_group(Relation index, BM25MergeShared *ms, int g);
static void bm25_merge_segments(Relation index);	/* size-tiered LSM merge (defined below) */

PGDLLEXPORT void bm25_parallel_merge_main(dsm_segment *seg, shm_toc *toc);

void
bm25_parallel_merge_main(dsm_segment *seg, shm_toc *toc)
{
	BM25MergeShared *ms;
	Relation	heap;
	Relation	index;

	ms = (BM25MergeShared *) shm_toc_lookup(toc, PARALLEL_KEY_BM25_MERGE, false);
	heap = table_open(ms->heaprelid, AccessShareLock);
	index = index_open(ms->indexrelid, RowExclusiveLock);

	/* worker N handles group (N+1); group 0 is the leader's */
	if (ParallelWorkerNumber + 1 < ms->ngroups)
		bm25_merge_one_group(index, ms, ParallelWorkerNumber + 1);

	index_close(index, RowExclusiveLock);
	table_close(heap, AccessShareLock);
}

/* merge group g's sources into one segment, store descriptor in shared state */
static void
bm25_merge_one_group(Relation index, BM25MergeShared *ms, int g)
{
	int			lo = ms->groupoff[g];
	int			hi = ms->groupoff[g + 1];
	BM25SegMeta out;

	if (hi - lo <= 0)
		return;
	if (hi - lo == 1)
	{
		/* singleton group: nothing to merge, keep the source as-is */
		ms->outseg[g] = ms->src[lo];
		ms->outvalid[g] = false;	/* signals "source kept, no new seg" */
		return;
	}
	bm25_merge_group_to_seg(index, &ms->src[lo], (uint32) (hi - lo), &out);
	SpinLockAcquire(&ms->mutex);
	ms->outseg[g] = out;
	ms->outvalid[g] = true;
	SpinLockRelease(&ms->mutex);
}

/*
 * Parallel merge-all: partition live segments into (workers+1) groups, each
 * participant merges its group into a new segment, then the leader installs the
 * results with a single metapage update.  Returns true if it ran (and did the
 * directory swap), false to signal the caller to fall back to serial.
 */
static bool
bm25_merge_all_parallel(Relation index, int request)
{
	ParallelContext *pcxt;
	BM25MergeShared *ms;
	BM25MetaPageData meta;
	Size		estms;
	int			ngroups;
	int			nsrc;
	int			g,
				i;
	Relation	heap;
	Oid			heaprelid;

	{
		Buffer		mb = ReadBuffer(index, BM25_METAPAGE_BLKNO);

		LockBuffer(mb, BUFFER_LOCK_SHARE);
		bm25_meta_from_page(BufferGetPage(mb), &meta);
		UnlockReleaseBuffer(mb);
	}
	if (meta.nsegments <= 2)
		return false;			/* not worth parallelizing; serial handles it */

	heaprelid = index->rd_index->indrelid;

	EnterParallelMode();
	pcxt = CreateParallelContext("pg_fts", "bm25_parallel_merge_main", request);
	estms = BUFFERALIGN(sizeof(BM25MergeShared));
	shm_toc_estimate_chunk(&pcxt->estimator, estms);
	shm_toc_estimate_keys(&pcxt->estimator, 1);
	InitializeParallelDSM(pcxt);

	if (pcxt->seg == NULL)
	{
		DestroyParallelContext(pcxt);
		ExitParallelMode();
		return false;
	}

	ms = (BM25MergeShared *) shm_toc_allocate(pcxt->toc, estms);
	ms->heaprelid = heaprelid;
	ms->indexrelid = RelationGetRelid(index);
	SpinLockInit(&ms->mutex);

	/* collect the live source segments */
	nsrc = 0;
	for (i = 0; i < (int) meta.nsegments; i++)
		if (meta.segs[i].dictstart != InvalidBlockNumber)
			ms->src[nsrc++] = meta.segs[i];
	ms->nsrc = nsrc;

	/* groups = min(participants, nsrc); participant 0 = leader */
	ngroups = request + 1;
	if (ngroups > nsrc)
		ngroups = nsrc;
	ms->ngroups = ngroups;

	/* even contiguous partition of the nsrc sources into ngroups */
	for (g = 0; g <= ngroups; g++)
		ms->groupoff[g] = (int) ((int64) g * nsrc / ngroups);
	for (g = 0; g < ngroups; g++)
		ms->outvalid[g] = false;

	shm_toc_insert(pcxt->toc, PARALLEL_KEY_BM25_MERGE, ms);
	LaunchParallelWorkers(pcxt);

	if (pcxt->nworkers_launched == 0)
	{
		WaitForParallelWorkersToFinish(pcxt);
		DestroyParallelContext(pcxt);
		ExitParallelMode();
		return false;			/* no workers; serial fallback */
	}

	/* leader merges group 0 itself while workers handle groups 1..n */
	heap = table_open(heaprelid, AccessShareLock);
	bm25_merge_one_group(index, ms, 0);
	table_close(heap, AccessShareLock);

	WaitForParallelWorkersToFinish(pcxt);

	/*
	 * Single atomic directory update: drop every consumed source descriptor
	 * (content-match) and install each group's merged descriptor.  Groups that
	 * did not actually merge (singleton) keep their one source, so we simply
	 * don't drop it.
	 */
	{
		Buffer		mb = ReadBuffer(index, BM25_METAPAGE_BLKNO);
		GenericXLogState *state;
		Page		mp;
		BM25MetaPageData *m;
		BM25SegMeta kept[BM25_MAX_SEGMENTS];
		uint32		nkept = 0;
		uint32		j;
		int			k;

		LockBuffer(mb, BUFFER_LOCK_EXCLUSIVE);
		state = GenericXLogStart(index);
		mp = GenericXLogRegisterBuffer(state, mb, 0);
		bm25_meta_upcast_page(mp);	/* v3 -> v4 before struct write */
		m = BM25PageGetMeta(mp);

		/* keep any segment that is NOT a consumed source of a merged group */
		for (j = 0; j < m->nsegments; j++)
		{
			bool		consumed = false;

			for (g = 0; g < ngroups && !consumed; g++)
			{
				if (!ms->outvalid[g])
					continue;	/* singleton group merged nothing */
				for (k = ms->groupoff[g]; k < ms->groupoff[g + 1]; k++)
					if (memcmp(&m->segs[j], &ms->src[k], sizeof(BM25SegMeta)) == 0)
					{
						consumed = true;
						break;
					}
			}
			if (!consumed)
				kept[nkept++] = m->segs[j];
		}
		/* append each merged group's new segment */
		for (g = 0; g < ngroups; g++)
			if (ms->outvalid[g])
				kept[nkept++] = ms->outseg[g];

		memcpy(m->segs, kept, nkept * sizeof(BM25SegMeta));
		m->nsegments = nkept;
		m->generation++;		/* directory changed: invalidate concurrent scan snapshots */
		GenericXLogFinish(state);
		UnlockReleaseBuffer(mb);

		/* recycle the consumed source segments' pages */
		for (g = 0; g < ngroups; g++)
			if (ms->outvalid[g])
				for (k = ms->groupoff[g]; k < ms->groupoff[g + 1]; k++)
					bm25_free_segment(index, &ms->src[k]);
	}

	DestroyParallelContext(pcxt);
	ExitParallelMode();
	IndexFreeSpaceMapVacuum(index);
	return true;
}

static bool
bm25_merge_all(Relation index, bool try_parallel)
{
	bool		didwork = false;
	int			guard;
	BM25AllocCtx prev_alloc;

	bm25_assert_merge_serialized(index);

	/*
	 * Try a parallel merge first (unless already inside a parallel operation,
	 * e.g. the parallel build leader -- no nested parallelism).  It compacts
	 * the sources into (workers+1) groups in one parallel pass; the serial
	 * loop below then finishes to a single segment.
	 *
	 * NB: iterating the parallel pass to one segment was measured WORSE at 2M
	 * (each pass rewrites data -> write amplification) and did not cut the
	 * tail: the final reduction is the write of ONE multi-GB output segment by
	 * a single backend, which no group-partition scheme parallelizes.  The
	 * merge tail is a single-output-write cost, not a parallelism-partition
	 * one -- see ROADMAP.md (codec / streamed-write direction).
	 */
	if (try_parallel && !IsInParallelMode() && max_parallel_maintenance_workers > 0)
	{
		int			request = Min(max_parallel_maintenance_workers,
								 max_parallel_workers);

		if (request > 0 && bm25_merge_all_parallel(index, request))
			didwork = true;
	}

	/* extend-only serial collapse (same recycle-race avoidance as
	 * bm25_merge_segments; freed inputs are reclaimed later) */
	prev_alloc = bm25_alloc_scope_enter(index, BM25_ALLOC_EXTEND_ONLY);

	PG_TRY();
	{
	for (guard = 0; guard < BM25_MAX_SEGMENTS; guard++)
	{
		BM25MetaPageData meta;
		MergeCand	cand[BM25_MAX_SEGMENTS];
		uint32		sel[BM25_MAX_SEGMENTS];
		uint32		nsel = 0;
		uint32		ncand = 0;
		uint32		i;

		{
			Buffer		mb = ReadBuffer(index, BM25_METAPAGE_BLKNO);

			LockBuffer(mb, BUFFER_LOCK_SHARE);
			bm25_meta_from_page(BufferGetPage(mb), &meta);
			UnlockReleaseBuffer(mb);
		}
		if (meta.nsegments <= 1)
			break;				/* already optimal */

		/*
		 * Collapse toward one segment in BOUNDED FAN-IN batches: sort populated
		 * segments by live size and merge the smallest <= BM25_MERGE_FANOUT of
		 * them each pass.  Merging all N at once (the old behavior) was a single
		 * multi-GB single-backend pass over the whole index -- on a large,
		 * high-vocabulary corpus that terminal merge is the field-reported
		 * non-converging "one segment rewritten forever".  Smallest-first bounded
		 * batches keep each pass cheap and observable (nsegments falls a bounded
		 * step per pass) and still reach a single segment.
		 */
		for (i = 0; i < meta.nsegments; i++)
			if (meta.segs[i].dictstart != InvalidBlockNumber)
			{
				cand[ncand].idx = i;
				cand[ncand].size = meta.segs[i].ndocs - meta.segs[i].ndeleted;
				if (cand[ncand].size < 1)
					cand[ncand].size = 1;
				ncand++;
			}
		if (ncand <= 1)
			break;
		qsort(cand, ncand, sizeof(MergeCand), cmp_mergecand);
		for (i = 0; i < ncand && nsel < BM25_MERGE_FANOUT; i++)
			sel[nsel++] = cand[i].idx;

		if (nsel < 2)
			break;
		if (!bm25_merge_selected(index, sel, nsel))
			break;				/* directory changed underneath; stop */
		didwork = true;
	}
	}
	PG_FINALLY();
	{
		bm25_alloc_scope_exit(prev_alloc);
	}
	PG_END_TRY();
	return didwork;
}

/*
 * Finalize an index BUILD's segment layout.
 *
 * The scan phase leaves many segments (each parallel participant flushes
 * several, budget-triggered).  Collapsing them all into ONE segment is optimal
 * for ranked-scan latency, but on a huge, high-vocabulary corpus that final
 * single-backend merge writes the entire multi-GB index in one shot and can run
 * for hours with no incremental progress -- the field-reported non-convergence.
 *
 * So finalize adaptively, LSM-style, and SERIALLY (no parallel merge context --
 * see the extension-lock hazard note in the body):
 *   1. Size-tiered merge (bm25_merge_segments) to a bounded, geometrically
 *      spread set -- always a bounded amount of work per merge, always
 *      converges.  The 1.1.1 O(N) trigram build made this tractable even on a
 *      huge, high-vocabulary corpus.
 *   2. Collapse to a single segment ONLY when the whole index is small enough
 *      (<= pg_fts.build_collapse_max_mb) that the single-backend collapse is
 *      quick.  Above that, stop at the bounded tiered set: the index is valid
 *      and queryable (ranked scans traverse a bounded handful of segments, a
 *      small fixed cost), and fts_merge() collapses to one on demand in a
 *      maintenance window.
 *
 * This makes a large build ALWAYS terminate in bounded, observable steps
 * (each bm25_merge_selected logs a DEBUG1 progress line) instead of a single
 * open-ended collapse.
 */
static void
bm25_build_finalize(Relation index)
{
	BlockNumber nblocks;
	uint64		sizemb;
	int			nseg;
	BM25MetaPageData meta;

	/*
	 * Bounded size-tiered merge (LSM), serial.  We do NOT start a parallel
	 * merge context here: this runs inside ambuild, after the build-scan's own
	 * parallel context was torn down (bm25_end_parallel), and re-entering
	 * parallel mode to merge a very large index inside ambuild -- especially
	 * under CREATE INDEX CONCURRENTLY on a busy, memory-pressured host -- risks
	 * wedging the leader in WaitForParallelWorkersToFinish while participants
	 * contend on / hold the relation-extension lock (a field-reported hang:
	 * leader parked in poll(), a sibling blocked on Lock:extend, indisvalid=f
	 * for hours).  The 1.1.1 O(N) trigram fix made the serial merge tractable,
	 * so the parallel pass is no longer needed for convergence; an explicit
	 * fts_merge() (run outside ambuild) still parallelizes on demand.
	 */
	/*
	 * Under the maintenance mutex, like every other merger.  A plain CREATE
	 * INDEX holds AccessExclusiveLock and nothing else can reach this index; a
	 * CREATE INDEX CONCURRENTLY holds only ShareUpdateExclusiveLock and a
	 * concurrent autovacuum CAN see the not-yet-valid index and merge it, so
	 * the mutex is required, not decorative.  Cheap here: uncontended in the
	 * common case.
	 */
	bm25_maintenance_lock(index);
	PG_TRY();
	{
	bm25_merge_segments(index);

	/*
	 * Collapse to one only if the whole index is small enough that the
	 * single-backend collapse is quick.  pg_fts.build_collapse_max_mb == 0 forces
	 * the historical always-collapse behavior for callers who want it.
	 */
	nblocks = RelationGetNumberOfBlocks(index);
	sizemb = ((uint64) nblocks * BLCKSZ) / (1024 * 1024);
	{
		Buffer		mb = ReadBuffer(index, BM25_METAPAGE_BLKNO);

		LockBuffer(mb, BUFFER_LOCK_SHARE);
		bm25_meta_from_page(BufferGetPage(mb), &meta);
		UnlockReleaseBuffer(mb);
	}
	nseg = (int) meta.nsegments;

	if (pg_fts_build_collapse_max_mb == 0 ||
		sizemb <= (uint64) pg_fts_build_collapse_max_mb)
	{
		if (nseg > 1)
			elog(DEBUG1, "pg_fts build: index \"%s\": collapsing %d segments to one (%lu MB <= collapse cap %d MB)",
				 RelationGetRelationName(index), nseg, (unsigned long) sizemb,
				 pg_fts_build_collapse_max_mb);
		bm25_merge_all(index, false);	/* serial: no parallel re-entry inside ambuild */
	}
	else
		elog(LOG, "pg_fts build: index \"%s\": leaving %d size-tiered segments (%lu MB > collapse cap %d MB); run fts_merge('%s') to collapse to one",
			 RelationGetRelationName(index), nseg, (unsigned long) sizemb,
			 pg_fts_build_collapse_max_mb, RelationGetRelationName(index));
	}
	PG_FINALLY();
	{
		bm25_maintenance_unlock(index);
	}
	PG_END_TRY();
}

/*
 * Full-compaction with tail truncation, for VACUUM FULL / an explicit
 * fts_vacuum().  Merge every live segment into one, biasing allocation toward
 * the lowest free blocks so live pages pack at the front; then truncate the
 * contiguous run of free blocks at the end of the file back to the OS.  This
 * is what reclaims the physical bloat left by ordinary merges (which recycle
 * freed pages to the FSM for later reuse but never shrink the relation).
 *
 * Single-writer only (holds a lock that excludes concurrent writers, e.g.
 * VACUUM's ShareUpdateExclusiveLock or CIC's AccessExclusiveLock).
 */

/*
 * Coalesce every live segment into a single segment, allocating either
 * low-first (extend_only=false: pack toward the front) or extend-only
 * (extend_only=true: write the whole output to fresh high blocks, vacating the
 * free region below).  Returns true if anything was written.  Not parallel:
 * the allocator hints are backend-scoped and compaction wants a deterministic
 * layout.
 */
static bool
bm25_compact_to_one(Relation index, bool extend_only)
{
	bool		didwork = false;
	int			guard;
	BM25AllocCtx prev_alloc;

	prev_alloc = bm25_alloc_scope_enter(index,
										extend_only ? BM25_ALLOC_EXTEND_ONLY
										: BM25_ALLOC_LOWFIRST);

	PG_TRY();
	{
		/* rewrite all live segments once (relocates their pages) ... */
		{
			BM25MetaPageData meta;
			uint32		sel[BM25_MAX_SEGMENTS];
			uint32		nsel = 0;
			uint32		i;
			Buffer		mb = ReadBuffer(index, BM25_METAPAGE_BLKNO);

			LockBuffer(mb, BUFFER_LOCK_SHARE);
			bm25_meta_from_page(BufferGetPage(mb), &meta);
			UnlockReleaseBuffer(mb);
			for (i = 0; i < meta.nsegments; i++)
				if (meta.segs[i].dictstart != InvalidBlockNumber)
					sel[nsel++] = i;
			if (nsel >= 1 && bm25_merge_selected(index, sel, nsel))
				didwork = true;
		}

		/* ... then coalesce any remaining segments down to one */
		for (guard = 0; guard < BM25_MAX_SEGMENTS; guard++)
		{
			BM25MetaPageData meta;
			uint32		sel[BM25_MAX_SEGMENTS];
			uint32		nsel = 0;
			uint32		i;
			Buffer		mb;

			CHECK_FOR_INTERRUPTS();	/* between merges (no lock/window held) */
			mb = ReadBuffer(index, BM25_METAPAGE_BLKNO);
			LockBuffer(mb, BUFFER_LOCK_SHARE);
			bm25_meta_from_page(BufferGetPage(mb), &meta);
			UnlockReleaseBuffer(mb);
			if (meta.nsegments <= 1)
				break;
			for (i = 0; i < meta.nsegments; i++)
				if (meta.segs[i].dictstart != InvalidBlockNumber)
					sel[nsel++] = i;
			if (nsel <= 1)
				break;
			if (!bm25_merge_selected(index, sel, nsel))
				break;
			didwork = true;
		}
	}
	PG_FINALLY();
	{
		bm25_alloc_scope_exit(prev_alloc);
	}
	PG_END_TRY();

	return didwork;
}

/* Truncate the contiguous run of free blocks at the end of the file back to
 * the OS.  Returns the new block count.  Scan is cancel-safe (no lock held). */
static BlockNumber
bm25_truncate_free_tail(Relation index)
{
	BlockNumber nblocks = RelationGetNumberOfBlocks(index);
	BlockNumber truncpoint = nblocks;
	BlockNumber blk;

	for (blk = nblocks; blk > 1; blk--)
	{
		CHECK_FOR_INTERRUPTS();		/* scan-only, no lock held */
		if (GetRecordedFreeSpace(index, blk - 1) >= BLCKSZ / 2)
			truncpoint = blk - 1;	/* free -> part of the truncatable tail */
		else
			break;				/* first live block from the end; stop */
	}
	if (truncpoint < nblocks)
	{
		FreeSpaceMapVacuumRange(index, truncpoint, nblocks);
		RelationTruncate(index, truncpoint);
		nblocks = truncpoint;
	}
	return nblocks;
}

/*
 * Is the index already at its compaction floor -- i.e. would a vacate+pack
 * rewrite be pure waste?  True only when BOTH:
 *   (1) the live data is already front-packed (negligible free space below the
 *       highest live block), so a rewrite would only re-grow then re-truncate
 *       to the same size, and
 *   (2) there is at most ONE live segment, so there is nothing to coalesce
 *       (fts_vacuum's other job is to merge segments to one for scan speed).
 * If either fails, the vacate+pack pass still has work to do.  Scan-only for
 * the FSM part; a brief shared lock on the metapage for the segment count.
 */
/*
 * Is there enough RECYCLABLE free space to hold the live data?
 *
 * bm25_vacuum_compact can only shrink the file by reusing existing free pages, and
 * bm25_page_recyclable() gates every candidate on GlobalVisCheckRemovableXid().  Pages
 * freed by the CURRENT transaction -- notably by the merge that cleanup just ran -- are
 * therefore all rejected, the allocator falls back to extending, and vacate+pack copies
 * the live data to fresh blocks while reclaiming nothing.
 *
 * Measured without this check (t/010, three cleanups, no rows added):
 *   nblocks=2366 freeblks=1500 gate=1 -> 4553 -> 6740 -> 8927, i.e. +2187 blocks
 *   (~3x the ~730 live blocks) EVERY pass, unbounded -- while an earlier pass whose
 *   free pages came from an older transaction shrank 1908 -> 615 correctly.
 *
 * The plain freeblks count that gates the caller cannot see this: it counts free space,
 * not *usable* free space.  Comparing usable against live is what distinguishes "this
 * pass will reclaim" from "this pass will just grow the file".
 *
 * Returns true when a compaction pass can be expected to make progress.
 */
static bool
bm25_have_recyclable_room(Relation index, BlockNumber live)
{
	BlockNumber nblocks = RelationGetNumberOfBlocks(index);
	BlockNumber blk;
	BlockNumber usable = 0;

	/*
	 * Make the FSM current first.  GetRecordedFreeSpace() reads the FSM, and a page
	 * freed by bulkdelete or by the merge above is not reflected there until the FSM
	 * is vacuumed -- so counting without this overstates `live`, the check says "not
	 * enough room", and a compaction that WOULD have reclaimed is skipped.  That is
	 * how an index with plenty of genuinely reclaimable space (post-DELETE) sat at
	 * 18 MB instead of falling to 4 MB.
	 */
	IndexFreeSpaceMapVacuum(index);

	/*
	 * `live` is supplied by the caller, which has just counted it, so this loop only
	 * has to find enough recyclable pages to cover it and can stop there.  That
	 * matters at scale: without the early exit this would ReadBuffer() every free
	 * block on a multi-GB index on every autovacuum cycle.
	 */
	for (blk = 1; blk < nblocks && usable < live; blk++)
	{
		Buffer		buf;
		bool		ok;

		CHECK_FOR_INTERRUPTS();
		if (GetRecordedFreeSpace(index, blk) < BLCKSZ / 2)
			continue;			/* in use, or too full to reuse */
		buf = ReadBuffer(index, blk);
		LockBuffer(buf, BUFFER_LOCK_SHARE);
		ok = bm25_page_recyclable(index, BufferGetPage(buf));
		UnlockReleaseBuffer(buf);
		if (ok)
			usable++;
	}

	/*
	 * Require room for the live data.  bm25_compact_to_one relocates the whole live
	 * segment, and if the recyclable pages cannot hold it the allocator extends for
	 * the remainder -- which for online cleanup is pure growth with no reclaim,
	 * because the relocated copy then sits at the top of the file where a tail
	 * truncate cannot reach it (verified: giveback prev=3095 packed=3824 back=3824,
	 * nothing recovered).
	 */
	return usable >= live;
}

static bool
bm25_index_is_compacted(Relation index)
{
	BlockNumber nblocks = RelationGetNumberOfBlocks(index);
	BlockNumber lastlive = 0;
	BlockNumber freebelow = 0;
	BlockNumber threshold;
	BlockNumber blk;
	uint32		nlive = 0;

	/* (2) segment count: only a single live segment counts as coalesced */
	{
		BM25MetaPageData meta;
		Buffer		mb = ReadBuffer(index, BM25_METAPAGE_BLKNO);
		uint32		i;

		LockBuffer(mb, BUFFER_LOCK_SHARE);
		bm25_meta_from_page(BufferGetPage(mb), &meta);
		UnlockReleaseBuffer(mb);
		for (i = 0; i < meta.nsegments; i++)
			if (meta.segs[i].dictstart != InvalidBlockNumber)
				nlive++;
	}
	if (nlive > 1)
		return false;				/* multiple segments: pack must coalesce */

	/* (1) front-packed: highest live block, then free-below count */
	for (blk = nblocks; blk > 1; blk--)
	{
		CHECK_FOR_INTERRUPTS();		/* scan-only, no lock held */
		if (GetRecordedFreeSpace(index, blk - 1) < BLCKSZ / 2)
		{
			lastlive = blk - 1;
			break;
		}
	}
	if (lastlive <= 1)
		return true;				/* empty / only the metapage: nothing to pack */

	/* count mostly-free blocks strictly below the last live block */
	for (blk = 1; blk < lastlive; blk++)
	{
		CHECK_FOR_INTERRUPTS();
		if (GetRecordedFreeSpace(index, blk) >= BLCKSZ / 2)
			freebelow++;
	}
	threshold = Max(nblocks / 50, 8);
	return freebelow <= threshold;
}

static bool
bm25_vacuum_compact(Relation index)
{
	BlockNumber startblocks;
	BlockNumber nblocks;
	BlockNumber prevblocks;
	bool		didwork = false;
	int			pass;

	/*
	 * Converge a bloated index to its size floor in ONE call, stably (repeated
	 * calls do not oscillate) and NEVER returning larger than we started.
	 *
	 * The hard case (verified): after ordinary merges the single live segment
	 * sits at the HIGH end of the file with the freed dead pages as a LOW free
	 * region, and that free region is SMALLER than the live segment (the file is
	 * >50% live).  A plain low-bias rewrite then fills the low free and EXTENDS
	 * the rest, so the new segment straddles the file and its tail is live --
	 * nothing is truncatable.  Iterating that rewrite just oscillates between two
	 * layouts and never reaches the floor.  (This is the "stable but never
	 * shrinks" defect; the earlier code instead oscillated and could end larger.)
	 *
	 * The fix is a two-phase relocation per pass, because a merge writes the new
	 * segment BEFORE freeing the old one (write-before-free, required for crash
	 * safety -- the old on-disk pages must stay valid until the metapage swap
	 * commits):
	 *
	 *   Phase 1 (VACATE): rewrite the segment EXTEND-ONLY, so the new copy lands
	 *     on fresh high blocks and the old pages -- wherever they were -- are all
	 *     freed.  The free region below the new (high) copy is now contiguous and
	 *     at least as large as the live segment.  The file grows transiently.
	 *
	 *   Phase 2 (PACK): rewrite the segment LOW-BIAS.  Its free list now includes
	 *     that whole low region (>= live size), so the copy fits entirely at the
	 *     front; the phase-1 high copy is freed and becomes a contiguous free
	 *     TAIL, which we truncate.  Result: front-packed at the floor.
	 *
	 * One vacate+pass reaches the floor in the common single-segment case; the
	 * loop re-checks and stops as soon as a pass stops shrinking, bounded by
	 * BM25_VACUUM_MAX_PASSES.  A final backstop guarantees we never return above
	 * the pre-call size even if the cap is hit mid-vacate.
	 *
	 * Single-writer only (holds a lock that excludes concurrent writers, e.g.
	 * VACUUM's ShareUpdateExclusiveLock or CIC's AccessExclusiveLock).
	 */
	startblocks = RelationGetNumberOfBlocks(index);
	prevblocks = startblocks;

	for (pass = 0; pass < BM25_VACUUM_MAX_PASSES; pass++)
	{
		CHECK_FOR_INTERRUPTS();		/* between passes: no lock/window held */

		/*
		 * Pre-pass convergence guard.  If the live data is already at the front
		 * of the file, a vacate+pack rewrite would only re-grow it and truncate
		 * back to the same floor -- pure waste, and the dominant cost on a large
		 * index (each rewrite streams the whole multi-GB segment through the
		 * buffer pool twice).  Just truncate any free tail and stop.  This makes
		 * a bloated index converge in ONE vacate+pack+truncate pass and an
		 * already-compact index a near-no-op (no rewrite at all).
		 */
		if (bm25_index_is_compacted(index))
		{
			nblocks = bm25_truncate_free_tail(index);
			if (nblocks < prevblocks)
				didwork = true;
			prevblocks = nblocks;
			break;
		}

		/*
		 * PACK-FIRST: try to relocate the live data into existing low free blocks
		 * WITHOUT extending the file at all.
		 *
		 * The two-phase vacate+pack below always works, but phase 1 deliberately
		 * extends by the live size before phase 2 moves data back down -- so a pass
		 * interrupted between them (autovacuum yields to any conflicting lock
		 * request) leaves that extension behind as permanent growth.  Measured at
		 * ~11 MB per interrupted pass on a small index with no rows added, and it is
		 * the reason a periodic manual fts_vacuum was still needed
		 * (CHANGELOG 1.7.0).
		 *
		 * When the file already holds enough low free space -- which is exactly the
		 * bloated case we are called for -- a single low-first pack reaches the same
		 * end state monotonically: the file only ever shrinks, so an interruption at
		 * any point is never a net cost.  A LOWFIRST scope hands out
		 * lowest-free-first and falls back to extending only if it runs out, and the
		 * bm25_page_recyclable() gate already makes low reuse safe under
		 * ShareUpdateExclusiveLock with concurrent scans running (phase 2 has always
		 * relied on both).
		 *
		 * If the pack alone did not shrink the file, fall through to vacate+pack for
		 * the case it cannot handle: too little low free space to hold the live data,
		 * where the transient extension is genuinely required to make progress.
		 */
		{
			BlockNumber packed;

			if (bm25_compact_to_one(index, false))
				didwork = true;
			IndexFreeSpaceMapVacuum(index);
			packed = bm25_truncate_free_tail(index);
			if (packed < prevblocks)
			{
				/* monotonic progress with no transient growth: done for this pass */
				didwork = true;
				nblocks = packed;
				prevblocks = nblocks;
				continue;
			}
		}

		/* Phase 1: vacate -- push the live segment onto fresh high blocks so the
		 * freed old pages form one contiguous low free region >= live size. */
		if (bm25_compact_to_one(index, true))
			didwork = true;
		IndexFreeSpaceMapVacuum(index);

		/* Phase 2: pack -- relocate the segment to the front (its free list now
		 * spans that whole low region), freeing the phase-1 high copy. */
		if (bm25_compact_to_one(index, false))
			didwork = true;
		IndexFreeSpaceMapVacuum(index);

		/* Truncate the free tail the pack phase left above the front-packed data. */
		nblocks = bm25_truncate_free_tail(index);
		if (nblocks < prevblocks)
			didwork = true;

		/* Converged: a full vacate+pack+truncate pass made no further progress. */
		if (nblocks >= prevblocks)
		{
			prevblocks = nblocks;
			break;
		}
		prevblocks = nblocks;
	}

	/*
	 * Backstop: never return larger than we started.  Phase 1 grows the file
	 * transiently; if the pass cap were somehow hit right after a vacate, the
	 * pack phase would still have run, but guard anyway by truncating any free
	 * tail down to at most the pre-call size.
	 */
	nblocks = RelationGetNumberOfBlocks(index);
	if (nblocks > startblocks)
	{
		BlockNumber truncpoint = nblocks;
		BlockNumber blk;

		for (blk = nblocks; blk > startblocks; blk--)
		{
			CHECK_FOR_INTERRUPTS();		/* scan-only, no lock held */
			if (GetRecordedFreeSpace(index, blk - 1) >= BLCKSZ / 2)
				truncpoint = blk - 1;
			else
				break;
		}
		if (truncpoint < nblocks)
		{
			FreeSpaceMapVacuumRange(index, truncpoint, nblocks);
			RelationTruncate(index, truncpoint);
			didwork = true;
		}
	}

	return didwork;
}

static void
bm25_merge_segments(Relation index)
{
	int			guard;
	BM25AllocCtx prev_alloc;

	bm25_assert_merge_serialized(index);

	/*
	 * Leveled (HanoiDB/LSM) compaction: each pass, assign every live segment a
	 * level from its size, and if any level holds >= BM25_MERGE_FANOUT runs,
	 * merge JUST that level's runs into one (which lands in the next level).
	 * Merging only one level at a time bounds the fan-in of any single merge to
	 * ~FANOUT segments, so no pass is ever the giant "merge all N segments at
	 * once" that the old size-tiered selector produced on a build of many
	 * near-equal segments.  The loop compacts the lowest over-capacity level
	 * first (cheapest), converging in O(log) passes; the guard bounds it (each
	 * successful merge strictly reduces nsegments).
	 *
	 * ALLOCATION MODE -- this choice is the difference between an index that
	 * stays near its live size under ingest and one that grows ~35-50 pages per
	 * document.
	 *
	 * The hazard: a merge frees its input pages to the FSM, and if the NEXT merge
	 * in this same loop took those blocks for its output while still reading
	 * input posting/dict chains -- whose on-page nextblk pointers may thread
	 * through a just-recycled block -- the result is a wrong read or a SIGBUS.
	 *
	 * Until 1.8.3 this used EXTEND_ONLY, which forbids ALL reuse.  That is exact
	 * against the hazard but over-approximates it badly: it also forbids reusing
	 * pages freed by EARLIER calls -- previous inserts' merges, already committed,
	 * with no reader of ours anywhere near them.  Because at high terms-per-doc
	 * every document mints a one-doc segment and triggers a merge, the merge is
	 * the dominant writer and its freed pages were reachable only by fts_vacuum.
	 * Measured: 34 pages/doc with one transaction per row, 49 with one statement
	 * for all rows, against ~0.5 pages/doc of real data; fts_vacuum recovered
	 * 65-95x.  The XID horizon was NOT the cause -- a fresh transaction per row
	 * changed it by only 1.4x -- the extend-only mode was.
	 *
	 * SNAPSHOT mode makes the guard exact instead of conservative: the free list
	 * is gathered ONCE here, before this call frees anything, and the loop hands
	 * out only from that snapshot, then extends.  It never re-consults the live
	 * FSM, so a page freed by merge N in this loop cannot be handed to merge N+1
	 * -- it is not in the snapshot.  Pages from previous calls ARE in it and are
	 * reused.  bm25_page_recyclable() still gates every one against concurrent
	 * scans holding directory snapshots, unchanged.
	 */
	prev_alloc = bm25_alloc_scope_enter(index, BM25_ALLOC_SNAPSHOT);

	PG_TRY();
	{
	for (guard = 0; guard < BM25_MAX_SEGMENTS; guard++)
	{
		BM25MetaPageData meta;
		uint32		sel[BM25_MAX_SEGMENTS];
		uint32		nsel = 0;
		int			lvlcount[BM25_MAX_LEVELS];
		int			target = -1;
		uint32		i;

		{
			Buffer		mb = ReadBuffer(index, BM25_METAPAGE_BLKNO);

			LockBuffer(mb, BUFFER_LOCK_SHARE);
			bm25_meta_from_page(BufferGetPage(mb), &meta);
			UnlockReleaseBuffer(mb);
		}
		if (meta.nsegments <= 1)
			break;

		/* count runs per level */
		memset(lvlcount, 0, sizeof(lvlcount));
		for (i = 0; i < meta.nsegments; i++)
		{
			if (meta.segs[i].dictstart == InvalidBlockNumber)
				continue;
			lvlcount[bm25_seg_level(meta.segs[i].ndocs - meta.segs[i].ndeleted)]++;
		}

		/* lowest level that is over capacity (>= FANOUT runs) is compacted first */
		for (i = 0; i < BM25_MAX_LEVELS; i++)
			if (lvlcount[i] >= BM25_MERGE_FANOUT)
			{
				target = (int) i;
				break;
			}

		/*
		 * If no level is over capacity but the total count still exceeds the
		 * budget, compact the lowest level that has >= 2 runs -- this bounds the
		 * live segment count (query cost) without ever selecting more than one
		 * level's worth (bounded fan-in).
		 */
		if (target < 0 && meta.nsegments > BM25_MERGE_THRESHOLD)
			for (i = 0; i < BM25_MAX_LEVELS; i++)
				if (lvlcount[i] >= 2)
				{
					target = (int) i;
					break;
				}

		if (target < 0)
			break;				/* every level within capacity + count OK */

		/* select up to BM25_MERGE_FANOUT smallest segments in the target level
		 * (bounded fan-in: never merge a whole over-full level at once, which for
		 * pg_fts's near-equal flushed segments would be an all-at-once pass) */
		{
			MergeCand	lc[BM25_MAX_SEGMENTS];
			uint32		nlc = 0;

			for (i = 0; i < meta.nsegments; i++)
			{
				double		sz;

				if (meta.segs[i].dictstart == InvalidBlockNumber)
					continue;
				sz = meta.segs[i].ndocs - meta.segs[i].ndeleted;
				if (bm25_seg_level(sz) != target)
					continue;
				lc[nlc].idx = i;
				lc[nlc].size = sz < 1 ? 1 : sz;
				nlc++;
			}
			qsort(lc, nlc, sizeof(MergeCand), cmp_mergecand);
			for (i = 0; i < nlc && nsel < BM25_MERGE_FANOUT; i++)
				sel[nsel++] = lc[i].idx;
		}

		if (nsel < 2)
			break;				/* nothing to do (shouldn't happen: count >= 2) */
		if (!bm25_merge_selected(index, sel, nsel))
			break;				/* directory changed underneath */
	}
	}
	PG_FINALLY();
	{
		bm25_alloc_scope_exit(prev_alloc);
	}
	PG_END_TRY();

	/*
	 * RECLAIM WHAT THIS MERGE ITSELF FREED, before returning.
	 *
	 * The loop above allocates extend-only (see the comment on that assignment:
	 * reusing a just-freed page while an in-flight read still threads through it
	 * risks a wrong read or SIGBUS).  That is correct for safety, but it means a
	 * merge always leaves the file larger than it found it -- and if the caller is
	 * then interrupted before it compacts (autovacuum yields to any conflicting
	 * lock request, "canceling autovacuum task"), the net effect of the pass is
	 * PURE GROWTH.  Measured before this fix: three consecutive VACUUMs on an
	 * insert-heavy index went 7,021 -> 7,734 -> 8,423 -> 9,111 MB, reclaiming
	 * nothing, while one fts_vacuum returned it to 344 MB.  A cancelled pass was
	 * strictly worse than no pass at all, which is what turned a missed
	 * optimisation into unbounded growth.  See
	 * CHANGELOG 1.7.0.
	 *
	 * Truncating our own free tail here fixes that at the source: it is O(free
	 * tail) with no data rewrite, it needs no extra lock (the caller already holds
	 * the maintenance lock), and it runs while the index stays fully online.  It
	 * reclaims only a CONTIGUOUS tail -- freed pages buried under live data still
	 * need the vacate+pack of bm25_vacuum_compact -- but it guarantees the
	 * invariant that matters: **a merge never leaves the index bigger than it
	 * found it**, so repeated cleanup passes make monotonic progress instead of
	 * monotonic growth, with or without a later compaction.
	 */
	(void) bm25_truncate_free_tail(index);
}

/* ---- parallel index build (level 1: parallel heap scan + per-worker segment
 * flush; the leader merges the workers' segments at the end) ---- */

#define PARALLEL_KEY_BM25_SHARED		UINT64CONST(0xB250000000000001)
#define PARALLEL_KEY_QUERY_TEXT			UINT64CONST(0xB250000000000002)
#define PARALLEL_KEY_WAL_USAGE			UINT64CONST(0xB250000000000003)
#define PARALLEL_KEY_BUFFER_USAGE		UINT64CONST(0xB250000000000004)

/*
 * Shared state for a parallel bm25 build, in the DSM segment.  Workers write
 * their own segments straight into the index (segments are self-contained and
 * appended to the metapage under its exclusive lock), so unlike a btree build
 * there is no central sort or result hand-off -- the only shared state is the
 * parallel table scan and a done-counter.
 */
typedef struct BM25Shared
{
	Oid			heaprelid;
	Oid			indexrelid;
	bool		isconcurrent;
	ConditionVariable workersdonecv;
	slock_t		mutex;
	int			nparticipantsdone;
	double		reltuples;
	/* ParallelTableScanDescData follows (alignment: allocated separately) */
}			BM25Shared;

#define ParallelTableScanFromBM25Shared(shared) \
	(ParallelTableScanDesc) ((char *) (shared) + BUFFERALIGN(sizeof(BM25Shared)))

typedef struct BM25Leader
{
	ParallelContext *pcxt;
	int			nparticipanttuplesorts;
	BM25Shared *bm25shared;
	Snapshot	snapshot;
	BufferUsage *bufferusage;
	WalUsage   *walusage;
}			BM25Leader;

/*
 * Run the heap scan (serial or, if pscan != NULL, a parallel slice) building
 * segments into `index`.  Returns the number of heap tuples this participant
 * saw.  Flushing the residual terms is left to the caller so the leader can
 * account the total before the final merge.
 */
static double
bm25_scan_and_build(Relation heap, Relation index, IndexInfo *indexInfo,
					BM25BuildState *bs, ParallelTableScanDesc pscan)
{
	TableScanDesc scan = NULL;

	if (pscan != NULL)
#if PG_VERSION_NUM >= 190000
		scan = table_beginscan_parallel(heap, pscan, SO_NONE);
#else
		scan = table_beginscan_parallel(heap, pscan);
#endif
	return table_index_build_scan(heap, index, indexInfo, true, true,
								  bm25_build_callback, (void *) bs, scan);
}

/*
 * Worker entry point (registered as "pg_fts"/"bm25_parallel_build_main").
 */
PGDLLEXPORT void bm25_parallel_build_main(dsm_segment *seg, shm_toc *toc);

void
bm25_parallel_build_main(dsm_segment *seg, shm_toc *toc)
{
	BM25Shared *bm25shared;
	Relation	heap;
	Relation	index;
	IndexInfo  *indexInfo;
	ParallelTableScanDesc pscan;
	BM25BuildState bs;
	LOCKMODE	heapLockmode;
	LOCKMODE	indexLockmode;
	double		reltuples;
	char	   *sharedquery;
	BufferUsage *bufferusage;
	WalUsage   *walusage;

	bm25shared = (BM25Shared *) shm_toc_lookup(toc, PARALLEL_KEY_BM25_SHARED, false);

	sharedquery = shm_toc_lookup(toc, PARALLEL_KEY_QUERY_TEXT, true);
	debug_query_string = sharedquery;

	if (!bm25shared->isconcurrent)
	{
		heapLockmode = ShareLock;
		indexLockmode = AccessExclusiveLock;
	}
	else
	{
		heapLockmode = ShareUpdateExclusiveLock;
		indexLockmode = RowExclusiveLock;
	}

	heap = table_open(bm25shared->heaprelid, heapLockmode);
	index = index_open(bm25shared->indexrelid, indexLockmode);
	indexInfo = BuildIndexInfo(index);
	indexInfo->ii_Concurrent = bm25shared->isconcurrent;

	/* report buffer/WAL usage so EXPLAIN ANALYZE etc. account worker I/O */
	bufferusage = shm_toc_lookup(toc, PARALLEL_KEY_BUFFER_USAGE, false);
	walusage = shm_toc_lookup(toc, PARALLEL_KEY_WAL_USAGE, false);
	InstrStartParallelQuery();

	pscan = ParallelTableScanFromBM25Shared(bm25shared);

	bs.ctx = AllocSetContextCreate(CurrentMemoryContext, "bm25 parallel worker",
								   ALLOCSET_DEFAULT_SIZES);
	bs.want_positions = bm25_index_wants_positions(index);
	bs.want_trigrams = bm25_index_wants_trigrams(index);
	bs.want_sidecar = bm25_index_wants_doclen_sidecar(index);
	bs.terms = NULL;
	bs.nterms = 0;
	bs.maxterms = 0;
	bs.ndocs = 0;
	bs.sumdoclen = 0;
	bs.flush_budget = 0;
	bs.nflushes = 0;
	bm25_build_ht_init(&bs);
	reltuples = bm25_scan_and_build(heap, index, indexInfo, &bs, pscan);
	bm25_build_flush_segment(index, &bs);	/* worker's residual -> a segment */
	MemoryContextDelete(bs.ctx);

	InstrEndParallelQuery(&bufferusage[ParallelWorkerNumber],
						  &walusage[ParallelWorkerNumber]);

	/* report done + this worker's tuple count */
	SpinLockAcquire(&bm25shared->mutex);
	bm25shared->nparticipantsdone++;
	bm25shared->reltuples += reltuples;
	SpinLockRelease(&bm25shared->mutex);
	ConditionVariableSignal(&bm25shared->workersdonecv);

	index_close(index, indexLockmode);
	table_close(heap, heapLockmode);
}

/*
 * Set up the parallel context, DSM shared state, and launch workers.  Returns
 * the leader struct, or NULL if no workers could be launched (fall back to a
 * serial build).
 */
static BM25Leader *
bm25_begin_parallel(Relation heap, Relation index, bool isconcurrent,
					int request)
{
	ParallelContext *pcxt;
	Snapshot	snapshot;
	Size		estbm25shared;
	Size		estscan;
	BM25Shared *bm25shared;
	ParallelTableScanDesc pscan;
	BM25Leader *bm25leader;
	BufferUsage *bufferusage;
	WalUsage   *walusage;
	char	   *sharedquery;
	int			querylen;
	bool		leaderparticipates = true;

	EnterParallelMode();
	Assert(request > 0);
	pcxt = CreateParallelContext("pg_fts", "bm25_parallel_build_main", request);

	if (!isconcurrent)
		snapshot = SnapshotAny;
	else
		snapshot = RegisterSnapshot(GetTransactionSnapshot());

	estbm25shared = BUFFERALIGN(sizeof(BM25Shared));
	estscan = table_parallelscan_estimate(heap, snapshot);
	shm_toc_estimate_chunk(&pcxt->estimator, estbm25shared + estscan);
	shm_toc_estimate_keys(&pcxt->estimator, 1);

	/* query text for worker debug/reporting */
	if (debug_query_string)
	{
		querylen = strlen(debug_query_string);
		shm_toc_estimate_chunk(&pcxt->estimator, querylen + 1);
		shm_toc_estimate_keys(&pcxt->estimator, 1);
	}
	else
		querylen = 0;

	shm_toc_estimate_chunk(&pcxt->estimator,
						   mul_size(sizeof(BufferUsage), pcxt->nworkers));
	shm_toc_estimate_keys(&pcxt->estimator, 1);
	shm_toc_estimate_chunk(&pcxt->estimator,
						   mul_size(sizeof(WalUsage), pcxt->nworkers));
	shm_toc_estimate_keys(&pcxt->estimator, 1);

	InitializeParallelDSM(pcxt);

	if (pcxt->seg == NULL)
	{
		if (IsMVCCSnapshot(snapshot))
			UnregisterSnapshot(snapshot);
		DestroyParallelContext(pcxt);
		ExitParallelMode();
		return NULL;
	}

	bm25shared = (BM25Shared *) shm_toc_allocate(pcxt->toc,
												 estbm25shared + estscan);
	bm25shared->heaprelid = RelationGetRelid(heap);
	bm25shared->indexrelid = RelationGetRelid(index);
	bm25shared->isconcurrent = isconcurrent;
	bm25shared->nparticipantsdone = 0;
	bm25shared->reltuples = 0.0;
	ConditionVariableInit(&bm25shared->workersdonecv);
	SpinLockInit(&bm25shared->mutex);

	pscan = ParallelTableScanFromBM25Shared(bm25shared);
	table_parallelscan_initialize(heap, pscan, snapshot);
	shm_toc_insert(pcxt->toc, PARALLEL_KEY_BM25_SHARED, bm25shared);

	if (debug_query_string)
	{
		sharedquery = (char *) shm_toc_allocate(pcxt->toc, querylen + 1);
		memcpy(sharedquery, debug_query_string, querylen + 1);
		shm_toc_insert(pcxt->toc, PARALLEL_KEY_QUERY_TEXT, sharedquery);
	}

	bufferusage = shm_toc_allocate(pcxt->toc,
								   mul_size(sizeof(BufferUsage), pcxt->nworkers));
	shm_toc_insert(pcxt->toc, PARALLEL_KEY_BUFFER_USAGE, bufferusage);
	walusage = shm_toc_allocate(pcxt->toc,
								mul_size(sizeof(WalUsage), pcxt->nworkers));
	shm_toc_insert(pcxt->toc, PARALLEL_KEY_WAL_USAGE, walusage);

	LaunchParallelWorkers(pcxt);

	if (pcxt->nworkers_launched == 0)
	{
		/* no workers actually started; caller will do a serial build */
		WaitForParallelWorkersToFinish(pcxt);
		if (IsMVCCSnapshot(snapshot))
			UnregisterSnapshot(snapshot);
		DestroyParallelContext(pcxt);
		ExitParallelMode();
		return NULL;
	}

	bm25leader = (BM25Leader *) palloc0(sizeof(BM25Leader));
	bm25leader->pcxt = pcxt;
	bm25leader->nparticipanttuplesorts = pcxt->nworkers_launched;
	if (leaderparticipates)
		bm25leader->nparticipanttuplesorts++;
	bm25leader->bm25shared = bm25shared;
	bm25leader->snapshot = snapshot;
	bm25leader->bufferusage = bufferusage;
	bm25leader->walusage = walusage;
	return bm25leader;
}

/*
 * Wait for all workers to finish, accumulate their I/O stats + tuple count,
 * and tear down.  Returns the total heap tuples the workers scanned (read from
 * the DSM before it is unmapped).
 */
static double
bm25_end_parallel(BM25Leader *bm25leader)
{
	int			i;
	double		worker_tuples;

	WaitForParallelWorkersToFinish(bm25leader->pcxt);

	for (i = 0; i < bm25leader->pcxt->nworkers_launched; i++)
		InstrAccumParallelQuery(&bm25leader->bufferusage[i], &bm25leader->walusage[i]);

	/* read the workers' accumulated tuple count while the DSM is still mapped */
	worker_tuples = bm25leader->bm25shared->reltuples;

	if (IsMVCCSnapshot(bm25leader->snapshot))
		UnregisterSnapshot(bm25leader->snapshot);
	DestroyParallelContext(bm25leader->pcxt);
	ExitParallelMode();
	return worker_tuples;
}

static IndexBuildResult *
bm25_build(Relation heap, Relation index, IndexInfo *indexInfo)
{
	IndexBuildResult *result;
	BM25BuildState bs;
	double		reltuples;
	BM25Leader *bm25leader = NULL;

	if (RelationGetNumberOfBlocks(index) != 0)
		elog(ERROR, "index \"%s\" already contains data",
			 RelationGetRelationName(index));

	/* metapage must be block 0 -- write it before workers or the scan touch it */
	bm25_init_metapage(index);

	/* Try a parallel build if the planner requested workers. */
	if (indexInfo->ii_ParallelWorkers > 0)
		bm25leader = bm25_begin_parallel(heap, index, indexInfo->ii_Concurrent,
										 indexInfo->ii_ParallelWorkers);

	bs.ctx = AllocSetContextCreate(CurrentMemoryContext, "bm25 build",
								   ALLOCSET_DEFAULT_SIZES);
	bs.want_positions = bm25_index_wants_positions(index);
	bs.want_trigrams = bm25_index_wants_trigrams(index);
	bs.want_sidecar = bm25_index_wants_doclen_sidecar(index);
	bs.terms = NULL;
	bs.nterms = 0;
	bs.maxterms = 0;
	bs.ndocs = 0;
	bs.sumdoclen = 0;
	bs.flush_budget = 0;
	bs.nflushes = 0;
	bm25_build_ht_init(&bs);

	if (bm25leader != NULL)
	{
		/*
		 * Parallel build: the leader also scans a slice (leaderparticipates),
		 * using the same shared parallel scan the workers use, and flushes its
		 * residual as a segment.  Workers write their own segments directly.
		 */
		ParallelTableScanDesc pscan =
			ParallelTableScanFromBM25Shared(bm25leader->bm25shared);

		reltuples = bm25_scan_and_build(heap, index, indexInfo, &bs, pscan);
		bm25_build_flush_segment(index, &bs);

		/* add the workers' tuple counts BEFORE tearing down the DSM */
		reltuples += bm25_end_parallel(bm25leader);

		/*
		 * Finalize the participants' segments.  Rather than always collapsing to
		 * a single segment (a single-backend O(index) merge that does not converge
		 * in bounded time on a huge, high-vocabulary corpus), bm25_build_finalize
		 * runs a serial bounded size-tiered merge and collapses to one only when the
		 * index is small enough (pg_fts.build_collapse_max_mb).  A large build thus
		 * always terminates, leaving a bounded tiered set; fts_merge() collapses to
		 * one on demand.  It does NOT start a parallel merge context inside ambuild
		 * (that risked wedging CONCURRENTLY builds on large/pressured hosts).
		 */
		bm25_build_finalize(index);
	}
	else
	{
		/* Serial build. */
		reltuples = bm25_scan_and_build(heap, index, indexInfo, &bs, NULL);
		bm25_build_flush_segment(index, &bs);

		/*
		 * Same adaptive finalization as the parallel path (a serial build makes
		 * fewer segments, so this usually collapses to one; a very large serial
		 * build stays tiered rather than spinning on an open-ended collapse).
		 */
		bm25_build_finalize(index);
	}

	/*
	 * Reclaim the free tail the end-of-build merge left on disk.  The merge
	 * writes the merged output before freeing the input segments (write-before-
	 * free, for crash safety), so freed input pages accumulate but the file is
	 * never shrunk during a build (only fts_vacuum truncates).  Truncating the
	 * contiguous free tail reclaims what the final merge leaves above the
	 * front-packed data -- substantial on a parallel build (freed tail present),
	 * a no-op when the free space is interior (a serial single-segment layout);
	 * fully compacting a freshly built index still needs fts_vacuum.  We hold the
	 * index AccessExclusiveLock and any parallel workers are already torn down
	 * (bm25_end_parallel), and during ambuild the index is not yet visible to
	 * other backends (indisready=false, even under CONCURRENTLY), so this backend
	 * is the sole writer -- truncating the free tail is safe.
	 */
	bm25_truncate_free_tail(index);

	MemoryContextDelete(bs.ctx);

	result = (IndexBuildResult *) palloc0(sizeof(IndexBuildResult));
	result->heap_tuples = reltuples;
	result->index_tuples = reltuples;
	return result;
}

static void
bm25_buildempty(Relation index)
{
	bm25_init_metapage(index);
}

/*
 * Index one oversized document (its analyzed ftsdoc does not fit on a single
 * pending page) directly as its own one-document segment, bypassing the
 * verbatim pending buffer.  Segment posting storage is a chain of FOR-packed
 * pages with no per-document size limit, so arbitrarily large documents (e.g.
 * long Wikipedia articles) can be indexed.  Rare, so building a whole segment
 * per such document is acceptable.
 */
/*
 * Are there enough small segments to make an insert-time merge worth its rewrite?
 *
 * Reading the metapage is cheap; rewriting a run is not.  Returning false here just
 * defers the merge to a later insert (or to vacuum/fts_merge), so the directory is
 * still bounded -- it only stops us rewriting a whole run for every single document.
 *
 * The threshold is the fan-in the leveled compactor would use anyway: below it,
 * bm25_merge_segments() finds no level over capacity and is a no-op that we can skip
 * without changing behaviour.  Above it, we merge exactly as before.
 */
static bool
bm25_pending_segments_worth_merging(Relation index)
{
	Buffer		buf;
	BM25MetaPageData meta;

	buf = ReadBuffer(index, BM25_METAPAGE_BLKNO);
	LockBuffer(buf, BUFFER_LOCK_SHARE);
	bm25_meta_from_page(BufferGetPage(buf), &meta);
	UnlockReleaseBuffer(buf);

	/*
	 * Count runs in the smallest level.  A one-doc segment always lands there, so
	 * this is the number of un-amortised inserts waiting to be folded in.
	 */
	{
		uint32		i;
		int			small = 0;

		for (i = 0; i < meta.nsegments; i++)
		{
			if (meta.segs[i].dictstart == InvalidBlockNumber)
				continue;
			if (bm25_seg_level(meta.segs[i].ndocs - meta.segs[i].ndeleted) == 0)
				small++;
		}
		return small >= BM25_MERGE_FANOUT;
	}
}

static void
bm25_insert_oversized_as_segment(Relation index, FtsDoc doc, ItemPointer tid)
{
	BM25BuildState bs;
	FtsTermEntry *entries = FTS_DOC_ENTRIES(doc);
	uint32		j;

	bs.ctx = AllocSetContextCreate(CurrentMemoryContext, "bm25 oversized",
								   ALLOCSET_DEFAULT_SIZES);
	bs.want_positions = bm25_index_wants_positions(index);
	bs.want_trigrams = bm25_index_wants_trigrams(index);
	bs.want_sidecar = bm25_index_wants_doclen_sidecar(index);
	bs.terms = NULL;
	bs.nterms = 0;
	bs.maxterms = 0;
	bs.ndocs = 0;
	bs.sumdoclen = 0;
	bs.nflushes = 0;
	bs.flush_budget = 0;
	bm25_build_ht_init(&bs);

	{
		MemoryContext old = MemoryContextSwitchTo(bs.ctx);

		for (j = 0; j < doc->nterms; j++)
		{
			const uint32 *pos = (bs.want_positions && FTS_DOC_HAS_POS(doc))
				? FTS_DOC_TERMPOS(doc, &entries[j]) : NULL;

			add_posting(&bs, FTS_DOC_TERMTEXT(doc, &entries[j]), entries[j].len,
						tid, entries[j].tf, doc->doclen,
						pos, pos ? (int) entries[j].tf : 0);
		}
		bs.ndocs = 1.0;
		bs.sumdoclen = doc->doclen;
		MemoryContextSwitchTo(old);
	}

	/* write the one-doc segment (updates corpus N/sumdoclen via add_segment) */
	bm25_build_flush_segment(index, &bs);
	MemoryContextDelete(bs.ctx);

	/*
	 * Keep the tiered segment set compacted as documents arrive.  On a
	 * continuously-written table whose rows are mostly larger than one pending
	 * page (long email bodies, articles, code -- the common case for a body
	 * index), EVERY insert lands here and mints a segment, so without ongoing
	 * compaction the directory climbs to the hard cap within the hour (a field
	 * deployment did exactly this: 8 -> 128 segments in ~1h of ingestion, then
	 * could neither merge nor VACUUM).  bm25_merge_segments() is the leveled LSM
	 * compactor: it merges only a level that is over its fan-in capacity and is
	 * a cheap metapage read when every level is within capacity, so calling it
	 * after each flush keeps nsegments bounded (O(log N) tiers) instead of
	 * letting it grow unbounded toward the cap.  This IS the background
	 * auto-compaction: no VACUUM or manual fts_merge() is required to stay
	 * healthy under continuous writes.
	 *
	 * The merge frees + recycles the input segments' pages, which is unsafe to
	 * run concurrently with another flush/merge/compact on this index, so take
	 * the maintenance mutex.  CONDITIONALLY: this is an opportunistic insert-time
	 * compaction under only RowExclusiveLock -- if a cleanup is already running
	 * (autovacuum, fts_merge, or another inserter) just skip; that writer, or the
	 * next insert/vacuum, keeps nsegments bounded.  (Adding the segment above is
	 * an extend-only metapage write and needs no mutex; only the recycling merge
	 * does.)
	 */
	/*
	 * ...but do not merge on EVERY insert.  Each oversized document mints a
	 * one-document segment, and merging immediately means one document in causes a
	 * whole level-0 run to be rewritten out: LSM write amplification at the
	 * smallest possible unit.  Measured at field shape (1660 terms/doc), where every
	 * document takes this path: **23-30 index pages extended per document**, linear
	 * in the document count, against roughly 2 pages of actual postings -- a ~12-15x
	 * amplification with page reuse near zero (16-64 reuses against 5,924 extends).
	 * The index grew ~5 GB per 5,000 documents to 31,537 MB, and a single later
	 * fts_vacuum returned it to 124 MB.
	 *
	 * The freed pages cannot be reused within the inserting transaction: the
	 * bm25_page_recyclable() XID gate rejects them because our own transaction can
	 * still see them (measured: norecyc=3,169 of 5,924 allocations), and that gate
	 * must stand -- bypassing it previously corrupted a concurrent reader.  So the
	 * only lever is to rewrite less often.
	 *
	 * Letting one-doc segments accumulate to the level's fan-in before merging
	 * amortises each rewrite over ~FANOUT documents instead of paying it per
	 * document, while still bounding the directory: the segment count stays below
	 * the cap that a field deployment hit (8 -> 128 segments in ~1h), because a
	 * merge still runs as soon as there are enough runs to be worth merging.
	 * See CHANGELOG 1.7.2 (known issue).
	 */
	if (bm25_pending_segments_worth_merging(index) &&
		bm25_maintenance_lock_conditional(index))
	{
		PG_TRY();
		{
			bm25_merge_segments(index);
		}
		PG_FINALLY();
		{
			bm25_maintenance_unlock(index);
		}
		PG_END_TRY();
	}
}

/*
 * aminsert: append the new document to the pending list.
 *
 * The document is stored verbatim (its ftsdoc bytes) on a chain of pending
 * pages and is searched directly at scan time, so newly inserted rows are
 * immediately visible to @@@ without a REINDEX.  The metapage N and sum(doclen)
 * are updated so BM25 length-normalization stays correct; per-term df in the
 * dictionary is not updated until a merge (REINDEX), matching GIN fastupdate's
 * documented staleness.
 */
static bool
bm25_insert(Relation index, Datum *values, bool *isnull,
			ItemPointer ht_ctid, Relation heapRel,
			IndexUniqueCheck checkUnique, bool indexUnchanged,
			IndexInfo *indexInfo)
{
	FtsDoc		doc;
	Size		doclen;
	Size		need;
	Buffer		metabuf;
	GenericXLogState *state;
	Page		metapage;
	BM25MetaPageData *meta;
	BlockNumber tailblk;
	Buffer		tailbuf;
	Page		tailpage;
	bool		appended = false;

	if (isnull[0])
		return false;

	doc = (FtsDoc) PG_DETOAST_DATUM(values[0]);
	doclen = VARSIZE(doc);
	need = MAXALIGN(sizeof(BM25PendingItem) + doclen);

	if (need > BLCKSZ - MAXALIGN(SizeOfPageHeaderData) - MAXALIGN(sizeof(BM25PageOpaqueData)))
	{
		/* Too large for the verbatim pending buffer: index it directly as its
		 * own one-document segment (no per-doc size limit there). */
		bm25_insert_oversized_as_segment(index, doc, ht_ctid);
		return true;
	}

	/* Lock the metapage for the whole append (serializes inserters; a
	 * per-inserter fast path is a later optimization). */
	metabuf = ReadBuffer(index, BM25_METAPAGE_BLKNO);
	LockBuffer(metabuf, BUFFER_LOCK_EXCLUSIVE);
	metapage = BufferGetPage(metabuf);
	bm25_check_meta(metapage, index);
	meta = BM25PageGetMeta(metapage);
	tailblk = meta->pendingtail;

	/* Try to append to the current tail page. */
	if (tailblk != InvalidBlockNumber)
	{
		tailbuf = ReadBuffer(index, tailblk);
		LockBuffer(tailbuf, BUFFER_LOCK_EXCLUSIVE);
		tailpage = BufferGetPage(tailbuf);
		if (((PageHeader) tailpage)->pd_lower + need <=
			BLCKSZ - MAXALIGN(sizeof(BM25PageOpaqueData)))
		{
			BM25PendingItem *pi;

			state = GenericXLogStart(index);
			tailpage = GenericXLogRegisterBuffer(state, tailbuf, 0);
			pi = (BM25PendingItem *) ((char *) tailpage +
									 ((PageHeader) tailpage)->pd_lower);
			pi->tid = *ht_ctid;
			pi->doclen = doclen;
			memcpy((char *) pi + sizeof(BM25PendingItem), doc, doclen);
			((PageHeader) tailpage)->pd_lower += need;
			metapage = GenericXLogRegisterBuffer(state, metabuf, 0);
			meta = BM25PageGetMeta(metapage);
			meta->ndocs += 1.0;
			meta->sumdoclen += doc->doclen;
			meta->npending += 1;
			GenericXLogFinish(state);
			appended = true;
		}
		if (!appended)
			UnlockReleaseBuffer(tailbuf);	/* re-read below as oldtail */
	}

	/* Need a fresh pending page (either none yet, or the tail is full). */
	if (!appended)
	{
		Buffer		newbuf = bm25_new_buffer(index);
		BlockNumber newblk = BufferGetBlockNumber(newbuf);
		BM25PendingItem *pi;

		state = GenericXLogStart(index);
		{
			Page		np = GenericXLogRegisterBuffer(state, newbuf,
													   GENERIC_XLOG_FULL_IMAGE);

			bm25_init_page(np, BM25_PENDING);
			pi = (BM25PendingItem *) ((char *) np +
									 ((PageHeader) np)->pd_lower);
			pi->tid = *ht_ctid;
			pi->doclen = doclen;
			memcpy((char *) pi + sizeof(BM25PendingItem), doc, doclen);
			((PageHeader) np)->pd_lower += need;
		}

		/* link previous tail (if any) to the new page */
		if (tailblk != InvalidBlockNumber)
		{
			Buffer		oldtail = ReadBuffer(index, tailblk);
			Page		op;

			LockBuffer(oldtail, BUFFER_LOCK_EXCLUSIVE);
			op = GenericXLogRegisterBuffer(state, oldtail, 0);
			BM25PageGetOpaque(op)->nextblk = newblk;
			metapage = GenericXLogRegisterBuffer(state, metabuf, 0);
			meta = BM25PageGetMeta(metapage);
			meta->pendingtail = newblk;
			meta->ndocs += 1.0;
			meta->sumdoclen += doc->doclen;
			meta->npending += 1;
			GenericXLogFinish(state);
			UnlockReleaseBuffer(oldtail);
		}
		else
		{
			metapage = GenericXLogRegisterBuffer(state, metabuf, 0);
			meta = BM25PageGetMeta(metapage);
			meta->pendinghead = newblk;
			meta->pendingtail = newblk;
			meta->ndocs += 1.0;
			meta->sumdoclen += doc->doclen;
			meta->npending += 1;
			GenericXLogFinish(state);
		}
		UnlockReleaseBuffer(newbuf);
	}
	else
		UnlockReleaseBuffer(tailbuf);

	UnlockReleaseBuffer(metabuf);
	return true;
}

/* ----- scan ----- */

/*
 * ONE TRANSLATION UNIT, ON PURPOSE.
 *
 * The three files below are #included here rather than compiled separately, and
 * this is a decision (2026-09-17, REVIEW_2026-09-17.md item C3), not an accident
 * to be tidied.  The measured cost of splitting them:
 *
 *   - 15 static helpers in this file would have to become extern for the scan
 *     and trigram code to see them, and 1 scan helper (bm25_scan_readbuf) for
 *     this file to see it;
 *   - ~10 shared struct types would move into pg_fts_am.h, which is the
 *     ON-DISK FORMAT header and should stay free of scan-time internals;
 *   - the hot-path helpers bm25_tid_to_docid / bm25_docid_to_tid /
 *     bm25_page_data_end / bm25_doclen_cursor_lookup are `static inline` and
 *     sit inside the 45%-doclen / 37%-candidate-iteration profile of a
 *     common-term query.  Across a TU boundary they stop inlining (without
 *     LTO, which the PGXS build does not use).
 *
 * In exchange we would get three .o files and no behaviour change.  Not worth
 * it.  What the single TU costs is only that the files cannot be syntax-checked
 * alone -- check THIS file (see AGENTS.md "Build / test") and the includes come
 * with it.  If a future change needs separate compilation, the two things to
 * do first are (1) move the shared types out of pg_fts_am.h into a new
 * pg_fts_am_internal.h and (2) measure the common-term latency before and after
 * de-inlining, since that is where the risk is.
 */
#include "pg_fts_lev.c"
#include "pg_fts_am_scan.c"
#include "pg_fts_trgm_index.c"

/* ----- vacuum / flush / merge / cost / options ----- */

/*
 * Maintenance serialization lock (the GIN ginInsertCleanup pattern).
 *
 * Every operation that MUTATES the segment directory or frees + recycles a
 * segment's pages -- bm25_flush_pending, bm25_merge_segments/_all,
 * bm25_vacuum_compact, bulkdelete's livedocs swap -- must run one-at-a-time per
 * index.  The obvious candidate, the table/index relation lock, does NOT serve:
 * autovacuum's index cleanup holds ShareUpdateExclusiveLock on the TABLE while a
 * user fts_merge()/fts_vacuum() holds it on the INDEX -- different lock tags
 * that do not conflict -- and an INSERT's oversized-doc segment path holds only
 * RowExclusiveLock.  So two of these could run at once: one frees + recycles a
 * segment's dict/posting pages while the other's streaming merge is still
 * reading them, yielding a garbage read (a SIGSEGV in merge_source_load_page
 * under heavy concurrent insert+merge+vacuum churn -- the t/006 crash).
 *
 * A heavyweight page lock on the metapage block, used for NOTHING else, gives a
 * per-index mutex independent of the relation lock (exactly how GIN serializes
 * pending-list cleanup).  Explicit/required maintenance (VACUUM cleanup,
 * fts_merge, fts_vacuum) takes it blocking; opportunistic maintenance (the
 * insert-triggered tiered merge) takes it CONDITIONALLY and simply skips when a
 * cleanup is already running -- another writer or the next insert/vacuum will
 * compact, so nsegments still stays bounded.
 */
static inline void
bm25_maintenance_lock(Relation index)
{
	LockPage(index, BM25_METAPAGE_BLKNO, ExclusiveLock);
}

/*
 * Every merger must run under the maintenance mutex -- or on an index no other
 * backend can see (ambuild: the relation is being created).  Enforced, not
 * documented: the one site that skipped it deadlocked two merges on a shared
 * buffer the moment merges started reusing pages.  An elog, not an Assert -- the
 * release gate is not a cassert build.
 */
static inline void
bm25_assert_merge_serialized(Relation index)
{
	LOCKTAG		tag;

	SET_LOCKTAG_PAGE(tag, index->rd_lockInfo.lockRelId.dbId,
					 index->rd_lockInfo.lockRelId.relId, BM25_METAPAGE_BLKNO);
	if (unlikely(!LockHeldByMe(&tag, ExclusiveLock, false) &&
				 !CheckRelationLockedByMe(index, AccessExclusiveLock, true)))
		elog(ERROR, "pg_fts: merge entered without the maintenance mutex on index \"%s\"",
			 RelationGetRelationName(index));
}

static inline bool
bm25_maintenance_lock_conditional(Relation index)
{
	return ConditionalLockPage(index, BM25_METAPAGE_BLKNO, ExclusiveLock);
}

static inline void
bm25_maintenance_unlock(Relation index)
{
	UnlockPage(index, BM25_METAPAGE_BLKNO, ExclusiveLock);
}

/*
 * Flush the pending write buffer into a NEW immutable segment.
 *
 * O(pending), not O(index): only the pending documents are folded into a fresh
 * segment appended to the directory.  (The old monolithic design re-read and
 * rewrote the entire index on every merge -- O(index) and quadratic under
 * steady inserts.)  Pending pages are then recycled to the FSM.  Tiered
 * compaction of many small segments is a separate operation.  Returns true if
 * a flush happened.
 */
static bool
bm25_flush_pending(Relation index)
{
	BM25MetaPageData meta;
	BM25BuildState bs;
	BM25SegMeta seg;
	BlockNumber blk;

	{
		Buffer		mb = ReadBuffer(index, BM25_METAPAGE_BLKNO);

		LockBuffer(mb, BUFFER_LOCK_SHARE);
		bm25_meta_from_page(BufferGetPage(mb), &meta);
		UnlockReleaseBuffer(mb);
	}
	if (meta.npending == 0)
		return false;

	bs.ctx = AllocSetContextCreate(CurrentMemoryContext, "bm25 flush",
								   ALLOCSET_DEFAULT_SIZES);
	bs.want_positions = bm25_index_wants_positions(index);
	bs.want_trigrams = bm25_index_wants_trigrams(index);
	bs.want_sidecar = bm25_index_wants_doclen_sidecar(index);
	bs.terms = NULL;
	bs.nterms = 0;
	bs.maxterms = 0;
	bs.ndocs = 0;
	bs.sumdoclen = 0;
	bs.nflushes = 0;
	bs.flush_budget = 0;
	{
		HASHCTL		ctl;

		ctl.keysize = sizeof(TermKey);
		ctl.entrysize = sizeof(TermHashEntry);
		ctl.hcxt = bs.ctx;
		build_ht = hash_create("bm25 flush terms", 1024, &ctl,
							   HASH_ELEM | HASH_BLOBS | HASH_CONTEXT);
	}

	/* fold only the pending documents into the build state */
	blk = meta.pendinghead;
	while (blk != InvalidBlockNumber)
	{
		Buffer		buffer = ReadBuffer(index, blk);
		Page		page;
		char	   *ptr,
				   *end;
		BlockNumber next;
		MemoryContext old = MemoryContextSwitchTo(bs.ctx);

		LockBuffer(buffer, BUFFER_LOCK_SHARE);
		page = BufferGetPage(buffer);
		ptr = (char *) PageGetContents(page);
		end = bm25_page_data_end(page);
		next = BM25PageGetOpaque(page)->nextblk;
		while (ptr < end)
		{
			BM25PendingItem *pi = (BM25PendingItem *) ptr;
			FtsDoc		pdoc;
			FtsTermEntry *entries;
			uint32		j;

			/* Stop if the item header or its doclen-sized body runs past the page
			 * (a torn/recycled page with a garbage doclen would otherwise advance
			 * ptr off the page and read out of bounds). */
			if ((char *) pi + sizeof(BM25PendingItem) > end ||
				(char *) pi + MAXALIGN(sizeof(BM25PendingItem) + (Size) pi->doclen) > end)
				break;
			pdoc = (FtsDoc) ((char *) pi + sizeof(BM25PendingItem));

			/* Never trust raw pending-page bytes: a torn page or any producing
			 * bug could give a bad nterms/len/posoff that turns into a wild
			 * write in add_posting.  Validate against the item's own doclen and
			 * skip (not crash) a corrupt doc so autovacuum can make progress. */
			if (!fts_doc_is_valid(pdoc, pi->doclen))
			{
				ereport(WARNING,
						(errcode(ERRCODE_DATA_CORRUPTED),
						 errmsg("pg_fts: skipping malformed pending document in index \"%s\" during flush",
								RelationGetRelationName(index)),
						 errhint("REINDEX the index to rebuild it from the heap.")));
				ptr += MAXALIGN(sizeof(BM25PendingItem) + pi->doclen);
				continue;
			}
			entries = FTS_DOC_ENTRIES(pdoc);

			for (j = 0; j < pdoc->nterms; j++)
			{
				const uint32 *pos = (bs.want_positions && FTS_DOC_HAS_POS(pdoc))
					? FTS_DOC_TERMPOS(pdoc, &entries[j]) : NULL;

				add_posting(&bs, FTS_DOC_TERMTEXT(pdoc, &entries[j]),
							entries[j].len, &pi->tid, entries[j].tf,
							pdoc->doclen, pos, pos ? (int) entries[j].tf : 0);
			}
			bs.ndocs += 1.0;
			bs.sumdoclen += pdoc->doclen;
			ptr += MAXALIGN(sizeof(BM25PendingItem) + pi->doclen);
		}
		UnlockReleaseBuffer(buffer);
		MemoryContextSwitchTo(old);
		blk = next;
	}

	if (bs.nterms > 1)
		qsort(bs.terms, bs.nterms, sizeof(BuildTerm), cmp_buildterm);

	bm25_write_segment(index, &bs, &seg);
	bm25_add_segment_with_room(index, &seg);

	/*
	 * Clear the pending list.  Pending docs were already counted into the
	 * corpus totals at insert time; add_segment counted them again, so subtract
	 * the segment's contribution to avoid a double count.
	 */
	{
		Buffer		mb = ReadBuffer(index, BM25_METAPAGE_BLKNO);
		GenericXLogState *state;
		Page		mp;
		BM25MetaPageData *m;

		LockBuffer(mb, BUFFER_LOCK_EXCLUSIVE);
		state = GenericXLogStart(index);
		mp = GenericXLogRegisterBuffer(state, mb, 0);
		bm25_meta_upcast_page(mp);	/* v3 -> v4 before struct write */
		m = BM25PageGetMeta(mp);
		m->ndocs -= seg.ndocs;
		m->sumdoclen -= seg.sumdoclen;
		m->pendinghead = InvalidBlockNumber;
		m->pendingtail = InvalidBlockNumber;
		m->npending = 0;
		GenericXLogFinish(state);
		UnlockReleaseBuffer(mb);
	}

	/* recycle the old pending pages */
	blk = meta.pendinghead;
	while (blk != InvalidBlockNumber)
	{
		Buffer		buf = ReadBuffer(index, blk);
		BlockNumber next;

		LockBuffer(buf, BUFFER_LOCK_SHARE);
		next = BM25PageGetOpaque(BufferGetPage(buf))->nextblk;
		UnlockReleaseBuffer(buf);
		bm25_free_page(index, blk);
		blk = next;
	}
	IndexFreeSpaceMapVacuum(index);

	MemoryContextDelete(bs.ctx);

	/* keep the segment count bounded (query cost is O(nsegments) per term) */
	bm25_merge_segments(index);
	return true;
}

/*
 * Collect the distinct docids present in a segment into a sparsemap (the
 * segment's docid "universe").  Used by bulkdelete to enumerate the TIDs the
 * vacuum callback must be asked about.
 */
static sm_t *
bm25_segment_docids(Relation index, const BM25SegMeta *seg)
{
	sm_t	   *seen = sm_create(256);
	sm_t *volatile seen_v;
	BlockNumber blk = seg->dictstart;
	uint64	   *ids = NULL;
	int			nids = 0;
	int			capids = 0;

	if (seen == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_OUT_OF_MEMORY),
				 errmsg("out of memory building bm25 tombstone map")));

	/* seen is a libc-malloc sparsemap: free it if the page reads / bulk add
	 * below throw, else it would leak past transaction abort.  volatile: the
	 * pointer is rewritten inside PG_TRY (sm_add_many_grow may realloc) and read
	 * in PG_FINALLY. */
	seen_v = seen;
	PG_TRY();
	{
	/*
	 * Collect EVERY posting's docid across all terms into one array, then do a
	 * SINGLE bulk add.  A high-vocabulary segment has millions of low-frequency
	 * (often single-doc) terms; adding each term's postings with its own
	 * sm_add_many_grow call restarts the sparsemap cursor per call, so the adds
	 * are effectively unsorted and each re-walks the chunk chain -> O(N^2) (the
	 * CIC-validate / VACUUM spin observed at scale).  One bulk add over the full
	 * array sorts once and threads the cursor across the whole ascending run =
	 * true O(N).
	 */
	while (blk != InvalidBlockNumber)
	{
		Buffer		buffer = ReadBuffer(index, blk);
		Page		page;
		char	   *ptr,
				   *end;
		BlockNumber next;

		LockBuffer(buffer, BUFFER_LOCK_SHARE);
		page = BufferGetPage(buffer);
		ptr = (char *) PageGetContents(page);
		end = bm25_page_data_end(page);
		next = BM25PageGetOpaque(page)->nextblk;
		while (ptr < end)
		{
			BM25DictEntry *de = (BM25DictEntry *) ptr;
			Size		esize = MAXALIGN(offsetof(BM25DictEntry, term) + de->termlen);
			BM25Posting *post;
			int			np,
						k;

			np = bm25_decode_term(index, de->firstposting, de->firstoffset,
								  de->df, &post, NULL, false, NULL, true,
								  seg->doclenstart == InvalidBlockNumber);
			if (np > 0)
			{
				if (nids + np > capids)
				{
					capids = Max(nids + np, capids ? capids * 2 : 4096);
					ids = ids ? FTS_REALLOC_MAYBE_HUGE(ids, (Size) capids * sizeof(uint64))
						: (uint64 *) FTS_ALLOC_MAYBE_HUGE((Size) capids * sizeof(uint64));
				}
				for (k = 0; k < np; k++)
					ids[nids++] = bm25_tid_to_docid(&post[k].tid);
			}
			pfree(post);
			ptr += esize;
		}
		UnlockReleaseBuffer(buffer);
		blk = next;
	}

	if (nids > 0 && !sm_add_many_grow(&seen, ids, nids))
	{
		/* sm_add_many_grow updates *map even on a partial grow-then-fail, so the
		 * live pointer is `seen`, not the pre-call value; resync BEFORE the throw
		 * so PG_FINALLY frees the current (not a freed-by-realloc) map. */
		seen_v = seen;
		ereport(ERROR,
				(errcode(ERRCODE_OUT_OF_MEMORY),
				 errmsg("out of memory building bm25 livedocs set")));
	}
	seen_v = seen;			/* sm_add_many_grow may realloc: resync cleanup ptr */
	if (ids)
		pfree(ids);
	seen_v = NULL;			/* success: ownership passes to the caller, do not free */
	}
	PG_FINALLY();
	{
		/* runs on error only (seen_v NULLed on the success path above); frees the
		 * libc-malloc map before FINALLY re-throws */
		if (seen_v)
			sm_free((sm_t *) seen_v);
	}
	PG_END_TRY();
	return seen;
}

/*
 * bm25_bulkdelete: VACUUM asks us, via `callback`, which of the TIDs in the
 * index refer to now-dead heap tuples.  Because postings live in immutable
 * segments, we cannot cheaply remove individual entries; instead we maintain a
 * per-segment livedocs TOMBSTONE bitmap (a docid sparsemap of deleted docs).
 * Scans and counts subtract tombstoned docids, and the tiered merge physically
 * drops them.  This is essential for correctness: the index-only
 * scan and fts_count paths trust the visibility map, so a vacuumed+reused heap
 * slot MUST NOT still be reported as a match -- the tombstone prevents that.
 */
static IndexBulkDeleteResult *
bm25_bulkdelete(IndexVacuumInfo *info, IndexBulkDeleteResult *stats,
				IndexBulkDeleteCallback callback, void *callback_state)
{
	Relation	index = info->index;
	BM25MetaPageData meta;
	uint32		s;
	int64		num_index_tuples = 0;
	int64		tuples_removed = 0;

	/* sm_create() uses libc malloc (no palloc allocator installed), so an
	 * ereport(ERROR) between create and sm_free would leak past transaction
	 * abort.  Track the live maps here so PG_FINALLY frees them on error too.
	 * volatile: pointers are written inside PG_TRY, read in PG_FINALLY. */
	sm_t *volatile seen_v = NULL;
	sm_t *volatile dead_v = NULL;

	if (stats == NULL)
		stats = (IndexBulkDeleteResult *) palloc0(sizeof(IndexBulkDeleteResult));

	/* Serialize against a concurrent flush/merge/compact: bulkdelete reads each
	 * segment's docids (dict + posting pages) and swaps its livedocs pointer --
	 * both racy with a merge that frees/recycles those pages under a
	 * non-conflicting relation lock.  Blocking (vacuum must make progress). */
	bm25_maintenance_lock(index);
	PG_TRY();
	{
	{
		Buffer		mb = ReadBuffer(index, BM25_METAPAGE_BLKNO);

		LockBuffer(mb, BUFFER_LOCK_SHARE);
		bm25_check_meta(BufferGetPage(mb), index);
		bm25_meta_from_page(BufferGetPage(mb), &meta);
		UnlockReleaseBuffer(mb);
	}

	for (s = 0; s < meta.nsegments; s++)
	{
		BM25SegMeta *sg = &meta.segs[s];
		sm_t	   *seen;
		sm_t	   *dead;
		sm_cursor_t cur = SM_CURSOR_INIT;
		sm_cursor_t ccur;		/* reset immediately before the walk below */
		uint64		v;
		uint32		ndead = 0;
		BlockNumber oldlivedocs;
		uint32		oldlen;

		if (sg->dictstart == InvalidBlockNumber)
			continue;

		seen = bm25_segment_docids(index, sg);
		seen_v = seen;
		dead = sm_create(256);
		dead_v = dead;
		if (dead == NULL)
			ereport(ERROR,
					(errcode(ERRCODE_OUT_OF_MEMORY),
					 errmsg("out of memory building bm25 tombstone map")));

		/* carry forward any docids already tombstoned in this segment */
		if (sg->livedocs != InvalidBlockNumber && sg->livedocslen > 0)
		{
			uint8	   *buf = bm25_read_blob(index, sg->livedocs, sg->livedocslen);
			sm_t		old;
			sm_cursor_t oc = SM_CURSOR_INIT;
			uint64		dv;
			uint64	   *carry = NULL;
			int			ncarry = 0,
						carrycap = 0;

			sm_open(&old, (uint8_t *) buf, sg->livedocslen);
			for (dv = sm_next_member(&old, (uint64_t) -1, &oc);
				 dv != SM_IDX_MAX;
				 dv = sm_next_member(&old, dv, &oc))
			{
				if (ncarry >= carrycap)
				{
					/* sized by tombstone count: huge-safe, same reason as the
					 * doclen resident array (a delete-heavy field-scale index can
					 * exceed MaxAllocSize/8 = 134M entries, and this runs in
					 * bulkdelete, so failing here also blocks all reclaim). */
					carrycap = carrycap ? carrycap * 2 : 1024;
					carry = carry
						? FTS_REALLOC_MAYBE_HUGE(carry,
												 (Size) carrycap * sizeof(uint64))
						: FTS_ALLOC_MAYBE_HUGE((Size) carrycap * sizeof(uint64));
				}
				carry[ncarry++] = dv;
			}
			/* bulk O(N) add; one-at-a-time sm_add_grow is O(N^2) at scale */
			if (ncarry > 0 && !sm_add_many_grow(&dead, carry, ncarry))
			{
				dead_v = dead;	/* resync before throw: *map may have been realloc'd */
				ereport(ERROR,
						(errcode(ERRCODE_OUT_OF_MEMORY),
						 errmsg("out of memory building bm25 tombstone set")));
			}
			dead_v = dead;		/* sm_add_many_grow may realloc: resync cleanup ptr */
			ndead += ncarry;
			if (carry)
				pfree(carry);
			pfree(buf);
		}

		/* ask the callback about each live (not-yet-tombstoned) docid.  Collect
		 * the newly-dead docids and bulk-add them to `dead` once at the end:
		 * each docid in `seen` is visited exactly once, so the in-loop
		 * sm_contains() check only needs to see the carried-forward tombstones,
		 * and adding one at a time with sm_add_grow would be O(N^2). */
		{
			uint64	   *newdead = NULL;
			int			nnew = 0,
						newcap = 0;

			/*
			 * ONE cursor for the whole walk.  `v` comes from sm_next_member and is
			 * monotonically increasing -- exactly sm_contains()'s cursor contract --
			 * so a single threaded cursor makes this O(postings + chunks).
			 *
			 * This was declared INSIDE the loop and so reset every iteration, making
			 * each lookup re-walk the chunk chain from the head: O(n x chunks).  With
			 * ~1,068 chunks and millions of postings that is the SECOND half of the
			 * VACUUM hang -- after the merge-path fix, gdb showed the next VACUUM
			 * pinned here instead.  See CHANGELOG 1.6.1.
			 */
			ccur = (sm_cursor_t) SM_CURSOR_INIT;
			for (v = sm_next_member(seen, (uint64_t) -1, &cur);
				 v != SM_IDX_MAX;
				 v = sm_next_member(seen, v, &cur))
			{
				ItemPointerData tid;

				num_index_tuples++;
				if (sm_contains(dead, v, &ccur))
					continue;		/* already tombstoned (carried forward) */
				bm25_docid_to_tid(v, &tid);
				if (callback(&tid, callback_state))
				{
					if (nnew >= newcap)
					{
						newcap = newcap ? newcap * 2 : 1024;	/* huge-safe: see carry above */
						newdead = newdead
							? FTS_REALLOC_MAYBE_HUGE(newdead,
													 (Size) newcap * sizeof(uint64))
							: FTS_ALLOC_MAYBE_HUGE((Size) newcap * sizeof(uint64));
					}
					newdead[nnew++] = v;
					tuples_removed++;
				}
			}
			if (nnew > 0 && !sm_add_many_grow(&dead, newdead, nnew))
			{
				dead_v = dead;	/* resync before throw: *map may have been realloc'd */
				ereport(ERROR,
						(errcode(ERRCODE_OUT_OF_MEMORY),
						 errmsg("out of memory building bm25 tombstone set")));
			}
			dead_v = dead;		/* sm_add_many_grow may realloc: resync cleanup ptr */
			ndead += nnew;
			if (newdead)
				pfree(newdead);
		}
		sm_free(seen);
		seen_v = NULL;

		oldlivedocs = sg->livedocs;
		oldlen = sg->livedocslen;

		/* write the updated tombstone bitmap (if any) and patch the metapage */
		{
			BlockNumber newblk = InvalidBlockNumber;
			uint32		newlen = 0;

			if (ndead > 0)
			{
				newlen = (uint32) sm_get_size(dead);
				newblk = bm25_write_blob(index, (const uint8 *) sm_get_data(dead),
										 newlen);
			}
			sm_free(dead);
			dead_v = NULL;


			{
				Buffer		mb = ReadBuffer(index, BM25_METAPAGE_BLKNO);
				GenericXLogState *st;
				Page		mp;
				BM25MetaPageData *m;

				LockBuffer(mb, BUFFER_LOCK_EXCLUSIVE);
				st = GenericXLogStart(index);
				mp = GenericXLogRegisterBuffer(st, mb, 0);
				bm25_meta_upcast_page(mp);	/* v3 -> v4 before struct write */
				m = BM25PageGetMeta(mp);
				if (s < m->nsegments)
				{
					m->segs[s].livedocs = newblk;
					m->segs[s].livedocslen = newlen;
					m->segs[s].ndeleted = ndead;
					m->generation++;	/* livedocs blob pages freed: invalidate scan snapshots */
				}
				GenericXLogFinish(st);
				UnlockReleaseBuffer(mb);
			}
		}

		/* recycle the previous tombstone blob pages */
		if (oldlivedocs != InvalidBlockNumber && oldlen > 0)
			bm25_free_chain(index, oldlivedocs);
	}

	/* refresh corpus N so IDF/avgdl reflect the deletions */
	if (tuples_removed > 0)
	{
		Buffer		mb = ReadBuffer(index, BM25_METAPAGE_BLKNO);
		GenericXLogState *st;
		Page		mp;
		BM25MetaPageData *m;
		uint32		i;
		double		nd = 0;

		LockBuffer(mb, BUFFER_LOCK_EXCLUSIVE);
		st = GenericXLogStart(index);
		mp = GenericXLogRegisterBuffer(st, mb, 0);
		bm25_meta_upcast_page(mp);	/* v3 -> v4 before reading segs[] and writing */
		m = BM25PageGetMeta(mp);
		for (i = 0; i < m->nsegments; i++)
			nd += m->segs[i].ndocs - m->segs[i].ndeleted;
		m->ndocs = nd + m->npending;
		GenericXLogFinish(st);
		UnlockReleaseBuffer(mb);
	}
	}
	PG_FINALLY();
	{
		if (seen_v)
			sm_free((sm_t *) seen_v);
		if (dead_v)
			sm_free((sm_t *) dead_v);
		bm25_maintenance_unlock(index);
	}
	PG_END_TRY();

	stats->num_index_tuples = (double) (num_index_tuples - tuples_removed);
	stats->tuples_removed += (double) tuples_removed;
	stats->num_pages = RelationGetNumberOfBlocks(index);
	return stats;
}

static IndexBulkDeleteResult *
bm25_vacuumcleanup(IndexVacuumInfo *info, IndexBulkDeleteResult *stats)
{
	if (stats == NULL)
		stats = (IndexBulkDeleteResult *) palloc0(sizeof(IndexBulkDeleteResult));

	/* Fold any pending documents into a new segment, then compact segments. */
	if (!info->analyze_only)
	{
		/* serialize against any concurrent flush/merge/compact on this index
		 * (a user fts_merge/fts_vacuum, or another autovacuum worker): they take
		 * different relation locks that do not conflict, so this heavyweight
		 * page lock is the actual mutex.  Blocking: cleanup should run. */
		bm25_maintenance_lock(info->index);
		PG_TRY();
		{
			(void) bm25_flush_pending(info->index);
			bm25_merge_segments(info->index);

			/*
			 * If the relation carries substantial dead space (physical size well
			 * above the live pages), reclaim it: compact to one segment reusing
			 * low blocks, then truncate the free tail.  Gated so routine
			 * autovacuum does not pay a full rewrite every pass -- only when the
			 * free tail is a meaningful fraction of the file.
			 */
			{
				BlockNumber nblocks = RelationGetNumberOfBlocks(info->index);
				BlockNumber freeblks = 0;
				BlockNumber b;

				for (b = 1; b < nblocks; b++)
					if (GetRecordedFreeSpace(info->index, b) >= BLCKSZ / 2)
						freeblks++;

				/*
				 * ALWAYS truncate a free tail, unconditionally and first.
				 *
				 * This is O(free tail) with no data rewrite and it cannot be
				 * "wasted work", so it must not sit behind the bloat gate below.
				 * Doing it first also means that if the vacate+pack is cancelled
				 * (autovacuum yields to any conflicting lock request), the pass
				 * has still made real progress rather than none.  Safe while the
				 * index is online and under ShareUpdateExclusiveLock: scans read
				 * through bm25_scan_readbuf(), which treats an out-of-range block
				 * as end-of-chain (added in 1.5.7 for exactly this).
				 */
				(void) bm25_truncate_free_tail(info->index);

				/*
				 * Then the rewrite that reclaims free pages BURIED under live
				 * data, which a tail truncate cannot reach.  Still gated: an
				 * unconditional vacate+pack streams the whole index through the
				 * buffer pool twice and would be the dominant cost of routine
				 * autovacuum on a large index.
				 *
				 * The gate is deliberately generous (>= 25% free) because
				 * bm25_vacuum_compact is itself incremental and interruptible: it
				 * loops pass-by-pass, re-checks convergence each time, and its
				 * caller holds the maintenance lock, so a cancelled pass simply
				 * resumes on the next autovacuum cycle.  Combined with the
				 * unconditional truncate above and the merge now truncating its
				 * own tail, an index under sustained insert/delete churn
				 * converges toward its floor across successive cycles WITHOUT the
				 * operator scheduling anything.
				 */
				/*
				 * freeblks says there is dead space; bm25_have_recyclable_room()
				 * says whether it can actually be REUSED yet.  Without the second
				 * question a pass run right after this cleanup's own merge finds
				 * every freed page still visible to our transaction, extends
				 * instead of reclaiming, and grows the index ~3x the live size on
				 * every cycle.  Deferring costs nothing: the next cycle runs in a
				 * new transaction where those pages have become removable, and
				 * then the compaction actually shrinks the file.  That is what
				 * makes repeated cleanup converge with no operator action.
				 */
				if (nblocks > 16 && freeblks > nblocks / 4 &&
					bm25_have_recyclable_room(info->index,
											  nblocks - freeblks))
					(void) bm25_vacuum_compact(info->index);
			}
		}
		PG_FINALLY();
		{
			bm25_maintenance_unlock(info->index);
		}
		PG_END_TRY();
	}

	return stats;
}

PG_FUNCTION_INFO_V1(fts_merge);

/*
 * Guard shared by the SQL-callable maintenance functions (fts_merge,
 * fts_vacuum).  Both take heavy locks and write WAL, and both accept an
 * arbitrary index OID from any caller, so before doing any work:
 *
 *   - refuse to run during recovery: a hot standby is read-only, and the first
 *     WAL write during recovery would fail hard (worst case a PANIC that
 *     recycles the backend).  The AM callbacks do not need this -- core never
 *     invokes them during recovery -- so the gap is only in these SQL functions.
 *   - require the caller to own the index (same owner as the underlying table):
 *     otherwise any role could trigger a costly compaction, or an
 *     AccessExclusiveLock stall (fts_vacuum), on an index it has no rights to.
 */
static void
bm25_maintenance_guard(Oid indexoid, const char *fname)
{
	if (RecoveryInProgress())
		ereport(ERROR,
				(errcode(ERRCODE_READ_ONLY_SQL_TRANSACTION),
				 errmsg("%s() cannot run during recovery", fname)));
	if (!object_ownercheck(RelationRelationId, indexoid, GetUserId()))
		aclcheck_error(ACLCHECK_NOT_OWNER, OBJECT_INDEX,
					   get_rel_name(indexoid));
}

/* fts_merge(regclass) -> bool : merge the pending list on demand */
Datum
fts_merge(PG_FUNCTION_ARGS)
{
	Oid			indexoid = PG_GETARG_OID(0);
	Relation	index;
	bool		done;

	bm25_maintenance_guard(indexoid, "fts_merge");
	index = index_open(indexoid, ShareUpdateExclusiveLock);
	if (index->rd_rel->relam != get_index_am_oid("fts", true))
		ereport(ERROR,
				(errcode(ERRCODE_WRONG_OBJECT_TYPE),
				 errmsg("\"%s\" is not an fts index",
						RelationGetRelationName(index))));
	/* serialize against a concurrent flush/merge/compact (autovacuum cleanup or
	 * another fts_merge/fts_vacuum): the index SUEL does not conflict with
	 * autovacuum's TABLE lock, so this page lock is the mutex.  Blocking. */
	bm25_maintenance_lock(index);
	PG_TRY();
	{
		done = bm25_flush_pending(index);
		/*
		 * Also compact the segment directory to a single optimal segment.  This is
		 * what makes fts_merge() an explicit "optimize now": after a parallel build
		 * (which leaves the workers' segments unmerged for speed) or churn, one call
		 * yields a one-segment index.  The tiered auto-merge deliberately leaves
		 * several same-size segments, so it is not enough on its own here.
		 */
		if (bm25_merge_all(index, true))
			done = true;
	}
	PG_FINALLY();
	{
		bm25_maintenance_unlock(index);
	}
	PG_END_TRY();
	index_close(index, ShareUpdateExclusiveLock);

	PG_RETURN_BOOL(done);
}

PG_FUNCTION_INFO_V1(fts_vacuum);

/*
 * fts_vacuum(regclass) -> bool : on-demand full compaction with truncation.
 * Like fts_merge(), but after compacting to one segment it reclaims the dead
 * pages left by prior merges -- packing live pages at the front of the file
 * and truncating the free tail back to the OS.  Use this to shrink an index
 * that has grown physically larger than its live contents.
 *
 * Takes AccessExclusiveLock on the index (like REINDEX): the vacate+pack phase
 * recycles just-freed pages immediately, which is only safe when no concurrent
 * scan can still be reading them.  Under the weaker ShareUpdateExclusiveLock a
 * scan could read a page mid-recycle (a rare crash); the exclusive lock is the
 * price of single-pass in-place shrink.  Autovacuum's cleanup path compacts
 * under its own SUEL and therefore keeps the recycle gate, reclaiming across
 * passes rather than corrupting a concurrent scan.
 */
Datum
fts_vacuum(PG_FUNCTION_ARGS)
{
	Oid			indexoid = PG_GETARG_OID(0);
	Relation	index;
	bool		done;

	bm25_maintenance_guard(indexoid, "fts_vacuum");
	index = index_open(indexoid, AccessExclusiveLock);
	if (index->rd_rel->relam != get_index_am_oid("fts", true))
		ereport(ERROR,
				(errcode(ERRCODE_WRONG_OBJECT_TYPE),
				 errmsg("\"%s\" is not an fts index",
						RelationGetRelationName(index))));
	/* AccessExclusiveLock on the index blocks scans/inserts on it, but NOT
	 * autovacuum's cleanup (which locks the table) -- so still take the
	 * maintenance mutex.  Blocking. */
	bm25_maintenance_lock(index);
	PG_TRY();
	{
		done = bm25_flush_pending(index);
		if (bm25_vacuum_compact(index))
			done = true;
	}
	PG_FINALLY();
	{
		bm25_maintenance_unlock(index);
	}
	PG_END_TRY();
	index_close(index, AccessExclusiveLock);

	PG_RETURN_BOOL(done);
}

static void
bm25_costestimate(PlannerInfo *root, IndexPath *path, double loop_count,
				  Cost *indexStartupCost, Cost *indexTotalCost,
				  Selectivity *indexSelectivity, double *indexCorrelation,
				  double *indexPages)
{
	GenericCosts costs = {0};

	/* baseline: generic estimate gives selectivity, pages, and row counts */
	genericcostestimate(root, path, loop_count, &costs);

	*indexSelectivity = costs.indexSelectivity;
	*indexCorrelation = costs.indexCorrelation;
	*indexPages = costs.numIndexPages;

	if (path->indexorderbys != NIL)
	{
		/*
		 * Ordering scan (ORDER BY ftsdoc <=> ftsquery): the AM runs block-max
		 * WAND / MaxScore and, with a LIMIT pushed down, the executor pulls only
		 * about k best results -- work is sublinear in the match set, unlike a
		 * generic full index scan.  Price it as mostly a modest startup plus a
		 * small per-tuple cost, so the planner prefers the index (which honours
		 * the ORDER BY) over a seqscan + sort.  We deliberately keep this low
		 * but nonzero; the LIMIT is applied by the caller (limit_tuples), so a
		 * cheap-per-tuple total lets a small LIMIT win and a large one still
		 * scale.
		 */
		double		ntuples = costs.numIndexTuples;

		*indexStartupCost = costs.indexStartupCost + 2.0 * cpu_operator_cost;
		/* WAND touches ~log(N)*k blocks, not all matches: charge a fraction of
		 * a page fetch per matching tuple plus the per-tuple CPU */
		*indexTotalCost = *indexStartupCost +
			ntuples * (cpu_index_tuple_cost + cpu_operator_cost) +
			0.25 * costs.numIndexPages * costs.spc_random_page_cost;
	}
	else
	{
		/*
		 * Plain @@@ scan: the generic estimate (selectivity from clause
		 * selectivity, pages from the posting lists) is a reasonable model of
		 * decoding the matching TID sets, so use it as-is.
		 */
		*indexStartupCost = costs.indexStartupCost;
		*indexTotalCost = costs.indexTotalCost;
	}
}

static bytea *
bm25_options(Datum reloptions, bool validate)
{
	static const relopt_parse_elt tab[] = {
		{"positions", RELOPT_TYPE_BOOL, offsetof(BM25Options, positions)},
		{"trigrams", RELOPT_TYPE_BOOL, offsetof(BM25Options, trigrams)},
		{"doclen_sidecar", RELOPT_TYPE_BOOL, offsetof(BM25Options, doclen_sidecar)},
	};

	return (bytea *) build_reloptions(reloptions, validate,
									  bm25_relopt_kind,
									  sizeof(BM25Options),
									  tab, lengthof(tab));
}

/*
 * Does this index carry token positions in its postings?  Reads the
 * `positions` reloption (default OFF -- positions ~double the posting bytes,
 * so the size-sensitive majority who never phrase-search pay nothing; phrase
 * users opt in with WITH (positions=on)).  Phrase/NEAR is CORRECT either way:
 * positions=on evaluates it from the postings with no recheck; positions=off
 * falls back to the (correct, slower) heap recheck.
 */
static bool
bm25_index_wants_positions(Relation index)
{
	BM25Options *opts = (BM25Options *) index->rd_options;

	return opts ? opts->positions : false;
}

/*
 * Does this index build the per-segment trigram index?  Reads the `trigrams`
 * reloption (default OFF).  The trigram index accelerates only regex and
 * over-long fuzzy terms and is ~18% of the on-disk index, so it is opt-in:
 * plain/boolean/ranked/phrase/prefix/short-fuzzy queries never consult it, and
 * regex/long-fuzzy remain CORRECT without it (they fall back to a full
 * dictionary scan when trgmstart is InvalidBlockNumber).  Turn it on with
 * WITH (trigrams=on) for regex- or long-fuzzy-heavy workloads.
 */
static bool
bm25_index_wants_trigrams(Relation index)
{
	BM25Options *opts = (BM25Options *) index->rd_options;

	return opts ? opts->trigrams : false;
}

/* Default ON: a new index uses the quantized doclen sidecar (v4).  WITH
 * (doclen_sidecar=off) stores doclen inline in each posting instead (the
 * pre-1.5 layout) -- an escape hatch for workloads that prefer the
 * pre-sidecar ranked-scan behavior. */
static bool
bm25_index_wants_doclen_sidecar(Relation index)
{
	BM25Options *opts = (BM25Options *) index->rd_options;
	bool		r = opts ? opts->doclen_sidecar : true;

	return r;
}

static bool
bm25_validate(Oid opclassoid)
{
	return true;
}

Datum
fts_handler(PG_FUNCTION_ARGS)
{
	IndexAmRoutine *amroutine = makeNode(IndexAmRoutine);

	amroutine->amstrategies = 2;
	amroutine->amsupport = 0;
	amroutine->amoptsprocnum = 0;
	amroutine->amcanorder = false;
	amroutine->amcanorderbyop = true;
#if PG_VERSION_NUM >= 180000
	amroutine->amcanhash = false;
	amroutine->amconsistentequality = false;
	amroutine->amconsistentordering = false;
#endif
	amroutine->amcanbackward = false;
	amroutine->amcanunique = false;
	amroutine->amcanmulticol = false;
	amroutine->amoptionalkey = false;
	amroutine->amsearcharray = false;
	amroutine->amsearchnulls = false;
	amroutine->amstorage = false;
	amroutine->amclusterable = false;
	amroutine->ampredlocks = false;
	amroutine->amcanparallel = false;
#if PG_VERSION_NUM >= 170000
	amroutine->amcanbuildparallel = true;
#endif
	amroutine->amcaninclude = false;
	amroutine->amusemaintenanceworkmem = false;
	amroutine->amparallelvacuumoptions = VACUUM_OPTION_NO_PARALLEL;
	amroutine->amkeytype = InvalidOid;

	amroutine->ambuild = bm25_build;
	amroutine->ambuildempty = bm25_buildempty;
	amroutine->aminsert = bm25_insert;
#if PG_VERSION_NUM >= 170000
	amroutine->aminsertcleanup = NULL;
#endif
	amroutine->ambulkdelete = bm25_bulkdelete;
	amroutine->amvacuumcleanup = bm25_vacuumcleanup;
	amroutine->amcanreturn = bm25_canreturn;
	amroutine->amcostestimate = bm25_costestimate;
#if PG_VERSION_NUM >= 180000
	amroutine->amgettreeheight = NULL;
#endif
	amroutine->amoptions = bm25_options;
	amroutine->amproperty = NULL;
	amroutine->ambuildphasename = NULL;
	amroutine->amvalidate = bm25_validate;
	amroutine->amadjustmembers = NULL;
	amroutine->ambeginscan = bm25_beginscan;
	amroutine->amrescan = bm25_rescan;
	amroutine->amgettuple = bm25_gettuple;
	amroutine->amgetbitmap = bm25_getbitmap;
	amroutine->amendscan = bm25_endscan;
	amroutine->ammarkpos = NULL;
	amroutine->amrestrpos = NULL;
	amroutine->amestimateparallelscan = NULL;
	amroutine->aminitparallelscan = NULL;
	amroutine->amparallelrescan = NULL;

	PG_RETURN_POINTER(amroutine);
}
