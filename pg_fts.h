/*-------------------------------------------------------------------------
 *
 * pg_fts.h
 *		Full-text search with BM25 ranking for PostgreSQL.
 *
 * pg_fts provides the analyzed document type (ftsdoc) and the parsed query type
 * (ftsquery) with @@@ match evaluation, plus a dedicated bm25 index access
 * method (segmented inverted index, block-max WAND ranking) that answers @@@
 * and the <=> ordering operator; matching is also available by sequential scan
 * via @@@, exactly as tsvector/tsquery were first introduced.
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 *
 * IDENTIFICATION
 *	  pg_fts.h
 *
 *-------------------------------------------------------------------------
 */
#ifndef PG_FTS_H
#define PG_FTS_H

#include "storage/itemptr.h"

#include "postgres.h"

#include "fmgr.h"
#include "varatt.h"

/*
 * ftsdoc -- an analyzed document.
 *
 * A varlena holding a sorted, de-duplicated array of terms.  Each term entry
 * records its term frequency (tf) and, after the entry array, the term text.
 *
 * Format version 3 optionally stores per-term token positions (needed for
 * phrase and NEAR queries).  When the FTS_DOCF_POSITIONS flag is set, a
 * positions region of uint32 values follows the lexemes; each term entry's
 * posoff/tf delimit that term's positions (tf positions starting at posoff,
 * in units of uint32).  Without the flag, posoff is unused and the document is
 * position-free (smaller; phrase/NEAR then fall back to plain term presence).
 *
 * Layout:
 *	  FtsDocData header
 *	  FtsTermEntry entries[nterms]		(sorted by term text)
 *	  char lexemes[]					(term texts, in entry order)
 *	  uint32 positions[]				(only if FTS_DOCF_POSITIONS)
 */
typedef struct FtsTermEntry
{
	uint32		off;			/* byte offset of term text within lexemes[] */
	uint32		len;			/* length of term text in bytes */
	uint32		tf;				/* term frequency (also # of positions) */
	uint32		posoff;			/* index of first position in positions[] */
} FtsTermEntry;

typedef struct FtsDocData
{
	int32		vl_len_;		/* varlena header (do not touch directly!) */
	uint16		version;		/* format version, currently 3 */
	uint16		flags;			/* FTS_DOCF_* */
	uint32		nterms;			/* number of distinct terms */
	uint32		doclen;			/* total token count (sum of tf); needed by BM25 */
	uint32		lexbytes;		/* total bytes of lexemes[] (to find positions[]) */
	FtsTermEntry entries[FLEXIBLE_ARRAY_MEMBER];
} FtsDocData;

typedef FtsDocData *FtsDoc;

#define FTS_DOC_VERSION			4	/* wire format; v3 carries positions, v4 adds weight labels in position high bits */
#define FTS_DOCF_POSITIONS		0x0001	/* positions[] region is present */
#define FTS_DOCF_WEIGHTS		0x0002	/* some position carries a non-D weight label (v4) */
#define FTS_DOC_HAS_POS(d)		(((d)->flags & FTS_DOCF_POSITIONS) != 0)
#define FTS_DOC_HDRSIZE			offsetof(FtsDocData, entries)
#define FTS_DOC_ENTRIES(d)		((d)->entries)
#define FTS_DOC_LEXEMES(d) \
	((char *) &(d)->entries[(d)->nterms])
#define FTS_DOC_TERMTEXT(d, e)	(FTS_DOC_LEXEMES(d) + (e)->off)

/* base of the positions[] region (valid only when FTS_DOC_HAS_POS).
 * Computed as doc_base + MAXALIGN(offset), matching how the analyzers lay the
 * region out (posbase = MAXALIGN(total)).  Must NOT be MAXALIGN() of the
 * absolute lexemes-end pointer: a detoasted/heap-read ftsdoc can sit at a
 * non-MAXALIGN'd address, and MAXALIGN(base+off) != base+MAXALIGN(off) there,
 * which pointed positions[] at garbage and silently degraded phrase/NEAR on
 * every stored (column-resident) ftsdoc. */
#define FTS_DOC_POSITIONS(d) \
	((uint32 *) ((char *) (d) + \
				 MAXALIGN(FTS_DOC_HDRSIZE + \
						  (Size) (d)->nterms * sizeof(FtsTermEntry) + \
						  (d)->lexbytes)))
#define FTS_DOC_TERMPOS(d, e)	(FTS_DOC_POSITIONS(d) + (e)->posoff)

#define DatumGetFtsDoc(X)		((FtsDoc) PG_DETOAST_DATUM(X))
#define PG_GETARG_FTSDOC(n)		DatumGetFtsDoc(PG_GETARG_DATUM(n))
#define PG_RETURN_FTSDOC(x)		PG_RETURN_POINTER(x)

/*
 * ftsquery -- a parsed boolean query.
 *
 * Stored as a varlena flattened postfix (RPN) list of items.  This mirrors the
 * proven tsquery representation: operands and operators in one array, term
 * text appended after.  Supports AND, OR, NOT, parenthesised grouping, phrase,
 * NEAR, prefix, fuzzy and regex items; field-scope and boosts can be added as
 * new item kinds without breaking v1 data (the version field guards the
 * on-disk format).
 */
typedef enum FtsQueryItemType
{
	FTS_QI_VAL = 1,				/* a term operand */
	FTS_QI_OPR					/* a boolean operator */
} FtsQueryItemType;

typedef enum FtsQueryOp
{
	FTS_OP_NOT = 1,
	FTS_OP_AND,
	FTS_OP_OR,
	FTS_OP_PHRASE,				/* ordered operands within `distance` */
	FTS_OP_WITHIN,				/* operands in either order within `distance` */
	FTS_OP_EXACT				/* exact gap from left end to right start */
} FtsQueryOp;

typedef struct FtsQueryItem
{
	uint8		type;			/* FtsQueryItemType */
	uint8		op;				/* FtsQueryOp, valid when type == FTS_QI_OPR */
	uint16		flags;			/* FTS_QF_* flags, valid for FTS_QI_VAL */
	uint32		distance;		/* max token gap for PHRASE/WITHIN (1 = adjacent);
								 * on a FTS_QI_VAL with FTS_QF_WEIGHTED, instead holds
								 * the weight-label mask (bit L set => match label L,
								 * L in 0..3 for D,C,B,A) -- a VAL never uses the gap */
	/* for FTS_QI_VAL: */
	uint32		termoff;		/* offset of term text within the text region */
	uint32		termlen;		/* length of term text */
} FtsQueryItem;

#define FTS_QF_PREFIX	0x0001	/* term is a prefix match (term*) */
#define FTS_QF_FUZZY	0x0002	/* term is a fuzzy match (term~k); k in distance */
#define FTS_QF_REGEX	0x0004	/* term text is a regular expression (/re/) */
#define FTS_QF_WEIGHTED	0x0008	/* term is weight-restricted (term:ABCD);
								 * the label mask is in `distance` (see above) */

/*
 * Weight labels (field zones), tsvector-compatible ordering D < C < B < A.
 * A label is stored in the TOP TWO BITS of each uint32 token position; the
 * low 30 bits are the 1-based token ordinal.  Label 0 = D (default/unlabeled),
 * so a v3 (label-free) position reads as D and behaves as "unlabeled".
 */
#define FTS_POS_LABEL_BITS	2
#define FTS_POS_LABEL_SHIFT	30
#define FTS_POS_ORD_MASK	0x3FFFFFFFu		/* low 30 bits: token ordinal */
#define FTS_POS_LABEL(p)	((uint8) ((p) >> FTS_POS_LABEL_SHIFT))	/* 0..3 */
#define FTS_POS_ORD(p)		((p) & FTS_POS_ORD_MASK)
#define FTS_POS_MAKE(ord, lbl)	(((uint32)(lbl) << FTS_POS_LABEL_SHIFT) | ((ord) & FTS_POS_ORD_MASK))
/* Map a weight char A/B/C/D (any case) to its 0..3 label; D/unknown -> 0. */
#define FTS_WEIGHT_LABEL(c) \
	(((c)=='A'||(c)=='a') ? 3 : ((c)=='B'||(c)=='b') ? 2 : ((c)=='C'||(c)=='c') ? 1 : 0)

typedef struct FtsQueryData
{
	int32		vl_len_;		/* varlena header (do not touch directly!) */
	uint16		version;		/* format version, currently 1 */
	uint16		flags;			/* reserved */
	uint32		nitems;			/* number of items in RPN list */
	FtsQueryItem items[FLEXIBLE_ARRAY_MEMBER];
	/* term texts follow items[] */
} FtsQueryData;

typedef FtsQueryData *FtsQuery;

#define FTS_QUERY_VERSION		2	/* v2: FTS_QI_VAL may carry a weight mask */
#define FTS_QUERY_HDRSIZE		offsetof(FtsQueryData, items)
#define FTS_QUERY_TEXTBASE(q)	((char *) &(q)->items[(q)->nitems])
#define FTS_QUERY_ITEMTEXT(q, it) (FTS_QUERY_TEXTBASE(q) + (it)->termoff)

#define DatumGetFtsQuery(X)		((FtsQuery) PG_DETOAST_DATUM(X))
#define PG_GETARG_FTSQUERY(n)	DatumGetFtsQuery(PG_GETARG_DATUM(n))
#define PG_RETURN_FTSQUERY(x)	PG_RETURN_POINTER(x)

/* pg_fts_analyze.c -- the built-in stage-1 tokenizer */
extern FtsDoc fts_analyze_text(const char *str, int len);
extern char *fold_token(const char *src, int len, int *outlen);

/* pg_fts_tsanalyze.c -- analyzer reusing an installed TS configuration */
extern FtsDoc fts_analyze_with_config(Oid cfgId, const char *str, int len, uint8 label);
#ifdef PG_FTS_TEST_HOOKS
/* TEST-ONLY (see pg_fts_customscan.c _PG_init): advisory key a scan waits on
 * mid-collect to expose the scan-vs-merge recycle window; 0 = off. */
extern int pg_fts_test_pause_advisory_key;
#endif
extern FtsDoc fts_doc_build(uint32 nterms, char **terms, const int *lens,
							const uint32 *tfs, bool has_pos,
							const uint32 *positions, const char *errctx);
extern char *fts_normalize_term(Oid cfgId, const char *term, int len, int *outlen);

/* pg_fts_query.c -- parse query text into an ftsquery */
extern FtsQuery fts_parse_query(const char *str, int len);
extern FtsQuery fts_parse_query_cfg(const char *str, int len, Oid cfgId);

/* pg_fts_match.c -- evaluate a parsed query against an analyzed doc */
extern bool fts_doc_matches(FtsDoc doc, FtsQuery query);
/* Match spans shared by document rechecks and positional index scans.
 * Endpoints are token ordinals, with any field restriction already applied. */
typedef struct FtsMatchSpan
{
	uint32		start;
	uint32		end;
} FtsMatchSpan;

typedef struct FtsMatchValue
{
	bool		present;
	FtsMatchSpan *spans;
	int			nspans;
} FtsMatchValue;

extern bool fts_match_eval(FtsQuery query, FtsMatchValue *values,
						   int maxspans, bool *overflow);
/* shared phrase adjacency over raw ascending position arrays (single source of
 * truth for the in-memory matcher and the index posting-list phrase eval) */
extern void fts_phrase_step_pos(const uint32 *left, int nleft,
								const uint32 *right, int nright,
								uint32 distance, bool exact, uint32 *out, int *nout);
/* shared: binary-search a term in a doc; returns entry or NULL */
extern FtsTermEntry *fts_doc_lookup(FtsDoc doc, const char *term, int termlen);

/* shared: structural self-consistency check for an FtsDoc read from an
 * untrusted source (pending page, detoasted column) before its offsets are
 * trusted; sz is the bytes available at doc.  See pg_fts_doc.c. */
extern bool fts_doc_is_valid(const FtsDocData *doc, Size sz);

/* shared: does any term in the doc start with the given prefix? */
extern bool fts_doc_has_prefix(FtsDoc doc, const char *prefix, int prefixlen);

/* shared: does any doc term match within edit distance k? (stage 13) */
extern bool fts_doc_has_fuzzy(FtsDoc doc, const char *term, int termlen, int k);

/* shared: does any doc term match the regular expression? (stage 14) */
extern bool fts_doc_has_regex(FtsDoc doc, const char *re, int relen);

/* pg_fts_rank.c -- collect distinct query term operands (shared) */
extern int	fts_query_terms(FtsQuery q, const char ***terms_out, int **lens_out);
extern double fts_bm25_score_index(FtsDoc doc, FtsQuery q, double N,
								   double avgdl, const double *dfs);

/* pg_fts_trgm.c -- trigram pre-filter for fuzzy/regex at scale */
#define FTS_MAX_TRIGRAMS 64
extern int	fts_trigrams(const char *s, int len, uint32 *out, int maxout);
extern int	fts_regex_trigrams(const char *re, int relen, uint32 *out, int maxout);
extern bool fts_trigrams_overlap(const uint32 *a, int na,
								 const uint32 *b, int nb);

/* pg_fts_am_scan.c -- count entry point reused by the COUNT-pushdown CustomScan */
extern int64 bm25_count_visible_oid(Oid indexoid, FtsQuery q);
extern int pg_fts_build_collapse_max_mb;
extern int pg_fts_build_mem_ceiling_mb;

#endif							/* PG_FTS_H */
