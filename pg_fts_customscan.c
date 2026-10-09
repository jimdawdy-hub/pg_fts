/*-------------------------------------------------------------------------
 *
 * pg_fts_customscan.c
 *	  CustomScan providers for pg_fts:
 *	    1. COUNT pushdown -- answer  SELECT count(*) ... WHERE col @@@ q
 *	       from the bm25 index (VM-based bulk count) instead of a bitmap heap
 *	       scan, ~3x faster on a common term.
 *	    (later stages add a parallel ranked top-k CustomScan)
 *
 * The providers are installed by _PG_init via create_upper_paths_hook (count)
 * and set_rel_pathlist_hook (ranked).  They are strictly additive: a candidate
 * CustomPath is only *added* alongside the normal paths, so if anything about
 * the shape is unsupported we simply add nothing and the planner uses the
 * ordinary plan.  Nothing here changes results -- only the mechanism.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/genam.h"
#include "access/relscan.h"
#include "access/table.h"
#include "catalog/index.h"
#include "catalog/namespace.h"
#include "commands/defrem.h"
#include "catalog/pg_operator.h"
#include "catalog/pg_type.h"
#include "executor/executor.h"
#include "utils/guc.h"
#include "executor/tuptable.h"
#include "nodes/extensible.h"
#include "nodes/makefuncs.h"
#include "nodes/nodeFuncs.h"
#include "nodes/pathnodes.h"
#include "nodes/plannodes.h"
#include "optimizer/optimizer.h"
#include "optimizer/pathnode.h"
#include "optimizer/paths.h"
#include "optimizer/planmain.h"
#include "optimizer/planner.h"
#include "parser/parse_oper.h"
#include "parser/parse_type.h"
#include "parser/parsetree.h"
#include "utils/builtins.h"
#include "utils/fmgroids.h"
#include "utils/datum.h"
#include "utils/lsyscache.h"
#include "utils/rel.h"
#include "utils/syscache.h"
#include "catalog/pg_proc.h"
#include "catalog/pg_language.h"

#include "pg_fts.h"
#include "pg_fts_am.h"			/* bm25_init_reloptions */

/* engine entry point implemented in pg_fts_am_scan.c (via pg_fts_am.c) */
extern int64 bm25_count_visible_oid(Oid indexoid, FtsQuery q);

PG_FUNCTION_INFO_V1(pg_fts_customscan_dummy);	/* keeps the file non-empty for old toolchains */
Datum
pg_fts_customscan_dummy(PG_FUNCTION_ARGS)
{
	PG_RETURN_NULL();
}

/* ---- saved previous hooks (chain, do not clobber) ---- */
static create_upper_paths_hook_type prev_upper_paths_hook = NULL;
static planner_hook_type prev_planner_hook = NULL;

/* cached OID of the @@@ (ftsdoc, ftsquery) operator; resolved lazily */
static Oid	fts_match_op = InvalidOid;

/*
 * ===== LIMIT hint for the ORDER BY <=> ordering scan (1.9.0) =====
 *
 * An index AM is never told the query's LIMIT, so bm25_gettuple used to compute
 * a fixed top-100 (and bm25_topk_visible over-fetched x4 on top: WAND top-400
 * for a LIMIT 10).  A deep k keeps WAND's threshold low and disables block
 * skipping.  After planning, walk the plan: for every  Limit -> IndexScan  on a
 * bm25 index whose single ORDER BY is  <expr> <=> <ftsquery Const>  and whose
 * LIMIT/OFFSET are constants, replace that Const with a COPY carrying
 * k = limit + offset in FtsQueryData.flags.
 *
 * Safety: the hint only sizes the FIRST batch.  bm25_gettuple's grow-and-
 * recompute path is unchanged, so an executor that pulls past k (a cursor, a
 * changed plan) still gets every row in exact order -- the hint can cost a
 * recompute, never a wrong or missing row.  The original Const is never written
 * (it may be shared with the plan cache); a fresh one replaces it.  Same
 * approach as pg_textsearch's tp_attach_seed_hint.
 */
static bool
fts_limit_const(Node *n, int64 *v)
{
	Const	   *c;

	if (n == NULL || !IsA(n, Const))
		return false;
	c = (Const *) n;
	if (c->constisnull || c->consttype != INT8OID)
		return false;
	*v = DatumGetInt64(c->constvalue);
	return true;
}

/*
 * The OID of pg_fts's own fts_current_distance(), resolved in the same schema
 * as the ftsquery type, and only if its C symbol is the one in this module
 * (pg_proc.prosrc = 'fts_current_distance', language C).  InvalidOid if the
 * installed SQL predates it -- score reuse is then simply off.
 */
static Oid
fts_lookup_current_distance_fn(void)
{
	Oid			typoid = TypenameGetTypid("ftsquery");
	Oid			nsp;
	Oid			fn;
	HeapTuple	tup;
	bool		ok = false;

	if (!OidIsValid(typoid))
		return InvalidOid;
	tup = SearchSysCache1(TYPEOID, ObjectIdGetDatum(typoid));
	if (!HeapTupleIsValid(tup))
		return InvalidOid;
	nsp = ((Form_pg_type) GETSTRUCT(tup))->typnamespace;
	ReleaseSysCache(tup);
	fn = GetSysCacheOid3(PROCNAMEARGSNSP, Anum_pg_proc_oid,
						 CStringGetDatum("fts_current_distance"),
						 PointerGetDatum(buildoidvector(NULL, 0)),
						 ObjectIdGetDatum(nsp));
	if (!OidIsValid(fn))
		return InvalidOid;
	tup = SearchSysCache1(PROCOID, ObjectIdGetDatum(fn));
	if (HeapTupleIsValid(tup))
	{
		Form_pg_proc p = (Form_pg_proc) GETSTRUCT(tup);
		bool		isnull;
		Datum		src = SysCacheGetAttr(PROCOID, tup, Anum_pg_proc_prosrc, &isnull);

		ok = (p->prolang == ClanguageId && p->prorettype == FLOAT8OID && !isnull &&
			  strcmp(TextDatumGetCString(src), "fts_current_distance") == 0);
		ReleaseSysCache(tup);
	}
	return ok ? fn : InvalidOid;
}

static bool
fts_is_bm25_indexscan(IndexScan *scan)
{
	Relation	irel;
	bool		isfts;

	irel = index_open(scan->indexid, NoLock);
	isfts = (irel->rd_indam != NULL && irel->rd_indam->amgettuple == bm25_gettuple);
	index_close(irel, NoLock);
	return isfts;
}

/*
 * Score reuse (1.9.0).  An ORDER BY <=> ordering scan computes each row's exact
 * distance from the index, but the planner also places the same `d <=> q`
 * expression in the scan's target list (it feeds the sort key / Limit), so the
 * executor RE-EVALUATED fts_distance per returned row: a heap detoast of the
 * whole ftsdoc plus a fresh BM25.  That was 28% of a rare-term ranked query
 * (perf, 2026-10-01).  Replace each target-list entry that is equal() to the
 * scan's own indexorderbyorig with fts_current_distance(), which returns the
 * distance bm25_gettuple stored for the current tuple.
 *
 * Exactness: only RESJUNK entries are replaced -- the copy the planner carries
 * purely as the sort key, never shown to the user.  A visible `d <=> q` keeps
 * fts_distance() (its N=1/avgdl=|D| neutral score), so no user-visible value
 * changes with the plan.  equal() to indexorderbyorig means it is the SAME
 * expression the index is ordering by, and bm25_gettuple sets
 * xs_recheckorderby = false, so the substituted value is the very Datum the
 * scan ordered on.  Only bm25 index scans are touched.
 */
static void
fts_reuse_distance(IndexScan *scan, Oid distfn)
{
	ListCell   *lc;
	Node	   *orig;

	if (list_length(scan->indexorderbyorig) != 1)
		return;
	orig = (Node *) linitial(scan->indexorderbyorig);
	foreach(lc, scan->scan.plan.targetlist)
	{
		TargetEntry *tle = (TargetEntry *) lfirst(lc);

		if (tle->resjunk && equal(tle->expr, orig))
			tle->expr = (Expr *) makeFuncExpr(distfn, FLOAT8OID, NIL,
											  InvalidOid, InvalidOid,
											  COERCE_EXPLICIT_CALL);
	}
}

static void
fts_hint_indexscan(IndexScan *scan, Limit *limit, Oid ftsqueryoid)
{
	int64		count,
				offset = 0,
				k;
	Node	   *expr;
	OpExpr	   *op;
	Const	   *orig,
			   *repl;
	FtsQuery	q;

	if (list_length(scan->indexorderby) != 1)
		return;
	if (!fts_limit_const(limit->limitCount, &count) || count <= 0)
		return;
	if (limit->limitOffset != NULL &&
		(!fts_limit_const(limit->limitOffset, &offset) || offset < 0))
		return;
	k = count + offset;
	if (k <= 0 || k > PG_UINT16_MAX)
		return;					/* deep page: leave the default batching alone */

	expr = (Node *) linitial(scan->indexorderby);
	if (!IsA(expr, OpExpr) || list_length(((OpExpr *) expr)->args) != 2)
		return;
	op = (OpExpr *) expr;
	if (!IsA(lsecond(op->args), Const))
		return;
	orig = (Const *) lsecond(op->args);
	if (orig->constisnull || orig->consttype != ftsqueryoid)
		return;

	q = (FtsQuery) DatumGetPointer(datumCopy(
		PointerGetDatum(PG_DETOAST_DATUM(orig->constvalue)), false, -1));
	q->flags = (uint16) k;
	repl = makeConst(orig->consttype, orig->consttypmod, orig->constcollid,
					 -1, PointerGetDatum(q), false, false);
	repl->location = orig->location;
	lsecond(op->args) = repl;
}

static void
fts_hint_walk(Plan *plan, Oid ftsqueryoid, Oid distfn)
{
	ListCell   *lc;

	if (plan == NULL)
		return;
	if (IsA(plan, IndexScan) && ((IndexScan *) plan)->indexorderbyorig != NIL &&
		fts_is_bm25_indexscan((IndexScan *) plan) && OidIsValid(distfn))
		fts_reuse_distance((IndexScan *) plan, distfn);
	if (IsA(plan, Limit) && plan->lefttree != NULL && IsA(plan->lefttree, IndexScan) &&
		fts_is_bm25_indexscan((IndexScan *) plan->lefttree))
		fts_hint_indexscan((IndexScan *) plan->lefttree, (Limit *) plan, ftsqueryoid);
	fts_hint_walk(plan->lefttree, ftsqueryoid, distfn);
	fts_hint_walk(plan->righttree, ftsqueryoid, distfn);
	switch (nodeTag(plan))
	{
		case T_Append:
			foreach(lc, ((Append *) plan)->appendplans)
				fts_hint_walk(lfirst(lc), ftsqueryoid, distfn);
			break;
		case T_MergeAppend:
			foreach(lc, ((MergeAppend *) plan)->mergeplans)
				fts_hint_walk(lfirst(lc), ftsqueryoid, distfn);
			break;
		case T_SubqueryScan:
			fts_hint_walk(((SubqueryScan *) plan)->subplan, ftsqueryoid, distfn);
			break;
		case T_CustomScan:
			foreach(lc, ((CustomScan *) plan)->custom_plans)
				fts_hint_walk(lfirst(lc), ftsqueryoid, distfn);
			break;
		default:
			break;
	}
}

static PlannedStmt *
fts_planner(Query *parse, const char *query_string, int cursorOptions,
			ParamListInfo boundParams)
{
	PlannedStmt *stmt;
	Oid			ftsqueryoid;
	ListCell   *lc;

	stmt = prev_planner_hook
		? prev_planner_hook(parse, query_string, cursorOptions, boundParams)
		: standard_planner(parse, query_string, cursorOptions, boundParams);

	/* pg_fts not installed in this database / not visible: nothing to hint */
	ftsqueryoid = TypenameGetTypid("ftsquery");
	if (!OidIsValid(ftsqueryoid))
		return stmt;
	{
		/* fts_current_distance() exists from 1.9.0's SQL; on an older installed
		 * extension version it is absent and score reuse is simply skipped */
		Oid			distfn = fts_lookup_current_distance_fn();

		fts_hint_walk(stmt->planTree, ftsqueryoid, distfn);
		foreach(lc, stmt->subplans)
			fts_hint_walk((Plan *) lfirst(lc), ftsqueryoid, distfn);
	}
	return stmt;
}

/*
 * fts_current_distance() -> float8: the exact <=> distance the bm25 ordering scan
 * stored for the tuple it most recently returned in this backend.  Only ever
 * placed in a plan by fts_reuse_distance(), directly in the target list of the
 * bm25 IndexScan that sets it, so it is read for the same tuple it was set for.
 * Not meant to be called by users (it is not exposed with a useful meaning
 * outside that position).
 */
PG_FUNCTION_INFO_V1(fts_current_distance);
Datum
fts_current_distance(PG_FUNCTION_ARGS)
{
	PG_RETURN_FLOAT8(fts_current_distance_value);
}

/* ===== count-pushdown CustomScan: path/plan/exec ===== */

typedef struct FtsCountScanState
{
	CustomScanState css;
	Oid			indexoid;
	FtsQuery	query;
	bool		done;
} FtsCountScanState;

static Plan *FtsCountPlanCustomPath(PlannerInfo *root, RelOptInfo *rel,
									struct CustomPath *best_path, List *tlist,
									List *clauses, List *custom_plans);
static Node *FtsCountCreateScanState(CustomScan *cscan);
static void FtsCountBeginScan(CustomScanState *node, EState *estate, int eflags);
static TupleTableSlot *FtsCountExecScan(CustomScanState *node);
static void FtsCountEndScan(CustomScanState *node);
static void FtsCountReScan(CustomScanState *node);

static const CustomPathMethods fts_count_path_methods = {
	.CustomName = "FtsCount",
	.PlanCustomPath = FtsCountPlanCustomPath,
};

static const CustomScanMethods fts_count_scan_methods = {
	.CustomName = "FtsCount",
	.CreateCustomScanState = FtsCountCreateScanState,
};

static const CustomExecMethods fts_count_exec_methods = {
	.CustomName = "FtsCount",
	.BeginCustomScan = FtsCountBeginScan,
	.ExecCustomScan = FtsCountExecScan,
	.EndCustomScan = FtsCountEndScan,
	.ReScanCustomScan = FtsCountReScan,
};

/*
 * Resolve the @@@ operator OID in the extension's schema.  Returns InvalidOid
 * if pg_fts's SQL objects are not installed in this database's search path
 * (then the pushdown simply never triggers).
 */
static Oid
fts_lookup_match_op(void)
{
	if (OidIsValid(fts_match_op))
		return fts_match_op;
	/* @@@ (ftsdoc, ftsquery) */
	fts_match_op = OpernameGetOprid(list_make1(makeString("@@@")),
									TypenameGetTypid("ftsdoc"),
									TypenameGetTypid("ftsquery"));
	return fts_match_op;
}

/*
 * If the RestrictInfo list contains exactly one clause of the form
 *   <indexable expr> @@@ <FtsQuery Const>
 * covered by a bm25 index on `rel`, return the index OID and the query Const;
 * else InvalidOid.
 */
static Oid
fts_find_pushdown_index(PlannerInfo *root, RelOptInfo *rel,
						List *baserestrictinfo, FtsQuery *query_out)
{
	Oid			matchop = fts_lookup_match_op();
	RangeTblEntry *rte;
	Relation	heap;
	ListCell   *lc;
	OpExpr	   *matchclause = NULL;
	int			nquals = 0;

	if (!OidIsValid(matchop))
		return InvalidOid;
	if (rel->reloptkind != RELOPT_BASEREL || rel->rtekind != RTE_RELATION)
		return InvalidOid;

	/* need exactly one qual, and it must be the @@@ operator */
	foreach(lc, baserestrictinfo)
	{
		RestrictInfo *ri = (RestrictInfo *) lfirst(lc);
		OpExpr	   *op;

		nquals++;
		if (!IsA(ri->clause, OpExpr))
			return InvalidOid;
		op = (OpExpr *) ri->clause;
		if (op->opno != matchop || list_length(op->args) != 2)
			return InvalidOid;
		matchclause = op;
	}
	if (nquals != 1 || matchclause == NULL)
		return InvalidOid;

	/* the right-hand side must be a plan-time constant FtsQuery */
	{
		Node	   *rhs = (Node *) lsecond(matchclause->args);

		if (!IsA(rhs, Const) || ((Const *) rhs)->constisnull)
			return InvalidOid;
		*query_out = (FtsQuery) DatumGetPointer(((Const *) rhs)->constvalue);
	}

	/* find a bm25 index on this rel whose expression matches the LHS */
	rte = planner_rt_fetch(rel->relid, root);
	if (rte->rtekind != RTE_RELATION)
		return InvalidOid;
	heap = table_open(rte->relid, AccessShareLock);
	{
		List	   *indexoidlist = RelationGetIndexList(heap);
		ListCell   *ic;
		Oid			found = InvalidOid;
		Node	   *lhs = (Node *) linitial(matchclause->args);

		foreach(ic, indexoidlist)
		{
			Oid			indexoid = lfirst_oid(ic);
			Relation	ind = index_open(indexoid, AccessShareLock);

			if (ind->rd_rel->relam == get_index_am_oid("fts", true))
			{
				if (ind->rd_indexprs != NIL)
				{
					/* expression index (e.g. USING fts (to_ftsdoc(body))):
					 * the LHS must equal the index expression. */
					if (equal(linitial(ind->rd_indexprs), lhs))
						found = indexoid;
				}
				else if (ind->rd_index->indnatts == 1 &&
						 IsA(lhs, Var) &&
						 ((Var *) lhs)->varno == rel->relid &&
						 ((Var *) lhs)->varattno == ind->rd_index->indkey.values[0])
				{
					/* plain-column index (USING fts (d)): the LHS must be the
					 * Var for that single indexed column.  This is the stored-
					 * ftsdoc-column form the docs recommend; without this the
					 * count pushdown only fired for expression indexes and a
					 * stored-column count(*) fell back to a slow bitmap scan. */
					found = indexoid;
				}
			}
			index_close(ind, AccessShareLock);
			if (OidIsValid(found))
				break;
		}
		list_free(indexoidlist);
		table_close(heap, AccessShareLock);
		return found;
	}
}

/*
 * create_upper_paths_hook: at the GROUP/AGG stage, if the query is a bare
 * COUNT(*) over a single base rel whose only qual is `col @@@ q` with a bm25
 * index, add a CustomScan path that answers the count from the index.
 */
static void
fts_create_upper_paths(PlannerInfo *root, UpperRelationKind stage,
					   RelOptInfo *input_rel, RelOptInfo *output_rel,
					   void *extra)
{
	Query	   *parse = root->parse;
	RelOptInfo *baserel;
	Oid			indexoid;
	FtsQuery	query;
	CustomPath *cpath;

	if (prev_upper_paths_hook)
		prev_upper_paths_hook(root, stage, input_rel, output_rel, extra);

	if (stage != UPPERREL_GROUP_AGG)
		return;
	/* bare aggregate: exactly one COUNT(*), no GROUP BY / HAVING / DISTINCT / window / set-op */
	if (parse->groupClause || parse->groupingSets || parse->havingQual ||
		parse->distinctClause || parse->hasWindowFuncs || parse->setOperations ||
		parse->hasDistinctOn || list_length(parse->targetList) != 1)
		return;
	if (list_length(parse->rtable) != 1)
		return;
	{
		TargetEntry *te = (TargetEntry *) linitial(parse->targetList);
		Aggref	   *agg;

		if (!IsA(te->expr, Aggref))
			return;
		agg = (Aggref *) te->expr;
		/* count(*) : COUNT with no args, no FILTER, no DISTINCT, no ORDER BY */
		if (agg->aggfnoid != F_COUNT_ ||
			agg->args != NIL || agg->aggfilter != NULL ||
			agg->aggdistinct != NIL || agg->aggorder != NIL)
			return;
	}

	/* the single base rel */
	if (bms_num_members(input_rel->relids) != 1)
		return;
	baserel = find_base_rel(root, bms_singleton_member(input_rel->relids));
	indexoid = fts_find_pushdown_index(root, baserel, baserel->baserestrictinfo,
									   &query);
	if (!OidIsValid(indexoid))
		return;

	/* build the CustomPath -- rows=1.
	 *
	 * Cost model: the count is answered from the bm25 index + the visibility
	 * map (bm25_count_visible_oid), visiting NO heap tuples -- unlike the
	 * Bitmap Index Scan + Aggregate alternative, whose cost scales with the
	 * number of matching heap tuples it must fetch/recheck.  The old estimate
	 * (baserel->pages) priced this at the whole heap and always lost to the
	 * bitmap path even though the VM-based count is measurably faster on
	 * common terms.  Price it as a small dictionary/posting walk (a handful of
	 * index pages, VM-only) so the planner chooses the pushdown when it applies;
	 * this stays an underestimate of the true cost only relative to a full heap
	 * scan, and the pushdown is exact (index-native, no seq fallback). */
	cpath = makeNode(CustomPath);
	cpath->path.pathtype = T_CustomScan;
	cpath->path.parent = output_rel;
	cpath->path.pathtarget = output_rel->reltarget;
	cpath->path.param_info = NULL;
	cpath->path.rows = 1;
	{
		/* index-only walk: a few index pages + the VM, no heap-tuple visits.
		 * Price it at a small fraction of the heap so it beats the Bitmap Index
		 * Scan + Aggregate alternative (whose cost scales with matching-tuple
		 * fetches) yet still scales mildly with table size.  The pushdown is
		 * exact and index-native; this only changes the planner's choice
		 * between two correct count paths. */
		double		c = (double) baserel->pages * 0.01 + 1.0;

		cpath->path.startup_cost = 0.0;
		cpath->path.total_cost = c;
	}
	cpath->flags = 0;
	cpath->custom_paths = NIL;
	{
		/*
		 * Carry the query into the plan as a proper VARLENA Const, not a bare
		 * INTERNALOID pointer.  FtsQuery is a varlena blob; an INTERNALOID Const
		 * (pass-by-value, typlen 8) makes copyObject/the plan cache copy only the
		 * 8-byte POINTER, so a cached or re-executed plan (e.g. a count(*) inside
		 * a plpgsql loop) dereferences the query after its planning context is
		 * freed -- reading garbage (a bogus nitems), underflowing the RPN eval
		 * stack, and crashing (SIGSEGV) or returning wrong counts.  Storing it as
		 * a varlena Const (typlen -1, byval false) of the ftsquery type makes
		 * datumCopy() deep-copy the whole blob with the plan, so it lives exactly
		 * as long as the plan that references it.  Copy into the current (planner)
		 * context up front so the Const owns its own copy.
		 */
		Oid			ftsqueryoid = TypenameGetTypid("ftsquery");
		Datum		qcopy = datumCopy(PointerGetDatum(query), false, -1);

		cpath->custom_private =
			list_make2(makeInteger((int) indexoid),
					   makeConst(OidIsValid(ftsqueryoid) ? ftsqueryoid : BYTEAOID,
								 -1, InvalidOid, -1, qcopy, false, false));
	}
	cpath->methods = &fts_count_path_methods;
	add_path(output_rel, (Path *) cpath);
}

static Plan *
FtsCountPlanCustomPath(PlannerInfo *root, RelOptInfo *rel,
					   struct CustomPath *best_path, List *tlist,
					   List *clauses, List *custom_plans)
{
	CustomScan *cscan = makeNode(CustomScan);

	cscan->scan.plan.targetlist = tlist;
	cscan->scan.plan.qual = NIL;
	cscan->scan.scanrelid = 0;	/* no base rel scanned at exec time */
	cscan->custom_scan_tlist = tlist;
	cscan->custom_private = best_path->custom_private;
	cscan->methods = &fts_count_scan_methods;
	return &cscan->scan.plan;
}

static Node *
FtsCountCreateScanState(CustomScan *cscan)
{
	FtsCountScanState *st = (FtsCountScanState *) newNode(sizeof(FtsCountScanState),
														 T_CustomScanState);
	Const	   *qc;

	st->css.methods = &fts_count_exec_methods;
	st->indexoid = (Oid) intVal(linitial(cscan->custom_private));
	qc = (Const *) lsecond(cscan->custom_private);
	st->query = (FtsQuery) DatumGetPointer(qc->constvalue);
	st->done = false;
	return (Node *) st;
}

static void
FtsCountBeginScan(CustomScanState *node, EState *estate, int eflags)
{
	/* nothing to set up beyond the tuple slot the executor made */
}

static TupleTableSlot *
FtsCountExecScan(CustomScanState *node)
{
	FtsCountScanState *st = (FtsCountScanState *) node;
	TupleTableSlot *slot = node->ss.ps.ps_ResultTupleSlot;
	int64		c;

	if (st->done)
		return NULL;
	st->done = true;

	c = bm25_count_visible_oid(st->indexoid, st->query);

	ExecClearTuple(slot);
	slot->tts_values[0] = Int64GetDatum(c);
	slot->tts_isnull[0] = false;
	ExecStoreVirtualTuple(slot);
	return slot;
}

static void
FtsCountEndScan(CustomScanState *node)
{
}

static void
FtsCountReScan(CustomScanState *node)
{
	((FtsCountScanState *) node)->done = false;
}

/* ===== module init ===== */

void		_PG_init(void);

#ifdef PG_FTS_TEST_HOOKS
/*
 * Test-only: a scan pauses on this advisory key right after snapshotting the
 * metapage in bm25_collect_matches, so a concurrent session can free + recycle
 * the snapshotted segment's pages in exactly the vulnerable window (the A1
 * scan-vs-merge race).  0 = off (default, and the only value in production).
 * Guarded by -DPG_FTS_TEST_HOOKS so the hook does not exist in a normal build.
 */
int			pg_fts_test_pause_advisory_key = 0;
#endif

void
_PG_init(void)
{
	RegisterXactCallback(bm25_maint_xact_reset, NULL);
	bm25_init_reloptions();
	RegisterCustomScanMethods(&fts_count_scan_methods);

	/*
	 * Cap (in MB) on the total index size for which an index BUILD finalizes to
	 * a single optimal segment.  Above this, the build stops at a bounded,
	 * size-tiered set of segments (LSM-style) so it always converges instead of
	 * doing one giant single-backend collapse that can run for hours on a huge,
	 * high-vocabulary corpus.  Ranked scans then traverse a bounded handful of
	 * segments (a small, fixed cost); run fts_merge() in a maintenance window to
	 * collapse to one when desired.  0 = always collapse (the historical behavior).
	 */
	DefineCustomIntVariable("pg_fts.build_collapse_max_mb",
							"Max total index size (MB) for which a build finalizes to a single segment; larger builds stop at a bounded tiered set.",
							"Above this, an index build leaves a bounded, size-tiered set of segments so it always converges; run fts_merge() to collapse to one. 0 = always collapse.",
							&pg_fts_build_collapse_max_mb,
							4096, 0, INT_MAX,
							PGC_USERSET, GUC_UNIT_MB, NULL, NULL, NULL);

	DefineCustomBoolVariable("pg_fts.bestfirst",
							 "Single-term, AND and phrase ranked queries visit posting blocks in descending score-bound order and stop as soon as no remaining block can enter the top-k.",
							 "Results are identical; off uses the docid-order paths (block-max WAND, or exhaustive scoring above pg_fts.dense_score_min_df).",
							 &pg_fts_bestfirst,
							 true,
							 PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomIntVariable("pg_fts.dense_score_min_df",
							"Single-term ranked queries on a term with at least this many postings (in one segment) are scored exhaustively instead of with block-max WAND; 0 disables.",
							"WAND prunes almost nothing for a very common term, so scoring every posting in a tight loop is faster; results are identical.",
							&pg_fts_dense_score_min_df,
							32768, 0, INT_MAX,
							PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable("pg_fts.shared_doclen",
							 "Keep one server-wide copy of each index segment's document-length array in shared memory, instead of one per backend.",
							 "Ranked results are identical either way; with many concurrent backends the shared copy is what keeps throughput from falling. Off restores the 1.9 per-backend copies.",
							 &pg_fts_shared_doclen,
							 true,
							 PGC_SUSET, 0, NULL, NULL, NULL);

	DefineCustomBoolVariable("pg_fts.lazy_phrase",
							 "Ranked phrase queries on a positions=on index check adjacency per candidate instead of building the full phrase match set first.",
							 "Results are identical; off restores the pre-1.9.1 collect-then-rank path.",
							 &pg_fts_lazy_phrase,
							 true,
							 PGC_USERSET, 0, NULL, NULL, NULL);

	DefineCustomIntVariable("pg_fts.doclen_cache_mb",
							"Per-backend memory budget (MB) for the resident slot-indexed document-length arrays used by ranked scans; 0 disables.",
							"Each backend decodes an index's doclen sidecar once per segment-directory generation into a dense array (about 2.6 bytes per document) so scoring reads a document's length with two array reads. A segment that does not fit keeps the page-directory lookup.",
							&pg_fts_doclen_cache_mb,
							64, 0, 1024,
							PGC_USERSET, GUC_UNIT_MB, NULL, NULL, NULL);

	DefineCustomIntVariable("pg_fts.build_mem_ceiling_mb",
							"Per-participant build flush-budget growth ceiling (MB); 0 = 2*maintenance_work_mem.",
							"Raise to trade RAM for fewer, larger segments on a very large build so its segment count stays under the cap. Peak build memory is about (max_parallel_maintenance_workers + 1) * this. 0 keeps the memory-safe default ceiling.",
							&pg_fts_build_mem_ceiling_mb,
							0, 0, INT_MAX,
							PGC_USERSET, GUC_UNIT_MB, NULL, NULL, NULL);

#ifdef PG_FTS_TEST_HOOKS
	/*
	 * TEST-ONLY build.  This GUC only exists when compiled with
	 * -DPG_FTS_TEST_HOOKS (never in a release build recipe -- Makefile, meson,
	 * and flake all omit it).  Announce loudly at load so a test-hook build can
	 * never be mistaken for, or silently shipped as, a production build.
	 */
	ereport(WARNING,
			(errmsg("pg_fts was built with PG_FTS_TEST_HOOKS: this is a TEST build, not for production")));
	DefineCustomIntVariable("pg_fts.test_pause_advisory_key",
							"TEST-ONLY: advisory key a scan waits on mid-collect (0=off).",
							NULL,
							&pg_fts_test_pause_advisory_key,
							0, 0, INT_MAX,
							PGC_USERSET, 0, NULL, NULL, NULL);
#endif

	prev_upper_paths_hook = create_upper_paths_hook;
	create_upper_paths_hook = fts_create_upper_paths;
	prev_planner_hook = planner_hook;
	planner_hook = fts_planner;
}
