/*
 * Isolated subset-scoring prototype; included after pg_fts_am_scan.c.
 * No ordinary scan or SQL installation path calls this entry point.
 */
#include "access/heapam.h"
#include "lib/binaryheap.h"
#include "utils/rls.h"

typedef struct SubsetTid
{
	ItemPointerData root;
	ItemPointerData visible;
	int64 tie_key;
} SubsetTid;

typedef struct SubsetHit
{
	ScoredTid ranked;
	ItemPointerData visible;
	int64 tie_key;
} SubsetHit;

static struct
{
	uint64 allowed;
	uint64 seeks;
	uint64 scored;
	uint64 contributions;
	uint64 fetched;
	uint64 retries;
} subset_debug;

static int
subset_tid_cmp(const void *a, const void *b)
{
	return ItemPointerCompare((ItemPointer) &((const SubsetTid *) a)->root,
							  (ItemPointer) &((const SubsetTid *) b)->root);
}

static int
subset_hit_cmp(const void *a, const void *b)
{
	const SubsetHit *x = a;
	const SubsetHit *y = b;

	if (x->ranked.score != y->ranked.score)
		return x->ranked.score < y->ranked.score ? 1 : -1;
	if (x->tie_key != y->tie_key)
		return x->tie_key < y->tie_key ? -1 : 1;
	return ItemPointerCompare((ItemPointer) &x->ranked.tid,
							  (ItemPointer) &y->ranked.tid);
}

/* PostgreSQL's binaryheap puts the greatest element first: make that worst. */
static int
subset_worst_cmp(Datum a, Datum b, void *arg)
{
	SubsetHit *x = (SubsetHit *) DatumGetPointer(a);
	SubsetHit *y = (SubsetHit *) DatumGetPointer(b);

	return subset_hit_cmp(x, y);
}

/* Current visible ctids only. Map HOT children while holding a page lock. */
static int
subset_root_tids(Relation heap, ArrayType *arr, ArrayType *keys, Snapshot snap, SubsetTid **out)
{
	Datum *values;
	bool *nulls;
	int n, i, used = 0;
	SubsetTid *input;
	SubsetTid *mapped;
	Datum *keyvalues = NULL;
	bool *keynulls = NULL;
	int nkeys = 0;

	deconstruct_array(arr, TIDOID, sizeof(ItemPointerData), false, TYPALIGN_SHORT,
					  &values, &nulls, &n);
	if (keys != NULL)
	{
		if (ARR_ELEMTYPE(keys) != INT8OID || ARR_NDIM(keys) > 1)
			ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE), errmsg("subset prototype: invalid tie-key array")));
		deconstruct_array(keys, INT8OID, sizeof(int64), FLOAT8PASSBYVAL, TYPALIGN_DOUBLE,
						  &keyvalues, &keynulls, &nkeys);
		if (nkeys != n)
			ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE), errmsg("subset prototype: tie-key length mismatch")));
	}
	input = (SubsetTid *) FTS_ALLOC_MAYBE_HUGE((Size) Max(n, 1) * sizeof(SubsetTid));
	mapped = (SubsetTid *) FTS_ALLOC_MAYBE_HUGE((Size) Max(n, 1) * sizeof(SubsetTid));
	for (i = 0; i < n; i++)
	{
		if ((i & 1023) == 0)
			CHECK_FOR_INTERRUPTS();
		if (nulls[i])
			ereport(ERROR, (errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
							errmsg("subset prototype: NULL allowed TID")));
		input[i].root = input[i].visible = *((ItemPointer) DatumGetPointer(values[i]));
		if (keys != NULL && keynulls[i])
			ereport(ERROR, (errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED), errmsg("subset prototype: NULL tie key")));
		input[i].tie_key = keys != NULL ? DatumGetInt64(keyvalues[i]) : 0;
		if (!ItemPointerIsValid(&input[i].visible) ||
			ItemPointerGetOffsetNumber(&input[i].visible) > MaxHeapTuplesPerPage)
			ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
							errmsg("subset prototype: invalid allowed TID")));
	}
	qsort(input, n, sizeof(SubsetTid), subset_tid_cmp);
	for (i = 1; i < n; i++)
		if (ItemPointerEquals(&input[i - 1].visible, &input[i].visible) &&
			input[i - 1].tie_key != input[i].tie_key)
			ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE), errmsg("subset prototype: conflicting duplicate tie keys")));
	for (i = 0; i < n;)
	{
		BlockNumber block = ItemPointerGetBlockNumber(&input[i].visible);
		Buffer buf;
		Page page;
		OffsetNumber roots[MaxHeapTuplesPerPage];

		CHECK_FOR_INTERRUPTS();
		if (block >= RelationGetNumberOfBlocks(heap))
			ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
							errmsg("subset prototype: allowed TID outside heap")));
		buf = ReadBuffer(heap, block);
		LockBuffer(buf, BUFFER_LOCK_SHARE);
		page = BufferGetPage(buf);
		heap_get_root_tuples(page, roots);
		while (i < n && ItemPointerGetBlockNumber(&input[i].visible) == block)
		{
			OffsetNumber off = ItemPointerGetOffsetNumber(&input[i].visible);

			if (off <= PageGetMaxOffsetNumber(page))
			{
				ItemId item = PageGetItemId(page, off);

				if (ItemIdIsNormal(item) && roots[off - 1] != InvalidOffsetNumber)
				{
					HeapTupleData tuple;

					tuple.t_data = (HeapTupleHeader) PageGetItem(page, item);
					tuple.t_len = ItemIdGetLength(item);
					tuple.t_self = input[i].visible;
					tuple.t_tableOid = RelationGetRelid(heap);
					if (HeapTupleSatisfiesVisibility(&tuple, snap, buf))
					{
						mapped[used].visible = input[i].visible;
						ItemPointerSet(&mapped[used].root, block, roots[off - 1]);
						mapped[used].tie_key = keys != NULL ? input[i].tie_key :
							(int64) bm25_tid_to_docid(&mapped[used].root);
						used++;
					}
				}
			}
			i++;
		}
		UnlockReleaseBuffer(buf);
	}
	qsort(mapped, used, sizeof(SubsetTid), subset_tid_cmp);
	if (used > 1)
	{
		int unique = 1;

		for (i = 1; i < used; i++)
			if (!ItemPointerEquals(&mapped[i].root, &mapped[unique - 1].root))
				mapped[unique++] = mapped[i];
		used = unique;
	}
	pfree(input);
	pfree(values);
	pfree(nulls);
	if (keyvalues)
		pfree(keyvalues);
	if (keynulls)
		pfree(keynulls);
	*out = mapped;
	return used;
}

static int
subset_score(Relation index, Relation heap, FtsQuery q,
			 SubsetTid *allowed, int nallowed, int k,
			 const BM25MetaPageData *meta, SubsetHit **out)
{
	const char **terms;
	int *lens;
	int nterms = fts_query_terms(q, &terms, &lens);
	int nactive = 0, t, i, nhits = 0;
	double N = Max(meta->ndocs, 1.0);
	double avgdl = meta->ndocs > 0 ? meta->sumdoclen / meta->ndocs : 1.0;
	BM25DoclenDirCache *dir = bm25_doclendir_cache(index, meta);
	BM25DoclenResident *resident;
	BM25Tombstones tombs;
	WandCursor *cursors;
	BoolGate gate;
	SubsetHit *hits;
	binaryheap *top;
	double *acc;
	IndexFetchTableData *fetch;
	TupleTableSlot *slot;

	resident = (BM25DoclenResident *) palloc0(sizeof(BM25DoclenResident) * Max((int) meta->nsegments, 1));
	cursors = (WandCursor *) palloc0(sizeof(WandCursor) * Max(nterms * (int) meta->nsegments, 1)); /* alloc-ok: <=64 query terms x <=128 segments */
	hits = (SubsetHit *) FTS_ALLOC_MAYBE_HUGE(sizeof(SubsetHit) * (Size) k);
	top = binaryheap_allocate(k, subset_worst_cmp, NULL);
	acc = (double *) palloc0(sizeof(double) * Max(nterms, 1)); /* alloc-ok: <=64 query terms */
	bm25_tombstones_load(index, meta, &tombs);
	for (t = 0; t < nterms; t++)
	{
		uint64 gdf = 0;
		uint32 s;
		double idf;

		for (s = 0; s < meta->nsegments; s++)
		{
			uint32 df, mtf, fo;
			BlockNumber fb;

			if (bm25_lookup_dict(index, &meta->segs[s], terms[t], lens[t], &df, &mtf, &fb, &fo, dir))
				gdf += df;
		}
		idf = bm25_index_idf(N, (double) gdf);
		for (s = 0; s < meta->nsegments; s++)
		{
			uint32 df, mtf, fo;
			BlockNumber fb;
			WandCursor *c;
			sm_cursor_t ini = SM_CURSOR_INIT;

			if (!bm25_lookup_dict(index, &meta->segs[s], terms[t], lens[t], &df, &mtf, &fb, &fo, dir))
				continue;
			c = &cursors[nactive++];
			c->index = index;
			c->firstblk = fb;
			c->firstoff = fo;
			c->df = df;
			c->termidx = t;
			c->idf = idf;
			c->avgdl = avgdl;
			c->k1b_inv_avgdl = 1.2 * 0.75 / avgdl;
			c->k1_1mb = 1.2 * (1.0 - 0.75);
			c->idf_k1p1 = idf * (1.2 + 1.0);
			c->tombs = &tombs;
			c->segidx = s;
			c->tombcursor = ini;
			c->has_doclen_col = meta->segs[s].doclenstart == InvalidBlockNumber;
			c->docid_lo = 0;
			c->docid_hi = UINT64_MAX;
			bm25_doclen_cursor_init(&c->doclenc, index, &meta->segs[s], dir, &resident[s]);
			wand_prime(c);
		}
	}
	gate.q = q;
	gate.nterms = nterms;
	gate.present = (bool *) palloc0(sizeof(bool) * Max(nterms, 1)); /* alloc-ok: <=64 query terms */
	gate.stack = (bool *) palloc(sizeof(bool) * Max(q->nitems, 1));
	gate.phrase = NULL;
#if PG_VERSION_NUM >= 190000
	fetch = table_index_fetch_begin(heap, SO_NONE);
#else
	fetch = table_index_fetch_begin(heap);
#endif
	slot = table_slot_create(heap, NULL);
	PG_TRY();
	{
		for (i = 0; i < nallowed; i++)
		{
			uint64 docid = bm25_tid_to_docid(&allowed[i].root);
			bool again = false, dead = false;
			ItemPointerData root = allowed[i].root;
			SubsetHit hit;

			CHECK_FOR_INTERRUPTS();
			for (t = 0; t < nactive; t++)
			{
				if (cursors[t].docid < docid)
				{
					wand_seek(&cursors[t], docid);
					subset_debug.seeks++;
				}
			}
			if (!bmw_gate_admits(&gate, cursors, nactive, docid))
				continue;
			subset_debug.fetched++;
			ExecClearTuple(slot);
			if (!table_index_fetch_tuple(fetch, &root, GetActiveSnapshot(), slot, &again, &dead) ||
				!ItemPointerEquals(&slot->tts_tid, &allowed[i].visible))
				continue;
			MemSet(acc, 0, sizeof(double) * Max(nterms, 1));
			for (t = 0; t < nactive; t++)
			{
				if (cursors[t].docid == docid)
				{
					acc[cursors[t].termidx] += wand_contrib_cur(&cursors[t]);
					subset_debug.contributions++;
				}
			}
			hit.ranked.tid = allowed[i].root;
			hit.ranked.score = sum_term_order(acc, nterms);
			hit.visible = slot->tts_tid;
			hit.tie_key = allowed[i].tie_key;
			subset_debug.scored++;
			if (nhits < k)
			{
				hits[nhits] = hit;
				binaryheap_add_unordered(top, PointerGetDatum(&hits[nhits++]));
				if (nhits == k)
					binaryheap_build(top);
			}
			else
			{
				SubsetHit *worst = (SubsetHit *) DatumGetPointer(binaryheap_first(top));

				if (subset_hit_cmp(worst, &hit) > 0)
				{
					*worst = hit;
					binaryheap_replace_first(top, PointerGetDatum(worst));
				}
			}
		}
	}
	PG_FINALLY();
	{
		table_index_fetch_end(fetch);
		ExecDropSingleTupleTableSlot(slot);
	}
	PG_END_TRY();
	for (t = 0; t < nactive; t++)
	{
		if (cursors[t].blkbuf)
			pfree(cursors[t].blkbuf);
		bm25_doclen_cursor_free(&cursors[t].doclenc);
	}
	bm25_tombstones_free(&tombs);
	qsort(hits, nhits, sizeof(SubsetHit), subset_hit_cmp);
	*out = hits;
	return nhits;
}

PG_FUNCTION_INFO_V1(fts_search_subset);
Datum
fts_search_subset(PG_FUNCTION_ARGS)
{
	FuncCallContext *funcctx;
	SubsetHit *results;

	if (SRF_IS_FIRSTCALL())
	{
		Oid indexoid = PG_GETARG_OID(0);
		FtsQuery q = PG_GETARG_FTSQUERY(1);
		ArrayType *arr = PG_GETARG_ARRAYTYPE_P(2);
		int k = PG_GETARG_INT32(3);
		ArrayType *keys = PG_NARGS() == 5 ? PG_GETARG_ARRAYTYPE_P(4) : NULL;
		MemoryContext oldctx;
		Relation index, heap;
		TupleDesc desc;
		SubsetTid *allowed;
		int nallowed, nvis = 0;
		uint32 qi;

		MemSet(&subset_debug, 0, sizeof(subset_debug));
		if (k < 1 || k > 10000 || ARR_ELEMTYPE(arr) != TIDOID || ARR_NDIM(arr) > 1)
			ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
							errmsg("subset prototype: k must be 1..10000 and allowed TIDs one-dimensional")));
		if (q->nitems > 127)
			ereport(ERROR, (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
							errmsg("subset prototype: at most 64 plain query terms supported")));
		for (qi = 0; qi < q->nitems; qi++)
		{
			FtsQueryItem *it = &q->items[qi];

			if ((it->type == FTS_QI_VAL && it->flags != 0) ||
				(it->type != FTS_QI_VAL && it->op != FTS_OP_AND && it->op != FTS_OP_OR))
				ereport(ERROR, (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
							errmsg("subset prototype: only positive plain AND/OR queries supported")));
		}
		funcctx = SRF_FIRSTCALL_INIT();
		oldctx = MemoryContextSwitchTo(funcctx->multi_call_memory_ctx);
		if (get_call_result_type(fcinfo, NULL, &desc) != TYPEFUNC_COMPOSITE)
			elog(ERROR, "subset prototype requires a row result");
		funcctx->tuple_desc = BlessTupleDesc(desc);
		index = index_open(indexoid, AccessShareLock);
		if (index->rd_rel->relam != get_index_am_oid("fts", false) ||
			!index->rd_index->indisvalid || !index->rd_index->indisready ||
			RelationGetIndexPredicate(index) != NIL)
			ereport(ERROR, (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
							errmsg("subset prototype requires a valid non-partial fts index")));
		heap = table_open(index->rd_index->indrelid, AccessShareLock);
		PG_TRY();
		{
			if (heap->rd_rel->relam != HEAP_TABLE_AM_OID || IsolationIsSerializable() ||
				check_enable_rls(RelationGetRelid(heap), InvalidOid, true) != RLS_NONE)
				ereport(ERROR, (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
								errmsg("subset prototype requires ordinary heap, no RLS, non-serializable snapshot")));
			if (pg_class_aclcheck(RelationGetRelid(heap), GetUserId(), ACL_SELECT) != ACLCHECK_OK)
				aclcheck_error(ACLCHECK_NO_PRIV, OBJECT_TABLE, RelationGetRelationName(heap));
			nallowed = subset_root_tids(heap, arr, keys, GetActiveSnapshot(), &allowed);
			subset_debug.allowed = nallowed;
			results = NULL;
			if (nallowed > 0 && q->nitems > 0)
			{
				int attempt;

				for (attempt = 0; attempt < 3; attempt++)
				{
					BM25MetaPageData meta, after;
					MemoryContext ctx;
					SubsetHit *hits;

					bm25_read_meta(index, &meta);
					if (meta.npending > 0)
						ereport(ERROR, (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
										errmsg("subset prototype: pending entries require ordinary search")));
					ctx = AllocSetContextCreate(CurrentMemoryContext, "pg_fts subset attempt", ALLOCSET_DEFAULT_SIZES);
					MemoryContextSwitchTo(ctx);
					nvis = subset_score(index, heap, q, allowed, nallowed, Min(k, nallowed), &meta, &hits);
					MemoryContextSwitchTo(funcctx->multi_call_memory_ctx);
					bm25_read_meta(index, &after);
					if (after.generation == meta.generation && after.npending == 0)
					{
						results = (SubsetHit *) FTS_ALLOC_MAYBE_HUGE(sizeof(SubsetHit) * (Size) Max(nvis, 1));
						memcpy(results, hits, sizeof(SubsetHit) * nvis);
						MemoryContextDelete(ctx);
						break;
					}
					MemoryContextDelete(ctx);
					subset_debug.retries++;
				}
				if (results == NULL)
					ereport(ERROR, (errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
									errmsg("subset prototype: index generation changed repeatedly")));
			}
			funcctx->max_calls = nvis;
			funcctx->user_fctx = results;
		}
		PG_FINALLY();
		{
			table_close(heap, AccessShareLock);
			index_close(index, AccessShareLock);
		}
		PG_END_TRY();
		MemoryContextSwitchTo(oldctx);
	}
	funcctx = SRF_PERCALL_SETUP();
	results = (SubsetHit *) funcctx->user_fctx;
	if (funcctx->call_cntr < funcctx->max_calls)
	{
		Datum values[2];
		bool nulls[2] = {false, false};
		ItemPointer copy = palloc(sizeof(ItemPointerData));

		*copy = results[funcctx->call_cntr].visible;
		values[0] = PointerGetDatum(copy);
		values[1] = Float8GetDatum(results[funcctx->call_cntr].ranked.score);
		SRF_RETURN_NEXT(funcctx, HeapTupleGetDatum(heap_form_tuple(funcctx->tuple_desc, values, nulls)));
	}
	SRF_RETURN_DONE(funcctx);
}

PG_FUNCTION_INFO_V1(fts_subset_prototype_stats);
Datum
fts_subset_prototype_stats(PG_FUNCTION_ARGS)
{
	char *json = psprintf("{\"allowed\":%llu,\"seeks\":%llu,\"scored\":%llu,\"contributions\":%llu,\"fetched\":%llu,\"retries\":%llu}",
		(unsigned long long) subset_debug.allowed, (unsigned long long) subset_debug.seeks,
		(unsigned long long) subset_debug.scored, (unsigned long long) subset_debug.contributions,
		(unsigned long long) subset_debug.fetched, (unsigned long long) subset_debug.retries);

	PG_RETURN_DATUM(DirectFunctionCall1(jsonb_in, CStringGetDatum(json)));
}
