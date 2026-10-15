/*-------------------------------------------------------------------------
 *
 * ts_parse.c
 *		main parse functions for tsearch
 *
 * Portions Copyright (c) 1996-2025, PostgreSQL Global Development Group
 *
 *
 * IDENTIFICATION
 *	  src/backend/tsearch/ts_parse.c
 *
 *-------------------------------------------------------------------------
 */

#include "postgres.h"

#include "tsearch/ts_cache.h"
#include "tsearch/ts_utils.h"
#include "varatt.h"
#include "../pg_fts.h"

/* PostgreSQL ParsedWord.pos is uint16; use a private wide representation.
 * This file vendors only the lexizing and parsing portion of PostgreSQL 18
 * ts_parse.c (REL_18_STABLE, retrieved 2026-10-11). The parser/dictionaries
 * remain PostgreSQL's; the changes are the private types, function name,
 * and checked 30-bit positions instead of LIMITPOS's 14-bit clamp.
 * Upstream source: https://github.com/postgres/postgres/blob/REL_18_STABLE/src/backend/tsearch/ts_parse.c
 */
typedef struct
{
    uint16 flags;
    uint16 len;
    uint16 nvariant;
    uint16 alen;
    union { uint32 pos; } pos;
    char *word;
} FtsParsedWord;

typedef struct
{
    int lenwords;
    int curwords;
    int pos;
    FtsParsedWord *words;
} FtsParsedText;

static void
fts_advance_position(FtsParsedText *prs)
{
    if ((uint32) prs->pos >= FTS_POS_ORD_MASK)
        ereport(ERROR,
                (errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
                 errmsg("ftsdoc has too many token positions")));
    prs->pos++;
}

#define IGNORE_LONGLEXEME	1

/*
 * Lexize subsystem
 */

typedef struct ParsedLex
{
	int			type;
	char	   *lemm;
	int			lenlemm;
	struct ParsedLex *next;
} ParsedLex;

typedef struct ListParsedLex
{
	ParsedLex  *head;
	ParsedLex  *tail;
} ListParsedLex;

typedef struct
{
	TSConfigCacheEntry *cfg;
	Oid			curDictId;
	int			posDict;
	DictSubState dictState;
	ParsedLex  *curSub;
	ListParsedLex towork;		/* current list to work */
	ListParsedLex waste;		/* list of lexemes that already lexized */

	/*
	 * fields to store last variant to lexize (basically, thesaurus or similar
	 * to, which wants several lexemes
	 */

	ParsedLex  *lastRes;
	TSLexeme   *tmpRes;
} LexizeData;

static void
LexizeInit(LexizeData *ld, TSConfigCacheEntry *cfg)
{
	ld->cfg = cfg;
	ld->curDictId = InvalidOid;
	ld->posDict = 0;
	ld->towork.head = ld->towork.tail = ld->curSub = NULL;
	ld->waste.head = ld->waste.tail = NULL;
	ld->lastRes = NULL;
	ld->tmpRes = NULL;
}

static void
LPLAddTail(ListParsedLex *list, ParsedLex *newpl)
{
	if (list->tail)
	{
		list->tail->next = newpl;
		list->tail = newpl;
	}
	else
		list->head = list->tail = newpl;
	newpl->next = NULL;
}

static ParsedLex *
LPLRemoveHead(ListParsedLex *list)
{
	ParsedLex  *res = list->head;

	if (list->head)
		list->head = list->head->next;

	if (list->head == NULL)
		list->tail = NULL;

	return res;
}

static void
LexizeAddLemm(LexizeData *ld, int type, char *lemm, int lenlemm)
{
	ParsedLex  *newpl = (ParsedLex *) palloc(sizeof(ParsedLex));

	newpl->type = type;
	newpl->lemm = lemm;
	newpl->lenlemm = lenlemm;
	LPLAddTail(&ld->towork, newpl);
	ld->curSub = ld->towork.tail;
}

static void
RemoveHead(LexizeData *ld)
{
	LPLAddTail(&ld->waste, LPLRemoveHead(&ld->towork));

	ld->posDict = 0;
}

static void
setCorrLex(LexizeData *ld, ParsedLex **correspondLexem)
{
	if (correspondLexem)
	{
		*correspondLexem = ld->waste.head;
	}
	else
	{
		ParsedLex  *tmp,
				   *ptr = ld->waste.head;

		while (ptr)
		{
			tmp = ptr->next;
			pfree(ptr);
			ptr = tmp;
		}
	}
	ld->waste.head = ld->waste.tail = NULL;
}

static void
moveToWaste(LexizeData *ld, ParsedLex *stop)
{
	bool		go = true;

	while (ld->towork.head && go)
	{
		if (ld->towork.head == stop)
		{
			ld->curSub = stop->next;
			go = false;
		}
		RemoveHead(ld);
	}
}

static void
setNewTmpRes(LexizeData *ld, ParsedLex *lex, TSLexeme *res)
{
	if (ld->tmpRes)
	{
		TSLexeme   *ptr;

		for (ptr = ld->tmpRes; ptr->lexeme; ptr++)
			pfree(ptr->lexeme);
		pfree(ld->tmpRes);
	}
	ld->tmpRes = res;
	ld->lastRes = lex;
}

static TSLexeme *
LexizeExec(LexizeData *ld, ParsedLex **correspondLexem)
{
	int			i;
	ListDictionary *map;
	TSDictionaryCacheEntry *dict;
	TSLexeme   *res;

	if (ld->curDictId == InvalidOid)
	{
		/*
		 * usual mode: dictionary wants only one word, but we should keep in
		 * mind that we should go through all stack
		 */

		while (ld->towork.head)
		{
			ParsedLex  *curVal = ld->towork.head;
			char	   *curValLemm = curVal->lemm;
			int			curValLenLemm = curVal->lenlemm;

			map = ld->cfg->map + curVal->type;

			if (curVal->type == 0 || curVal->type >= ld->cfg->lenmap || map->len == 0)
			{
				/* skip this type of lexeme */
				RemoveHead(ld);
				continue;
			}

			for (i = ld->posDict; i < map->len; i++)
			{
				dict = lookup_ts_dictionary_cache(map->dictIds[i]);

				ld->dictState.isend = ld->dictState.getnext = false;
				ld->dictState.private_state = NULL;
				res = (TSLexeme *) DatumGetPointer(FunctionCall4(&(dict->lexize),
																 PointerGetDatum(dict->dictData),
																 PointerGetDatum(curValLemm),
																 Int32GetDatum(curValLenLemm),
																 PointerGetDatum(&ld->dictState)));

				if (ld->dictState.getnext)
				{
					/*
					 * dictionary wants next word, so setup and store current
					 * position and go to multiword mode
					 */

					ld->curDictId = DatumGetObjectId(map->dictIds[i]);
					ld->posDict = i + 1;
					ld->curSub = curVal->next;
					if (res)
						setNewTmpRes(ld, curVal, res);
					return LexizeExec(ld, correspondLexem);
				}

				if (!res)		/* dictionary doesn't know this lexeme */
					continue;

				if (res->flags & TSL_FILTER)
				{
					curValLemm = res->lexeme;
					curValLenLemm = strlen(res->lexeme);
					continue;
				}

				RemoveHead(ld);
				setCorrLex(ld, correspondLexem);
				return res;
			}

			RemoveHead(ld);
		}
	}
	else
	{							/* curDictId is valid */
		dict = lookup_ts_dictionary_cache(ld->curDictId);

		/*
		 * Dictionary ld->curDictId asks us about following words
		 */

		while (ld->curSub)
		{
			ParsedLex  *curVal = ld->curSub;

			map = ld->cfg->map + curVal->type;

			if (curVal->type != 0)
			{
				bool		dictExists = false;

				if (curVal->type >= ld->cfg->lenmap || map->len == 0)
				{
					/* skip this type of lexeme */
					ld->curSub = curVal->next;
					continue;
				}

				/*
				 * We should be sure that current type of lexeme is recognized
				 * by our dictionary: we just check is it exist in list of
				 * dictionaries ?
				 */
				for (i = 0; i < map->len && !dictExists; i++)
					if (ld->curDictId == DatumGetObjectId(map->dictIds[i]))
						dictExists = true;

				if (!dictExists)
				{
					/*
					 * Dictionary can't work with current type of lexeme,
					 * return to basic mode and redo all stored lexemes
					 */
					ld->curDictId = InvalidOid;
					return LexizeExec(ld, correspondLexem);
				}
			}

			ld->dictState.isend = (curVal->type == 0);
			ld->dictState.getnext = false;

			res = (TSLexeme *) DatumGetPointer(FunctionCall4(&(dict->lexize),
															 PointerGetDatum(dict->dictData),
															 PointerGetDatum(curVal->lemm),
															 Int32GetDatum(curVal->lenlemm),
															 PointerGetDatum(&ld->dictState)));

			if (ld->dictState.getnext)
			{
				/* Dictionary wants one more */
				ld->curSub = curVal->next;
				if (res)
					setNewTmpRes(ld, curVal, res);
				continue;
			}

			if (res || ld->tmpRes)
			{
				/*
				 * Dictionary normalizes lexemes, so we remove from stack all
				 * used lexemes, return to basic mode and redo end of stack
				 * (if it exists)
				 */
				if (res)
				{
					moveToWaste(ld, ld->curSub);
				}
				else
				{
					res = ld->tmpRes;
					moveToWaste(ld, ld->lastRes);
				}

				/* reset to initial state */
				ld->curDictId = InvalidOid;
				ld->posDict = 0;
				ld->lastRes = NULL;
				ld->tmpRes = NULL;
				setCorrLex(ld, correspondLexem);
				return res;
			}

			/*
			 * Dict don't want next lexem and didn't recognize anything, redo
			 * from ld->towork.head
			 */
			ld->curDictId = InvalidOid;
			return LexizeExec(ld, correspondLexem);
		}
	}

	setCorrLex(ld, correspondLexem);
	return NULL;
}

/*
 * Parse string and lexize words.
 *
 * prs will be filled in.
 */
static void
fts_parsetext(Oid cfgId, FtsParsedText *prs, char *buf, int buflen)
{
	int			type,
				lenlemm = 0;	/* silence compiler warning */
	char	   *lemm = NULL;
	LexizeData	ldata;
	TSLexeme   *norms;
	TSConfigCacheEntry *cfg;
	TSParserCacheEntry *prsobj;
	void	   *prsdata;

	cfg = lookup_ts_config_cache(cfgId);
	prsobj = lookup_ts_parser_cache(cfg->prsId);

	prsdata = DatumGetPointer(FunctionCall2(&prsobj->prsstart,
											PointerGetDatum(buf),
											Int32GetDatum(buflen)));

	LexizeInit(&ldata, cfg);

	do
	{
		type = DatumGetInt32(FunctionCall3(&(prsobj->prstoken),
										   PointerGetDatum(prsdata),
										   PointerGetDatum(&lemm),
										   PointerGetDatum(&lenlemm)));

		if (type > 0 && lenlemm > MAXSTRLEN)
		{
#ifdef IGNORE_LONGLEXEME
			ereport(NOTICE,
					(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
					 errmsg("word is too long to be indexed"),
					 errdetail("Words longer than %d characters are ignored.",
							   MAXSTRLEN)));
			continue;
#else
			ereport(ERROR,
					(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
					 errmsg("word is too long to be indexed"),
					 errdetail("Words longer than %d characters are ignored.",
							   MAXSTRLEN)));
#endif
		}

		LexizeAddLemm(&ldata, type, lemm, lenlemm);

		while ((norms = LexizeExec(&ldata, NULL)) != NULL)
		{
			fts_advance_position(prs);			/* set pos */

			for (TSLexeme *ptr = norms; ptr->lexeme; ptr++)
			{
				size_t		lexeme_len = strlen(ptr->lexeme);

				if (lexeme_len > MAXSTRLEN)
				{
#ifdef IGNORE_LONGLEXEME
					ereport(NOTICE,
							(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
							 errmsg("word is too long to be indexed"),
							 errdetail("Words longer than %d characters are ignored.",
									   MAXSTRLEN)));
					continue;
#else
					ereport(ERROR,
							(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
							 errmsg("word is too long to be indexed"),
							 errdetail("Words longer than %d characters are ignored.",
									   MAXSTRLEN)));
#endif
				}

				if (prs->curwords == prs->lenwords)
				{
					prs->lenwords *= 2;
					prs->words = (FtsParsedWord *) repalloc(prs->words, prs->lenwords * sizeof(FtsParsedWord));
				}

				if (ptr->flags & TSL_ADDPOS)
					fts_advance_position(prs);
				prs->words[prs->curwords].len = lexeme_len;
				prs->words[prs->curwords].word = ptr->lexeme;
				prs->words[prs->curwords].nvariant = ptr->nvariant;
				prs->words[prs->curwords].flags = ptr->flags & TSL_PREFIX;
				prs->words[prs->curwords].alen = 0;
				prs->words[prs->curwords].pos.pos = (uint32) prs->pos;
				prs->curwords++;
			}
			pfree(norms);
		}
	} while (type > 0);

	FunctionCall1(&(prsobj->prsend), PointerGetDatum(prsdata));
}

