/*-------------------------------------------------------------------------
 *
 * pg_fts_match.c
 *		Match evaluation: does an ftsdoc satisfy an ftsquery?
 *
 * The query is a postfix (RPN) item list, so evaluation is a stack machine: a
 * term operand pushes "does this doc contain the term", and each operator pops
 * its arguments and pushes the combined result.  Beyond boolean AND/OR/NOT it
 * evaluates phrase and NEAR (using per-term positions), prefix, fuzzy (bounded
 * Levenshtein) and regex operands.  It mirrors tsquery's TS_execute strategy;
 * O(nitems * log nterms) with the binary-search term lookup.
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 *
 * IDENTIFICATION
 *	  pg_fts_match.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "pg_fts.h"
#include "catalog/pg_collation.h"
#include "miscadmin.h"
#include "regex/regex.h"
#include "utils/builtins.h"
#include "utils/memutils.h"
#include "utils/varlena.h"

/* A plain term's presence and its ascending position list. */
typedef struct MatchVal
{
	bool		present;
	uint32	   *pos;
	int			npos;
}			MatchVal;

/*
 * Positions where a (possibly prefix) term occurs.  For an exact term this is
 * the stored position list; for a prefix term we merge the position lists of
 * all matching terms (rare, so a simple concat + sort).  If the doc carries no
 * positions, returns present-without-positions.
 */
static MatchVal
term_positions(FtsDoc doc, const char *term, int termlen, uint16 flags,
			   uint32 distance)
{
	MatchVal	v;
	uint32		wmask = (flags & FTS_QF_WEIGHTED) ? distance : 0;

	v.present = false;
	v.pos = NULL;
	v.npos = 0;

	if (flags & FTS_QF_REGEX)
	{
		v.present = fts_doc_has_regex(doc, term, termlen);
		return v;
	}
	if (flags & FTS_QF_FUZZY)
	{
		v.present = fts_doc_has_fuzzy(doc, term, termlen, (int) distance);
		return v;
	}
	if (flags & FTS_QF_PREFIX)
	{
		/* Unweighted Boolean presence; proximity expansion uses term_spans. */
		v.present = fts_doc_has_prefix(doc, term, termlen);
		return v;
	}
	else
	{
		FtsTermEntry *e = fts_doc_lookup(doc, term, termlen);

		if (e == NULL)
			return v;
		v.present = true;
		if (FTS_DOC_HAS_POS(doc))
		{
			v.pos = FTS_DOC_TERMPOS(doc, e);
			v.npos = (int) e->tf;
		}
		/*
		 * Weight (field-zone) restriction: the term counts as present only if
		 * it occurs at >= 1 position whose label is in wmask.  A doc with no
		 * positions cannot be zone-filtered -- treat every position as label D
		 * (bit 0), i.e. matches iff the mask includes D.  When positions are
		 * present, narrow v.pos to the in-zone positions (kept as label-bearing
		 * words; phrase_step masks the ordinal) so a weighted phrase still
		 * enforces adjacency over only the in-zone occurrences.
		 */
		if (wmask != 0)
		{
			if (!FTS_DOC_HAS_POS(doc))
			{
				/*
				 * Zone labels are carried in each position's high bits
				 * (FTS_POS_LABEL), so a document without positions carries no
				 * label information at all -- it is unknown, not "D".  Treating
				 * unlabeled as D meant `term:D` matched EVERY positionless doc
				 * while `term:A` matched none, and a concatenation that dropped
				 * one side's labels (to_ftsdoc('simple','quick','A') ||
				 * $$'zz':1$$::ftsdoc) silently answered `term:D` = true.  A
				 * zone restriction we cannot evaluate must not match, for the
				 * same reason an unverifiable phrase must not (see
				 * phrase_step).
				 */
				v.present = false;
			}
			else
			{
				int			j,
							n = 0;
				bool		any = false;

				for (j = 0; j < v.npos; j++)
					if ((wmask & (1u << FTS_POS_LABEL(v.pos[j]))) != 0)
						any = true;
				v.present = any;
				/* compact in-zone positions in place (order preserved) */
				if (any)
				{
					uint32	   *keep = (uint32 *) palloc((Size) v.npos * sizeof(uint32));

					for (j = 0; j < v.npos; j++)
						if ((wmask & (1u << FTS_POS_LABEL(v.pos[j]))) != 0)
							keep[n++] = v.pos[j];
					v.pos = keep;
					v.npos = n;
				}
				else
				{
					v.pos = NULL;
					v.npos = 0;
				}
			}
		}
		return v;
	}
}

/*
 * Phrase step over raw ascending position arrays: return, in out[0..*nout),
 * the right positions p such that some left position L satisfies
 * p - L == distance when exact, or 0 < p - L <= distance otherwise.
 * out must have room for nright values.  This is the
 * single source of truth for phrase adjacency; both the in-memory matcher
 * (phrase_step) and the index posting-list phrase evaluator use it, so a
 * phrase answered from the postings is byte-identical to the heap recheck.
 */
void
fts_phrase_step_pos(const uint32 *left, int nleft,
					const uint32 *right, int nright,
					uint32 distance, bool exact, uint32 *out, int *nout)
{
	int			li = 0,
				ri,
				k = 0;

	for (ri = 0; ri < nright; ri++)
	{
		uint32		p = FTS_POS_ORD(right[ri]);	/* ordinal only; ignore label bits */

		/* advance li to the first left position that could be in range */
		while (li < nleft && FTS_POS_ORD(left[li]) < p &&
			p - FTS_POS_ORD(left[li]) > distance)
			li++;
		/* any left position L with p-distance <= L < p works */
		if (li < nleft &&
			(exact ? (FTS_POS_ORD(left[li]) <= p && p - FTS_POS_ORD(left[li]) == distance) :
			 (FTS_POS_ORD(left[li]) < p && p - FTS_POS_ORD(left[li]) <= distance)))
			out[k++] = right[ri];	/* keep the original (label-bearing) word */
	}
	*nout = k;
}

static int
span_cmp(const void *a, const void *b)
{
	const FtsMatchSpan *x = a;
	const FtsMatchSpan *y = b;

	if (x->start != y->start)
		return x->start < y->start ? -1 : 1;
	return x->end < y->end ? -1 : x->end > y->end;
}

/* Keep all distinct boundaries: two matches with the same end can have
 * different distances to a later operand on their left. */
static void
span_sort(FtsMatchValue *v)
{
	int			i,
				n = 0;

	if (v->nspans < 2)
		return;
	qsort(v->spans, v->nspans, sizeof(FtsMatchSpan), span_cmp);
	for (i = 0; i < v->nspans; i++)
		if (n == 0 || span_cmp(&v->spans[n - 1], &v->spans[i]) != 0)
			v->spans[n++] = v->spans[i];
	v->nspans = n;
}

static bool
span_push(FtsMatchValue *v, int *capacity, uint32 start, uint32 end,
		  int maxspans, bool *overflow)
{
	if (maxspans > 0 && v->nspans >= maxspans)
	{
		*overflow = true;
		return false;
	}
	if (v->nspans == *capacity)
	{
		Size		next = *capacity ? (Size) *capacity * 2 : 16;

		if (maxspans > 0)
			next = Min(next, (Size) maxspans);
		if (next > MaxAllocSize / sizeof(FtsMatchSpan))
			ereport(ERROR,
					(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
					 errmsg("too many phrase matches in one document")));
		v->spans = v->spans ? repalloc(v->spans, next * sizeof(FtsMatchSpan)) :
			palloc(next * sizeof(FtsMatchSpan));
		*capacity = (int) next;
	}
	v->spans[v->nspans++] = (FtsMatchSpan) {start, end};
	v->present = true;
	return true;
}

/* First span whose start is >= position; spans are sorted by (start,end). */
static int
span_lower_bound(FtsMatchValue v, uint32 position)
{
	int			lo = 0,
				hi = v.nspans;

	while (lo < hi)
	{
		int			mid = lo + (hi - lo) / 2;

		if (v.spans[mid].start < position)
			lo = mid + 1;
		else
			hi = mid;
	}
	return lo;
}

static FtsMatchValue
span_join(FtsMatchValue left, FtsMatchValue right, uint8 op, uint32 distance,
		  bool needspans, int maxspans, bool *overflow)
{
	FtsMatchValue out = {0};
	int			capacity = 0;
	int			pass,
				i,
				j;

	for (pass = 0; pass < (op == FTS_OP_WITHIN ? 2 : 1); pass++)
	{
		FtsMatchValue a = pass == 0 ? left : right;
		FtsMatchValue b = pass == 0 ? right : left;

		for (i = 0; i < a.nspans; i++)
		{
			uint32		end = a.spans[i].end;

			CHECK_FOR_INTERRUPTS();
			/* Legacy NEAR/p/N measures endpoints, including right-deep
			 * queries. New EXACT/WITHIN uses the nearest span boundaries. */
			j = op == FTS_OP_PHRASE ? 0 : span_lower_bound(b, end);
			for (; j < b.nspans; j++)
			{
				uint32		position = op == FTS_OP_PHRASE ?
					b.spans[j].end : b.spans[j].start;
				uint32		gap;

				if (position < end)
					continue;
				gap = position - end;
				if (gap > distance)
				{
					if (op != FTS_OP_PHRASE)
						break;
					continue;
				}
				if (op == FTS_OP_EXACT ? gap != distance : gap == 0)
					continue;
				out.present = true;
				if (!needspans)
					return out;
				if (!span_push(&out, &capacity,
							   Min(a.spans[i].start, b.spans[j].start),
							   Max(end, b.spans[j].end), maxspans, overflow))
					return out;
			}
		}
	}
	span_sort(&out);
	return out;
}

/*
 * needpos[i]: does item i's value need its spans (it is an operand of a
 * proximity operator, possibly through ORs)?  Everywhere else only presence
 * counts, so a caller may leave those values without spans.
 */
void
fts_match_needpos(FtsQuery query, bool *needpos)
{
	bool	   *work = palloc(Max(query->nitems, 1) * sizeof(bool));
	int			depth = 1;
	uint32		i;

	work[0] = false;
	for (i = query->nitems; i-- > 0;)
	{
		FtsQueryItem *it = &query->items[i];
		bool		need = work[--depth];

		needpos[i] = need;
		if (it->type == FTS_QI_VAL)
			continue;
		if (it->op != FTS_OP_OR)
			need = it->op == FTS_OP_PHRASE || it->op == FTS_OP_WITHIN ||
				it->op == FTS_OP_EXACT;
		work[depth++] = need;
		if (it->op != FTS_OP_NOT)
			work[depth++] = need;
	}
	pfree(work);
}

/* Shared RPN evaluator. Leaf values are indexed by query item. Callers own
 * the memory context; index callers reset it after each candidate document. */
bool
fts_match_eval(FtsQuery query, FtsMatchValue *values, int maxspans, bool *overflow)
{
	FtsMatchValue *stack = palloc(query->nitems * sizeof(FtsMatchValue));
	bool	   *needpos = palloc(Max(query->nitems, 1) * sizeof(bool));
	int			top = 0;
	uint32		i;
	bool		result;

	*overflow = false;
	fts_match_needpos(query, needpos);
	for (i = 0; i < query->nitems && !*overflow; i++)
	{
		FtsQueryItem *it = &query->items[i];
		FtsMatchValue a,
					b,
					out = {0};

		if (it->type == FTS_QI_VAL)
		{
			stack[top++] = values[i];
			continue;
		}
		b = stack[--top];
		if (it->op == FTS_OP_NOT)
			out.present = !b.present;
		else
		{
			a = stack[--top];
			if (it->op == FTS_OP_AND)
				out.present = a.present && b.present;
			else if (it->op == FTS_OP_OR)
			{
				int			capacity = 0,
							j;

				out.present = a.present || b.present;
				if (needpos[i])
				{
					for (j = 0; j < a.nspans && !*overflow; j++)
						span_push(&out, &capacity, a.spans[j].start,
								  a.spans[j].end, maxspans, overflow);
					for (j = 0; j < b.nspans && !*overflow; j++)
						span_push(&out, &capacity, b.spans[j].start,
								  b.spans[j].end, maxspans, overflow);
					span_sort(&out);
				}
			}
			else
				out = span_join(a, b, it->op, it->distance, needpos[i],
								maxspans, overflow);
		}
		stack[top++] = out;
	}
	result = !*overflow && top == 1 && stack[0].present;
	pfree(stack);
	pfree(needpos);
	return result;
}

/* Expand positional leaves against the stored lexemes. Native regex and
 * bounded edit distance are reused; every expansion contributes positions. */
static FtsMatchValue
term_spans(FtsDoc doc, FtsQuery q, FtsQueryItem *it)
{
	FtsMatchValue out = {0};
	const char *term = FTS_QUERY_ITEMTEXT(q, it);
	int			capacity = 0;
	bool		overflow = false;
	uint32		i;
	uint32		mask = it->flags & FTS_QF_WEIGHTED ? it->distance : 0;
	text	   *pattern = it->flags & FTS_QF_REGEX ?
		cstring_to_text_with_len(term, it->termlen) : NULL;

	if (!(it->flags & (FTS_QF_PREFIX | FTS_QF_FUZZY | FTS_QF_REGEX)))
	{
		MatchVal	v = term_positions(doc, term, it->termlen, it->flags,
									 it->distance);

		out.present = v.present;
		if (v.npos > 0)
		{
			out.spans = palloc((Size) v.npos * sizeof(FtsMatchSpan));
			for (i = 0; i < (uint32) v.npos; i++)
				out.spans[i] = (FtsMatchSpan) {FTS_POS_ORD(v.pos[i]),
					FTS_POS_ORD(v.pos[i])};
			out.nspans = v.npos;
		}
		return out;
	}
	for (i = 0; i < doc->nterms; i++)
	{
		FtsTermEntry *e = &doc->entries[i];
		const char *candidate = FTS_DOC_TERMTEXT(doc, e);
		bool		matches;
		uint32		j;

		CHECK_FOR_INTERRUPTS();
		if (it->flags & FTS_QF_PREFIX)
			matches = e->len >= it->termlen &&
				memcmp(candidate, term, it->termlen) == 0;
		else if (it->flags & FTS_QF_FUZZY)
			matches = varstr_levenshtein_less_equal(term, it->termlen,
				candidate, e->len, 1, 1, 1, it->distance, true) <= it->distance;
		else
			matches = RE_compile_and_execute(pattern, (char *) candidate,
				e->len, REG_ADVANCED, C_COLLATION_OID, 0, NULL);
		if (!matches)
			continue;
		if (!FTS_DOC_HAS_POS(doc))
		{
			out.present = mask == 0;
			continue;
		}
		for (j = 0; j < e->tf; j++)
		{
			uint32		p = FTS_DOC_TERMPOS(doc, e)[j];

			if (mask == 0 || (mask & (1u << FTS_POS_LABEL(p))))
				span_push(&out, &capacity, FTS_POS_ORD(p), FTS_POS_ORD(p),
						  0, &overflow);
		}
	}
	if (pattern)
		pfree(pattern);
	span_sort(&out);
	return out;
}

bool
fts_doc_matches(FtsDoc doc, FtsQuery query)
{
	FtsQueryItem *items = query->items;
	MatchVal   *stack;
	int			top = 0;
	uint32		i;
	bool		result;

	/* An empty query matches nothing (there is no positive evidence). */
	if (query->nitems == 0)
		return false;
	for (i = 0; i < query->nitems; i++)
		if ((items[i].type == FTS_QI_OPR &&
			 (items[i].op == FTS_OP_PHRASE || items[i].op == FTS_OP_EXACT ||
			  items[i].op == FTS_OP_WITHIN)) ||
			(items[i].type == FTS_QI_VAL &&
			 (items[i].flags & (FTS_QF_PREFIX | FTS_QF_WEIGHTED)) ==
			 (FTS_QF_PREFIX | FTS_QF_WEIGHTED)))
		{
			FtsMatchValue *values = palloc0(query->nitems * sizeof(FtsMatchValue));
			bool		overflow;
			uint32		j;

			for (j = 0; j < query->nitems; j++)
				if (items[j].type == FTS_QI_VAL)
					values[j] = term_spans(doc, query, &items[j]);
			result = fts_match_eval(query, values, 0, &overflow);
			pfree(values);
			return result;
		}
	stack = (MatchVal *) palloc(query->nitems * sizeof(MatchVal));

	for (i = 0; i < query->nitems; i++)
	{
		FtsQueryItem *it = &items[i];

		if (it->type == FTS_QI_VAL)
		{
			stack[top++] = term_positions(doc, FTS_QUERY_ITEMTEXT(query, it),
										  it->termlen, it->flags,
										  it->distance);
		}
		else if (it->op == FTS_OP_NOT)
		{
			Assert(top >= 1);
			stack[top - 1].present = !stack[top - 1].present;
			stack[top - 1].pos = NULL;
			stack[top - 1].npos = 0;
		}
		else if (it->op == FTS_OP_AND)
		{
			Assert(top >= 2);
			stack[top - 2].present = stack[top - 2].present && stack[top - 1].present;
			stack[top - 2].pos = NULL;
			stack[top - 2].npos = 0;
			top--;
		}
		else					/* FTS_OP_OR */
		{
			Assert(top >= 2);
			stack[top - 2].present = stack[top - 2].present || stack[top - 1].present;
			stack[top - 2].pos = NULL;
			stack[top - 2].npos = 0;
			top--;
		}
	}

	Assert(top == 1);
	result = stack[0].present;
	pfree(stack);
	return result;
}

PG_FUNCTION_INFO_V1(fts_match);

/* ftsdoc @@@ ftsquery -> bool */
Datum
fts_match(PG_FUNCTION_ARGS)
{
	FtsDoc		doc = PG_GETARG_FTSDOC(0);
	FtsQuery	query = PG_GETARG_FTSQUERY(1);
	bool		res;

	res = fts_doc_matches(doc, query);

	PG_FREE_IF_COPY(doc, 0);
	PG_FREE_IF_COPY(query, 1);
	PG_RETURN_BOOL(res);
}

PG_FUNCTION_INFO_V1(fts_match_commutator);

/* ftsquery @@@ ftsdoc -> bool (commutator) */
Datum
fts_match_commutator(PG_FUNCTION_ARGS)
{
	FtsQuery	query = PG_GETARG_FTSQUERY(0);
	FtsDoc		doc = PG_GETARG_FTSDOC(1);
	bool		res;

	res = fts_doc_matches(doc, query);

	PG_FREE_IF_COPY(query, 0);
	PG_FREE_IF_COPY(doc, 1);
	PG_RETURN_BOOL(res);
}
