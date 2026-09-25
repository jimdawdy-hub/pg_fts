/*-------------------------------------------------------------------------
 *
 * pg_fts_query.c
 *		Query-text parser and I/O for the ftsquery type.
 *
 * Stage-1 query grammar (recursive descent, no generator -- the grammar is
 * small and this keeps the extension self-contained):
 *
 *	  expr    := or_expr
 *	  or_expr := and_expr ( ('|' | 'OR') and_expr )*
 *	  and_expr:= proximity ( ('&' | 'AND')? proximity )* -- implicit AND
 *	  proximity := unary ( (('w/' | 'p/') distance | '<->' | '<N>') unary )*
 *	  unary   := ('!' | 'NOT' | '-') unary | primary
 *
 *	  '-' is negation only in PREFIX position; between two word characters it is part
 *	  of the term ('pkg-config'), as are '.' and '/'.  See is_term_infix_byte.
 *	  primary := '(' expr ')' | term
 *	  term    := run of token bytes (folded like the analyzer)
 *
 * The parser emits a postfix (RPN) item list, the same shape tsquery uses, so
 * evaluation is a simple stack machine.  Supported: AND, OR, NOT, parenthesised
 * grouping, phrase ("..."), NEAR, prefix (term*), fuzzy (term~k) and regex
 * (/re/); field scoping (field:term) and boosts remain future item kinds, which
 * the version field lets us add without breaking the on-disk format.
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 *
 * IDENTIFICATION
 *	  pg_fts_query.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include <limits.h>

#include "pg_fts.h"
#include "lib/stringinfo.h"
#include "libpq/pqformat.h"
#include "miscadmin.h"
#include "utils/builtins.h"

/* An operand collected during the parse, before flattening to a varlena. */
typedef struct ParsedItem
{
	uint8		type;			/* FtsQueryItemType */
	uint8		op;				/* FtsQueryOp when type == FTS_QI_OPR */
	uint16		flags;			/* FTS_QF_* for VAL items */
	uint32		distance;		/* FTS_OP_PHRASE gap */
	char	   *term;			/* palloc'd folded term when type == FTS_QI_VAL */
	int			termlen;
} ParsedItem;

/* Token kinds returned by the lexer. */
typedef enum
{
	TOK_EOF,
	TOK_TERM,
	TOK_AND,
	TOK_OR,
	TOK_NOT,
	TOK_LPAREN,
	TOK_RPAREN,
	TOK_QUOTE,					/* " -- starts/ends a phrase */
	TOK_NEAR,					/* NEAR keyword (proximity) */
	TOK_PROX,					/* w/N, p/N, <-> or <N> */
	TOK_COMMA					/* , inside NEAR(...) */
} TokKind;

typedef struct Token
{
	TokKind		kind;
	char	   *term;			/* folded term text for TOK_TERM */
	int			termlen;
	bool		prefix;			/* TOK_TERM followed by '*' */
	int			fuzzy_k;		/* TOK_TERM followed by ~k (0 = not fuzzy) */
	bool		regex;			/* TOK_TERM holds a regex (from /.../ ) */
	uint32		weightmask;		/* TOK_TERM followed by :ABCD -> label mask (0 = none) */
	uint32		distance;		/* TOK_PROX distance */
	uint8		op;				/* TOK_PROX operator */
} Token;

#define FTS_MAX_PROX_DISTANCE UINT32_MAX

typedef struct ParseState
{
	const char *buf;
	int			len;
	int			pos;
	ParsedItem *items;
	int			nitems;
	int			maxitems;
	bool		error;
	bool		have_peeked;	/* is peeked valid? */
	Token		peeked;			/* one-token lookahead cache */
} ParseState;

static void parse_or(ParseState *st);
static void emit_dist(ParseState *st, uint8 type, uint8 op, char *term,
					  int termlen, uint16 flags, uint32 distance);

/* Accept a bounded decimal distance without overflowing an intermediate. */
static bool
parse_distance(const char *s, int len, uint32 *distance)
{
	uint32		n = 0;
	int			i;

	if (len == 0)
		return false;
	for (i = 0; i < len; i++)
	{
		if (s[i] < '0' || s[i] > '9' ||
			n > (FTS_MAX_PROX_DISTANCE - (s[i] - '0')) / 10)
			return false;
		n = n * 10 + (s[i] - '0');
	}
	*distance = n;
	return true;
}

/*
 * May this byte appear INSIDE a term, i.e. between two word characters?
 *
 * The set is not a guess: it is what the DOCUMENT analyzer joins, verified against
 * to_ftsdoc('simple', 'a-b c/d e.f g_h i+j'), which yields
 *   'a-b' 'a' 'b' 'c/d' 'e.f' 'g' 'h' 'i' 'j'
 * -- so '-', '/' and '.' are kept inside a token (PostgreSQL classifies them
 * asciihword / file / file) while '_' and '+' SPLIT.  The query lexer has to agree
 * with that or a token the user typed can never match the token we stored.
 *
 * A trailing separator is deliberately not included by this rule, because it is not
 * between two word characters: `c++` and `notepad++` lex to 'c' / 'notepad', which is
 * what both PostgreSQL and our own document analyzer do.
 */
static inline bool
is_term_infix_byte(unsigned char c)
{
	return c == '-' || c == '.' || c == '/';
}

static inline bool
is_token_byte(unsigned char c)
{
	if (c >= 0x80)
		return true;
	return (c >= 'a' && c <= 'z') ||
		(c >= 'A' && c <= 'Z') ||
		(c >= '0' && c <= '9');
}

static void
emit(ParseState *st, uint8 type, uint8 op, char *term, int termlen,
	 uint16 flags)
{
	emit_dist(st, type, op, term, termlen, flags, 0);
}

static void
emit_dist(ParseState *st, uint8 type, uint8 op, char *term, int termlen,
		  uint16 flags, uint32 distance)
{
	if (st->nitems >= st->maxitems)
	{
		st->maxitems = st->maxitems ? st->maxitems * 2 : 16;
		if (st->items == NULL)
			st->items = (ParsedItem *) palloc(st->maxitems * sizeof(ParsedItem));
		else
			st->items = (ParsedItem *) repalloc(st->items,
												st->maxitems * sizeof(ParsedItem));
	}
	st->items[st->nitems].type = type;
	st->items[st->nitems].op = op;
	st->items[st->nitems].flags = flags;
	st->items[st->nitems].distance = distance;
	st->items[st->nitems].term = term;
	st->items[st->nitems].termlen = termlen;
	st->nitems++;
}

/* Suffixes are valid on both bare terms and quoted output terms. */
static void
lex_term_suffix(ParseState *st, Token *tok)
{
	while (st->pos < st->len)
	{
		char		c = st->buf[st->pos];

		if (c == '*' || c == '~')
		{
			if (tok->prefix || tok->fuzzy_k > 0)
			{
				st->error = true;
				return;
			}
			st->pos++;
			if (c == '*')
				tok->prefix = true;
			else
			{
				int			k = 0;
				bool		havedigit = false;

				while (st->pos < st->len &&
					   st->buf[st->pos] >= '0' && st->buf[st->pos] <= '9')
				{
					if (k > (INT_MAX - (st->buf[st->pos] - '0')) / 10)
					{
						st->error = true;
						return;
					}
					k = k * 10 + (st->buf[st->pos] - '0');
					havedigit = true;
					st->pos++;
				}
				tok->fuzzy_k = havedigit ? Max(k, 1) : 2;
			}
		}
		else if (c == ':')
		{
			int			p = st->pos + 1;
			uint32		mask = 0;
			bool		prefix = false;

			/* Also accept PostgreSQL's :*AB spelling. */
			if (p < st->len && st->buf[p] == '*')
			{
				prefix = true;
				p++;
			}
			while (p < st->len)
			{
				c = st->buf[p];
				if (c == 'A' || c == 'a')
					mask |= 1u << 3;
				else if (c == 'B' || c == 'b')
					mask |= 1u << 2;
				else if (c == 'C' || c == 'c')
					mask |= 1u << 1;
				else if (c == 'D' || c == 'd')
					mask |= 1u << 0;
				else
					break;
				p++;
			}
			if (mask == 0 && !prefix)
				return;
			if (tok->weightmask != 0 ||
				(prefix && (tok->prefix || tok->fuzzy_k > 0)))
			{
				st->error = true;
				return;
			}
			tok->weightmask = mask;
			tok->prefix |= prefix;
			st->pos = p;
		}
		else
			return;
	}
}

/*
 * Raw lexer.  Recognizes &, |, !, - and parentheses as punctuation; the
 * keywords AND/OR/NOT (case-insensitive) as operators; everything else is a
 * term.  A bare "and"/"or"/"not" is treated as an operator only when it stands
 * alone as a token, which is the standard, least-surprising behavior.
 *
 * Callers use next_token()/peek() rather than calling this directly, so that a
 * peeked token is lexed (and its term palloc'd) exactly once.
 */
static Token
lex_raw(ParseState *st)
{
	Token		tok = {TOK_EOF, NULL, 0, false, 0, false};
	int			start;
	int			flen;
	char	   *folded;

	/*
	 * A '-' or '/' that sits between two word characters belongs to the TERM, not to
	 * the operator/punctuation set, so hand it straight to the term scanner below.
	 *
	 * This mattered more than a mis-split: `to_ftsquery('pkg-config')` used to parse
	 * as ('pkg' & !'config'), and that NOT clause actively EXCLUDED the pkg-config
	 * documents being searched for -- `install-info` matched 1 row instead of 10.
	 * A silently different answer is a worse failure mode than a visible parse error.
	 * `foo/bar` was worse still: '/' opened a regex, so everything after it was
	 * swallowed and the query became just 'foo'.
	 *
	 * `a -b` still excludes b, and a standalone /regex/ still works: only a separator
	 * flanked by word characters is treated as literal.
	 */
	while (st->pos < st->len &&
		   !is_token_byte((unsigned char) st->buf[st->pos]))
	{
		char		c = st->buf[st->pos];

		if (is_term_infix_byte((unsigned char) c) && st->pos > 0 &&
			is_token_byte((unsigned char) st->buf[st->pos - 1]) &&
			st->pos + 1 < st->len &&
			is_token_byte((unsigned char) st->buf[st->pos + 1]))
			break;				/* intra-word separator: part of the term */

		switch (c)
		{
			case '&':
				st->pos++;
				tok.kind = TOK_AND;
				return tok;
			case '|':
				st->pos++;
				tok.kind = TOK_OR;
				return tok;
			case '!':
			case '-':
				st->pos++;
				tok.kind = TOK_NOT;
				return tok;
			case '(':
				st->pos++;
				tok.kind = TOK_LPAREN;
				return tok;
			case ')':
				st->pos++;
				tok.kind = TOK_RPAREN;
				return tok;
			case ',':
				st->pos++;
				tok.kind = TOK_COMMA;
				return tok;
			case '"':
				st->pos++;
				tok.kind = TOK_QUOTE;
				return tok;
			case '<':
				{
					int			dstart = ++st->pos;

					tok.kind = TOK_PROX;
					tok.op = FTS_OP_EXACT;
					if (st->pos + 1 < st->len && st->buf[st->pos] == '-' &&
						st->buf[st->pos + 1] == '>')
					{
						st->pos += 2;
						tok.distance = 1;
						return tok;
					}
					while (st->pos < st->len &&
						   st->buf[st->pos] >= '0' && st->buf[st->pos] <= '9')
						st->pos++;
					if (st->pos >= st->len || st->buf[st->pos] != '>' ||
						!parse_distance(st->buf + dstart, st->pos - dstart,
										&tok.distance))
						st->error = true;
					else
						st->pos++;
					return tok;
				}
			case '\'':
				{
					int			qstart = st->pos;
					char	   *literal;
					int			n = 0;
					bool		closed = false;

					/* An apostrophe inside a word remains a separator, as it
					 * was before display literals became input syntax. */
					if (qstart > 0 && is_token_byte((unsigned char) st->buf[qstart - 1]))
					{
						st->pos++;
						break;
					}
					literal = (char *) palloc(st->len - st->pos);
					st->pos++;
					while (st->pos < st->len)
					{
						char		ch = st->buf[st->pos++];

						if (ch == '\'')
						{
							closed = true;
							break;
						}
						if (ch == '\\' && st->pos < st->len)
							ch = st->buf[st->pos++];
						literal[n++] = ch;
					}
					if (!closed)
					{
						pfree(literal);
						st->pos = qstart + 1;
						break;
					}
					if (n == 0)
					{
						st->error = true;
						return tok;
					}
					tok.kind = TOK_TERM;
					tok.term = fold_token(literal, n, &tok.termlen);
					lex_term_suffix(st, &tok);
					return tok;
				}
			case '/':
				{
					/* /regex/ : read until the closing slash (not folded) */
					int			rstart;
					int			rlen;
					char	   *rbuf;

					st->pos++;
					rstart = st->pos;
					while (st->pos < st->len && st->buf[st->pos] != '/')
						st->pos++;
					rlen = st->pos - rstart;
					if (st->pos < st->len)
						st->pos++;	/* consume closing slash */
					else
					{
						st->error = true;
						tok.kind = TOK_EOF;	/* unterminated regex */
						return tok;
					}
					rbuf = (char *) palloc(rlen);
					memcpy(rbuf, st->buf + rstart, rlen);
					tok.kind = TOK_TERM;
					tok.term = rbuf;
					tok.termlen = rlen;
					tok.regex = true;
					lex_term_suffix(st, &tok);
					return tok;
				}
			default:
				st->pos++;		/* ordinary separator */
				break;
		}
	}
	if (st->pos >= st->len)
		return tok;				/* TOK_EOF */

	/*
	 * A term: a run of token bytes, which may contain '-', '.' or '/' provided each
	 * one is flanked by token bytes (see is_term_infix_byte).  That keeps
	 * 'pkg-config', 'foo/bar' and 'python3.14' whole, exactly as the document
	 * analyzer stores them, while a trailing or leading separator still terminates
	 * the term.
	 */
	start = st->pos;
	while (st->pos < st->len)
	{
		unsigned char ch = (unsigned char) st->buf[st->pos];

		if (is_token_byte(ch))
		{
			st->pos++;
			continue;
		}
		if (is_term_infix_byte(ch) && st->pos + 1 < st->len &&
			is_token_byte((unsigned char) st->buf[st->pos + 1]))
		{
			st->pos++;			/* separator between word characters */
			continue;
		}
		break;
	}
	flen = st->pos - start;

	/* fold identically to the document analyzer; folded length may differ from
	 * the raw run under Unicode lowercasing, so keyword checks use flen after. */
	folded = fold_token(st->buf + start, flen, &flen);
	if (flen >= 3 && (folded[0] == 'w' || folded[0] == 'p') &&
		folded[1] == '/' && folded[2] >= '0' && folded[2] <= '9')
	{
		int			k;

		for (k = 3; k < flen && folded[k] >= '0' && folded[k] <= '9'; k++)
			;
		if (k == flen)
		{
			tok.kind = TOK_PROX;
			tok.op = (folded[0] == 'w') ? FTS_OP_WITHIN : FTS_OP_PHRASE;
			tok.term = folded;
			tok.termlen = flen;
			return tok;
		}
	}
	tok.kind = TOK_TERM;
	tok.term = folded;
	tok.termlen = flen;
	lex_term_suffix(st, &tok);
	if (tok.prefix || tok.fuzzy_k > 0 || tok.weightmask != 0)
		return tok;

	/* keyword recognition (ASCII, case already folded).  Keyword tokens ALSO
	 * carry their folded text so a phrase/NEAR operand context can treat them as
	 * literal terms (a bare `and`/`or`/`not`/`near` inside "..." or NEAR(...) is a
	 * word, not an operator -- matching to_tsquery, which lexes them as lexemes). */
	if (flen == 3 && memcmp(folded, "and", 3) == 0)
	{
		tok.kind = TOK_AND;
		tok.term = folded;
		tok.termlen = flen;
	}
	else if (flen == 2 && memcmp(folded, "or", 2) == 0)
	{
		tok.kind = TOK_OR;
		tok.term = folded;
		tok.termlen = flen;
	}
	else if (flen == 3 && memcmp(folded, "not", 3) == 0)
	{
		tok.kind = TOK_NOT;
		tok.term = folded;
		tok.termlen = flen;
	}
	else if (flen == 4 && memcmp(folded, "near", 4) == 0)
	{
		tok.kind = TOK_NEAR;
		tok.term = folded;
		tok.termlen = flen;
	}
	return tok;
}

/*
 * next_token -- consume and return the next token, using the one-token
 * lookahead cache if a peek() filled it.
 */
static Token
next_token(ParseState *st)
{
	if (st->have_peeked)
	{
		st->have_peeked = false;
		return st->peeked;
	}
	return lex_raw(st);
}

/* peek -- return the next token without consuming it (lexed at most once) */
static Token
peek(ParseState *st)
{
	if (!st->have_peeked)
	{
		st->peeked = lex_raw(st);
		st->have_peeked = true;
	}
	return st->peeked;
}

/* Keep modifiers identical for bare terms, phrase terms and NEAR terms. */
static void
emit_term(ParseState *st, const Token *tok)
{
	uint16		flags = 0;
	uint32		distance = 0;

	/* A fuzzy distance and weight mask share the same stored field. */
	if ((tok->fuzzy_k > 0 && tok->weightmask != 0) ||
		(tok->regex && (tok->prefix || tok->fuzzy_k > 0 || tok->weightmask != 0)))
	{
		st->error = true;
		return;
	}
	if (tok->regex)
		flags = FTS_QF_REGEX;
	else if (tok->fuzzy_k > 0)
	{
		flags = FTS_QF_FUZZY;
		distance = (uint32) tok->fuzzy_k;
	}
	else if (tok->prefix)
		flags = FTS_QF_PREFIX;
	if (tok->weightmask != 0)
	{
		flags |= FTS_QF_WEIGHTED;
		distance = tok->weightmask;
	}
	emit_dist(st, FTS_QI_VAL, 0, tok->term, tok->termlen, flags, distance);
}

/* primary := '(' expr ')' | '"' term+ '"' | term */
static void
parse_primary(ParseState *st)
{
	Token		tok = next_token(st);

	if (tok.kind == TOK_LPAREN)
	{
		parse_or(st);
		tok = next_token(st);
		if (tok.kind != TOK_RPAREN)
			st->error = true;
	}
	else if (tok.kind == TOK_QUOTE)
	{
		/* Quoted phrases require exact adjacency, including stopword gaps. */
		int			nterms = 0;

		for (;;)
		{
			Token		p = next_token(st);

			if (p.kind == TOK_QUOTE)
			{
				/* Modifiers apply to individual terms, not to a whole phrase. */
				lex_term_suffix(st, &p);
				if (p.prefix || p.fuzzy_k > 0 || p.weightmask != 0)
					st->error = true;
				break;
			}
			/* inside "...", a bare and/or/not/near is a literal word, not an
			 * operator: accept keyword tokens (they carry their folded text). */
			if (p.kind != TOK_TERM && p.kind != TOK_AND && p.kind != TOK_OR &&
				p.kind != TOK_NOT && p.kind != TOK_NEAR && p.kind != TOK_PROX)
			{
				st->error = true;
				break;
			}
			if (p.term == NULL)	/* defensive: only real punctuation lacks text */
			{
				st->error = true;
				break;
			}
			emit_term(st, &p);
			if (st->error)
				return;
			if (nterms > 0)
				emit_dist(st, FTS_QI_OPR, FTS_OP_EXACT, NULL, 0, 0, 1);
			nterms++;
		}
		if (nterms == 0)
			st->error = true;	/* empty phrase "" */
	}
	else if (tok.kind == TOK_NEAR)
	{
		/* NEAR( term term ... , k ) : proximity within k tokens */
		int			nterms = 0;
		uint32		dist = 0;
		Token		p;

		p = next_token(st);
		if (p.kind != TOK_LPAREN)
		{
			st->error = true;
			return;
		}
		/* terms up to the comma */
		for (;;)
		{
			p = peek(st);
			if (p.kind == TOK_COMMA || p.kind == TOK_RPAREN ||
				p.kind == TOK_EOF)
				break;
			p = next_token(st);
			/* inside NEAR(...), and/or/not/near are literal words (they carry
			 * their folded text), not operators. */
			if ((p.kind != TOK_TERM && p.kind != TOK_AND && p.kind != TOK_OR &&
				 p.kind != TOK_NOT && p.kind != TOK_NEAR && p.kind != TOK_PROX) ||
				p.term == NULL)
			{
				st->error = true;
				return;
			}
			emit_term(st, &p);
			if (st->error)
				return;
			nterms++;
		}
		/* optional ", k" (k defaults to 10 like FTS5 when omitted) */
		p = next_token(st);
		if (p.kind == TOK_COMMA)
		{
			Token		kt = next_token(st);

			if (kt.kind != TOK_TERM ||
				!parse_distance(kt.term, kt.termlen, &dist))
			{
				st->error = true;
				return;
			}
			p = next_token(st);
		}
		else
			dist = 10;			/* NEAR default proximity */
		if (p.kind != TOK_RPAREN)
		{
			st->error = true;
			return;
		}
		if (nterms < 2 || dist < 1)
		{
			st->error = true;	/* NEAR needs >=2 terms and k>=1 */
			return;
		}
		/* join the nterms operands with PHRASE(dist): nterms-1 operators */
		{
			int			m;

			for (m = 1; m < nterms; m++)
				emit_dist(st, FTS_QI_OPR, FTS_OP_PHRASE, NULL, 0, 0, dist);
		}
	}
	else if (tok.kind == TOK_TERM)
		emit_term(st, &tok);
	else
	{
		st->error = true;
	}
}

/* unary := NOT unary | primary */
static void
parse_unary(ParseState *st)
{
	Token		tok = peek(st);

	check_stack_depth();
	if (tok.kind == TOK_NOT)
	{
		(void) next_token(st);
		parse_unary(st);
		emit(st, FTS_QI_OPR, FTS_OP_NOT, NULL, 0, 0);
	}
	else
		parse_primary(st);
}

/* Proximity binds tighter than AND and accepts grouped Boolean operands. */
static void
parse_proximity(ParseState *st)
{
	int			start = st->nitems;
	int			i;

	parse_unary(st);
	while (peek(st).kind == TOK_PROX)
	{
		Token		tok = next_token(st);

		if (tok.op != FTS_OP_EXACT &&
			(!parse_distance(tok.term + 2, tok.termlen - 2, &tok.distance) ||
			 tok.distance == 0))
		{
			st->error = true;
			return;
		}

		parse_unary(st);
		/* OR and proximity retain matching spans; AND/NOT do not. */
		for (i = start; i < st->nitems; i++)
		{
			if (st->items[i].type != FTS_QI_OPR)
				continue;
			if (st->items[i].op == FTS_OP_AND ||
				st->items[i].op == FTS_OP_NOT)
				st->error = true;
		}
		if (st->error)
			return;
		emit_dist(st, FTS_QI_OPR, tok.op, NULL, 0, 0, tok.distance);
		start = st->nitems;		/* earlier operands have already been checked */
	}
}

/* and_expr := proximity ( AND? proximity )* */
static void
parse_and(ParseState *st)
{
	parse_proximity(st);
	for (;;)
	{
		Token		tok = peek(st);

		if (tok.kind == TOK_AND)
		{
			(void) next_token(st);
			parse_proximity(st);
			emit(st, FTS_QI_OPR, FTS_OP_AND, NULL, 0, 0);
		}
		else if (tok.kind == TOK_TERM || tok.kind == TOK_NOT ||
				 tok.kind == TOK_LPAREN || tok.kind == TOK_QUOTE ||
				 tok.kind == TOK_NEAR)
		{
			/* implicit AND */
			parse_proximity(st);
			emit(st, FTS_QI_OPR, FTS_OP_AND, NULL, 0, 0);
		}
		else
			break;
	}
}

/* or_expr := and_expr ( OR and_expr )* */
static void
parse_or(ParseState *st)
{
	parse_and(st);
	for (;;)
	{
		Token		tok = peek(st);

		if (tok.kind == TOK_OR)
		{
			(void) next_token(st);
			parse_and(st);
			emit(st, FTS_QI_OPR, FTS_OP_OR, NULL, 0, 0);
		}
		else
			break;
	}
}

/*
 * Stopword-aware query normalization.
 *
 * to_ftsdoc() drops configuration stopwords from the document, so a query term
 * that is a stopword can never match a stored lexeme.  Standard PostgreSQL FTS
 * drops stopwords from BOTH sides (to_tsquery('english','the & x') -> 'x'), so
 * a stopword conjunct must be ELIDED from the query, not left as an
 * unsatisfiable term (which silently zeroes an AND).  We do that here by
 * building a small tree from the parsed RPN, marking each plain term that
 * normalizes away (fts_normalize_term returns NULL) as empty, and simplifying:
 *
 *   X & empty -> X      empty & X -> X       (AND drops the stopword side)
 *   X | empty -> X      empty | X -> X       (OR likewise; matches to_tsquery)
 *   !empty    -> empty                       (nothing to negate)
 *   X <-> empty / empty <-> X -> X           (carry the removed gap outward)
 *   empty (op) empty -> empty
 *
 * Exact phrase distances accumulate across removed stopwords, so
 * (X <-> empty) <-> Y becomes X <2> Y.  As in PostgreSQL, a retained Boolean
 * operator is a boundary for these adjustments; legacy p/N remains unchanged.
 *
 * A query that reduces entirely to empty yields a 0-item ftsquery, which
 * matches nothing -- consistent with to_tsquery('english','the') = '' @@ ... .
 * Prefix/fuzzy/regex terms are never stopwords (matched literally), so they are
 * never marked empty.
 */
typedef struct QNode
{
	bool		empty;			/* subtree elided (all-stopword) */
	int			item;			/* index into items[] for a VAL leaf, else -1 */
	uint8		op;				/* FTS_OP_* for an internal node */
	uint32		distance;		/* phrase gap */
	struct QNode *left;
	struct QNode *right;		/* NULL for NOT (unary, uses left) */
} QNode;

/* Pop the RPN in items[0..n) into a tree.  *pos walks from the end. */
static QNode *
qnode_build(ParsedItem *items, int *pos)
{
	QNode	   *n;

	check_stack_depth();
	if (*pos < 0)
		return NULL;
	n = (QNode *) palloc0(sizeof(QNode));
	n->item = -1;
	if (items[*pos].type == FTS_QI_VAL)
	{
		n->item = *pos;
		(*pos)--;
		return n;
	}
	n->op = items[*pos].op;
	n->distance = items[*pos].distance;
	(*pos)--;
	if (n->op == FTS_OP_NOT)
		n->left = qnode_build(items, pos);		/* unary */
	else
	{
		n->right = qnode_build(items, pos);		/* RPN top is the right operand */
		n->left = qnode_build(items, pos);
	}
	return n;
}

/* Simplify a tree in place, folding away empty (stopword) subtrees. */
static QNode *
qnode_simplify(QNode *n, uint64 *leftgap, uint64 *rightgap)
{
	uint64		ll,
				lr,
				rl,
				rr;

	check_stack_depth();
	*leftgap = *rightgap = 0;
	if (n == NULL)
		return NULL;
	if (n->item >= 0)
		return n;					/* leaf: emptiness marked by the caller */
	n->left = qnode_simplify(n->left, &ll, &lr);
	n->right = qnode_simplify(n->right, &rl, &rr);
	if (n->op == FTS_OP_NOT)
	{
		if (n->left == NULL || n->left->empty)
			n->empty = true;
		*leftgap = ll;
		*rightgap = lr;
		return n;
	}
	{
		bool		le = (n->left == NULL || n->left->empty);
		bool		re = (n->right == NULL || n->right->empty);
		bool		exact = (n->op == FTS_OP_EXACT);

		if (le && re)
		{
			n->empty = true;
			*leftgap = *rightgap = exact ? ll + n->distance + rl : Max(ll, rl);
			return n;
		}
		if (le)
		{
			*leftgap = exact ? ll + n->distance + rl : rl;
			*rightgap = rr;
			return n->right;
		}
		if (re)
		{
			*leftgap = ll;
			*rightgap = exact ? lr + n->distance + rr : lr;
			return n->left;
		}
		if (exact)
		{
			uint64		distance = n->distance + lr + rl;

			if (distance > FTS_MAX_PROX_DISTANCE)
				ereport(ERROR,
						(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
						 errmsg("ftsquery phrase distance exceeds %u", FTS_MAX_PROX_DISTANCE)));
			n->distance = (uint32) distance;
			*leftgap = ll;
			*rightgap = rr;
		}
		return n;
	}
}

/* Flatten a simplified tree back into RPN in out[]; advances *k. */
static void
qnode_flatten(QNode *n, ParsedItem *src, ParsedItem *out, int *k)
{
	check_stack_depth();
	if (n == NULL || n->empty)
		return;
	if (n->item >= 0)
	{
		out[*k] = src[n->item];
		(*k)++;
		return;
	}
	qnode_flatten(n->left, src, out, k);
	if (n->op != FTS_OP_NOT)
		qnode_flatten(n->right, src, out, k);
	out[*k].type = FTS_QI_OPR;
	out[*k].op = n->op;
	out[*k].flags = 0;
	out[*k].distance = n->distance;
	out[*k].term = NULL;
	out[*k].termlen = 0;
	(*k)++;
}

/*
 * fts_parse_query -- parse query text into an FtsQuery varlena.
 * Raises an error on malformed input.  An input with no terms yields a valid
 * empty query (matches nothing).
 *
 * If cfgId is a valid text-search config, each plain term is normalized through
 * that config (stemming, case, stopwords) so it matches the same lexemes the
 * document index stores.  Prefix (term*), fuzzy (term~k) and regex (/re/) terms
 * are left literal -- they are matched against raw stored lexemes, not stemmed.
 * cfgId == InvalidOid keeps the raw folded term (the simple analyzer path).
 */
FtsQuery
fts_parse_query_cfg(const char *str, int len, Oid cfgId)
{
	ParseState	st;
	FtsQuery	q;
	FtsQueryItem *items;
	char	   *textbase;
	Size		textbytes = 0;
	Size		total;
	uint32		off = 0;
	int			i;

	st.buf = str;
	st.len = len;
	st.pos = 0;
	st.items = NULL;
	st.nitems = 0;
	st.maxitems = 0;
	st.error = false;
	st.have_peeked = false;

	/* Only parse if there is at least one token; else empty query. */
	if (peek(&st).kind != TOK_EOF)
	{
		parse_or(&st);
		if (!st.error && peek(&st).kind != TOK_EOF)
			st.error = true;	/* trailing garbage */
	}

	if (st.error)
		ereport(ERROR,
				(errcode(ERRCODE_SYNTAX_ERROR),
				 errmsg("syntax error in ftsquery: \"%.*s\"", len, str)));

	/*
	 * Normalize plain terms through the text-search config so they match the
	 * document index's stemmed lexemes.  Prefix/fuzzy/regex terms stay literal.
	 */
	if (OidIsValid(cfgId))
	{
		bool	   *stopword = (bool *) palloc0(sizeof(bool) * Max(st.nitems, 1));
		bool		any_stop = false;

		for (i = 0; i < st.nitems; i++)
		{
			if (st.items[i].type == FTS_QI_VAL &&
				!(st.items[i].flags & (FTS_QF_PREFIX | FTS_QF_FUZZY | FTS_QF_REGEX)))
			{
				int			nlen;
				char	   *norm = fts_normalize_term(cfgId, st.items[i].term,
														 st.items[i].termlen, &nlen);

				if (norm != NULL)
				{
					st.items[i].term = norm;
					st.items[i].termlen = nlen;
				}
				else
				{
					/* stopword: mark for elision so it does not zero an AND */
					stopword[i] = true;
					any_stop = true;
				}
			}
		}

		/*
		 * Elide stopword terms: build the RPN into a tree, mark stopword leaves
		 * empty, simplify (drop empty operands + their operators), flatten back.
		 */
		if (any_stop && st.nitems > 0)
		{
			int			pos = st.nitems - 1;
			QNode	   *root = qnode_build(st.items, &pos);
			QNode	  **stack = (QNode **) palloc(sizeof(QNode *) * st.nitems);
			int			sp = 0;
			uint64		leftgap,
						rightgap;

			if (root)
				stack[sp++] = root;
			while (sp > 0)
			{
				QNode	   *nd = stack[--sp];

				if (nd->item >= 0)
					nd->empty = stopword[nd->item];
				else
				{
					if (nd->left)
						stack[sp++] = nd->left;
					if (nd->right)
						stack[sp++] = nd->right;
				}
			}
			root = qnode_simplify(root, &leftgap, &rightgap);
			{
				ParsedItem *out = (ParsedItem *) palloc(sizeof(ParsedItem) * st.nitems);
				int			k = 0;

				qnode_flatten(root, st.items, out, &k);
				for (i = 0; i < k; i++)
					st.items[i] = out[i];
				st.nitems = k;
			}
		}
	}

	for (i = 0; i < st.nitems; i++)
		if (st.items[i].type == FTS_QI_VAL)
			textbytes += st.items[i].termlen;

	total = FTS_QUERY_HDRSIZE +
		(Size) st.nitems * sizeof(FtsQueryItem) + textbytes;
	q = (FtsQuery) palloc0(total);
	SET_VARSIZE(q, total);
	q->version = FTS_QUERY_VERSION;
	q->flags = 0;
	q->nitems = st.nitems;

	items = q->items;
	textbase = FTS_QUERY_TEXTBASE(q);
	for (i = 0; i < st.nitems; i++)
	{
		items[i].type = st.items[i].type;
		items[i].op = st.items[i].op;
		items[i].flags = st.items[i].flags;
		items[i].distance = st.items[i].distance;
		if (st.items[i].type == FTS_QI_VAL)
		{
			items[i].termoff = off;
			items[i].termlen = st.items[i].termlen;
			memcpy(textbase + off, st.items[i].term, st.items[i].termlen);
			off += st.items[i].termlen;
		}
		else
		{
			items[i].termoff = 0;
			items[i].termlen = 0;
		}
	}

	return q;
}

/* raw parse (no config normalization) -- the simple analyzer / ftsquery_in path */
FtsQuery
fts_parse_query(const char *str, int len)
{
	return fts_parse_query_cfg(str, len, InvalidOid);
}

PG_FUNCTION_INFO_V1(ftsquery_in);
PG_FUNCTION_INFO_V1(ftsquery_out);
PG_FUNCTION_INFO_V1(ftsquery_recv);
PG_FUNCTION_INFO_V1(ftsquery_send);
PG_FUNCTION_INFO_V1(to_ftsquery);
PG_FUNCTION_INFO_V1(to_ftsquery_byid);

Datum
ftsquery_in(PG_FUNCTION_ARGS)
{
	char	   *in = PG_GETARG_CSTRING(0);

	PG_RETURN_FTSQUERY(fts_parse_query(in, strlen(in)));
}

Datum
to_ftsquery(PG_FUNCTION_ARGS)
{
	text	   *in = PG_GETARG_TEXT_PP(0);
	FtsQuery	q;

	q = fts_parse_query(VARDATA_ANY(in), VARSIZE_ANY_EXHDR(in));
	PG_FREE_IF_COPY(in, 0);
	PG_RETURN_FTSQUERY(q);
}

/* to_ftsquery(regconfig, text): parse and normalize terms through the config */
Datum
to_ftsquery_byid(PG_FUNCTION_ARGS)
{
	Oid			cfgId = PG_GETARG_OID(0);
	text	   *in = PG_GETARG_TEXT_PP(1);
	FtsQuery	q;

	q = fts_parse_query_cfg(VARDATA_ANY(in), VARSIZE_ANY_EXHDR(in), cfgId);
	PG_FREE_IF_COPY(in, 1);
	PG_RETURN_FTSQUERY(q);
}

/*
 * Render an ftsquery as fully parenthesised infix for display/debugging.
 * Ordered and unordered proximity print with their exact distances so the
 * output can be parsed back without changing the query's meaning.
 * Postfix RPN is walked with a small string stack.
 */
Datum
ftsquery_out(PG_FUNCTION_ARGS)
{
	FtsQuery	q = PG_GETARG_FTSQUERY(0);
	FtsQueryItem *items = q->items;
	StringInfoData *stack;
	int			top = 0;
	uint32		i;
	StringInfoData result;

	if (q->nitems == 0)
	{
		PG_FREE_IF_COPY(q, 0);
		PG_RETURN_CSTRING(pstrdup(""));
	}

	stack = (StringInfoData *) palloc(q->nitems * sizeof(StringInfoData));

	for (i = 0; i < q->nitems; i++)
	{
		FtsQueryItem *it = &items[i];

		if (it->type == FTS_QI_VAL)
		{
			StringInfoData s;
			int			j;
			const char *t = FTS_QUERY_ITEMTEXT(q, it);

			initStringInfo(&s);
			if (it->flags & FTS_QF_REGEX)
			{
				appendStringInfoChar(&s, '/');
				appendBinaryStringInfo(&s, t, it->termlen);
				appendStringInfoChar(&s, '/');
				stack[top++] = s;
				continue;
			}
			appendStringInfoChar(&s, '\'');
			for (j = 0; j < (int) it->termlen; j++)
			{
				if (t[j] == '\'' || t[j] == '\\')
					appendStringInfoChar(&s, '\\');
				appendStringInfoChar(&s, t[j]);
			}
			appendStringInfoChar(&s, '\'');
			if (it->flags & FTS_QF_PREFIX)
				appendStringInfoChar(&s, '*');
			else if (it->flags & FTS_QF_FUZZY)
				appendStringInfo(&s, "~%u", it->distance);
			if (it->flags & FTS_QF_WEIGHTED)
			{
				/* render the weight mask as :A/B/C/D (high labels first) */
				appendStringInfoChar(&s, ':');
				if (it->distance & (1u << 3)) appendStringInfoChar(&s, 'A');
				if (it->distance & (1u << 2)) appendStringInfoChar(&s, 'B');
				if (it->distance & (1u << 1)) appendStringInfoChar(&s, 'C');
				if (it->distance & (1u << 0)) appendStringInfoChar(&s, 'D');
			}
			stack[top++] = s;
		}
		else if (it->op == FTS_OP_NOT)
		{
			StringInfoData s;

			Assert(top >= 1);
			initStringInfo(&s);
			appendStringInfoString(&s, "!");
			appendBinaryStringInfo(&s, stack[top - 1].data,
								   stack[top - 1].len);
			pfree(stack[top - 1].data);
			stack[top - 1] = s;
		}
		else
		{
			StringInfoData s;
			const char *opstr;

			switch (it->op)
			{
				case FTS_OP_AND:
					opstr = " & ";
					break;
				case FTS_OP_OR:
					opstr = " | ";
					break;
				case FTS_OP_PHRASE:
					opstr = NULL;
					break;
				case FTS_OP_WITHIN:
				case FTS_OP_EXACT:
					opstr = NULL;
					break;
				default:
					opstr = " ? ";
					break;
			}
			Assert(top >= 2);
			initStringInfo(&s);
			appendStringInfoChar(&s, '(');
			appendBinaryStringInfo(&s, stack[top - 2].data,
								   stack[top - 2].len);
			if (opstr != NULL)
				appendStringInfoString(&s, opstr);
			else if (it->op == FTS_OP_EXACT && it->distance == 1)
				appendStringInfoString(&s, " <-> ");
			else if (it->op == FTS_OP_EXACT)
				appendStringInfo(&s, " <%u> ", it->distance);
			else
				appendStringInfo(&s, " %c/%u ",
								 (it->op == FTS_OP_WITHIN) ? 'w' : 'p',
								 it->distance);
			appendBinaryStringInfo(&s, stack[top - 1].data,
								   stack[top - 1].len);
			appendStringInfoChar(&s, ')');
			pfree(stack[top - 1].data);
			pfree(stack[top - 2].data);
			top -= 2;
			stack[top++] = s;
		}
	}

	Assert(top == 1);
	initStringInfo(&result);
	appendBinaryStringInfo(&result, stack[0].data, stack[0].len);
	pfree(stack[0].data);

	PG_FREE_IF_COPY(q, 0);
	PG_RETURN_CSTRING(result.data);
}

Datum
ftsquery_recv(PG_FUNCTION_ARGS)
{
	StringInfo	buf = (StringInfo) PG_GETARG_POINTER(0);
	uint16		version;
	uint32		nitems;
	FtsQuery	q;
	FtsQueryItem *items;
	char	   *textbase;
	uint8	   *types;
	uint8	   *ops;
	uint16	   *flags;
	uint32	   *dists;
	char	  **terms;
	int		   *lens;
	Size		textbytes = 0;
	uint32		off = 0;
	uint32		i;
	uint32		depth = 0;

	version = (uint16) pq_getmsgint(buf, 2);
	if (version != FTS_QUERY_VERSION)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_BINARY_REPRESENTATION),
				 errmsg("unsupported ftsquery version number %u", version)));

	nitems = (uint32) pq_getmsgint(buf, 4);

	/*
	 * Guard against a hostile/corrupt binary message: each item is at least a
	 * few fixed bytes (type+op+flags+distance), so nitems cannot exceed the
	 * remaining bytes / 8.  Rejects absurd counts before palloc (overflow /
	 * OOM at a trust boundary).
	 */
	if (nitems > (uint32) (buf->len - buf->cursor) / 8)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_BINARY_REPRESENTATION),
				 errmsg("invalid ftsquery: item count %u exceeds message size", nitems)));

	types = (uint8 *) palloc(nitems * sizeof(uint8));
	ops = (uint8 *) palloc(nitems * sizeof(uint8));
	flags = (uint16 *) palloc(nitems * sizeof(uint16));
	dists = (uint32 *) palloc(nitems * sizeof(uint32));
	terms = (char **) palloc(nitems * sizeof(char *));
	lens = (int *) palloc(nitems * sizeof(int));

	for (i = 0; i < nitems; i++)
	{
		types[i] = (uint8) pq_getmsgint(buf, 1);
		ops[i] = (uint8) pq_getmsgint(buf, 1);
		flags[i] = (uint16) pq_getmsgint(buf, 2);
		dists[i] = (uint32) pq_getmsgint(buf, 4);
		if (types[i] == FTS_QI_VAL)
		{
			const char *t;
			uint16		patterns = flags[i] &
				(FTS_QF_PREFIX | FTS_QF_FUZZY | FTS_QF_REGEX);

			/* Binary input must obey the same modifier rules as emit_term.
			 * Otherwise candidate generation and the span matcher can give
			 * different meanings to the same leaf (e.g. PREFIX | FUZZY). */
			if (ops[i] != 0 ||
				(flags[i] & ~(FTS_QF_PREFIX | FTS_QF_FUZZY |
							  FTS_QF_REGEX | FTS_QF_WEIGHTED)) != 0 ||
				(patterns & (patterns - 1)) != 0 ||
				((flags[i] & FTS_QF_WEIGHTED) &&
				 (patterns & (FTS_QF_FUZZY | FTS_QF_REGEX))))
				ereport(ERROR,
						(errcode(ERRCODE_INVALID_BINARY_REPRESENTATION),
						 errmsg("invalid ftsquery term modifiers")));
			if ((flags[i] & FTS_QF_WEIGHTED) ?
				(dists[i] == 0 || dists[i] > 15) :
				((flags[i] & FTS_QF_FUZZY) ?
				 (dists[i] == 0 || dists[i] > INT_MAX) : dists[i] != 0))
				ereport(ERROR,
						(errcode(ERRCODE_INVALID_BINARY_REPRESENTATION),
						 errmsg("invalid ftsquery term distance or weight mask")));

			lens[i] = pq_getmsgint(buf, 4);
			if (lens[i] < 0)
				ereport(ERROR,
						(errcode(ERRCODE_INVALID_BINARY_REPRESENTATION),
						 errmsg("invalid ftsquery term length")));
			t = pq_getmsgbytes(buf, lens[i]);
			terms[i] = (char *) palloc(lens[i]);
			memcpy(terms[i], t, lens[i]);
			textbytes += lens[i];
			depth++;
		}
		else
		{
			if (types[i] != FTS_QI_OPR ||
				(ops[i] != FTS_OP_NOT && ops[i] != FTS_OP_AND &&
				 ops[i] != FTS_OP_OR && ops[i] != FTS_OP_PHRASE &&
				 ops[i] != FTS_OP_WITHIN && ops[i] != FTS_OP_EXACT))
				ereport(ERROR,
						(errcode(ERRCODE_INVALID_BINARY_REPRESENTATION),
						 errmsg("invalid ftsquery item")));
			/* Older tsquery casts wrote 1 in the unused AND/OR distance
			 * field. Accept that valid legacy representation and normalize it. */
			if ((ops[i] == FTS_OP_AND || ops[i] == FTS_OP_OR) && dists[i] == 1)
				dists[i] = 0;
			if (flags[i] != 0 ||
				((ops[i] == FTS_OP_NOT || ops[i] == FTS_OP_AND ||
				  ops[i] == FTS_OP_OR) && dists[i] != 0) ||
				(ops[i] == FTS_OP_WITHIN && dists[i] == 0))
				ereport(ERROR,
						(errcode(ERRCODE_INVALID_BINARY_REPRESENTATION),
						 errmsg("invalid ftsquery operator flags or distance")));
			/* Old tsquery casts of <0> emitted PHRASE(0). Preserve its
			 * historical always-false result, rather than reinterpret it as
			 * EXACT(0). The text parser still rejects p/0. */
			lens[i] = 0;
			terms[i] = NULL;
			if (depth < (ops[i] == FTS_OP_NOT ? 1u : 2u))
				ereport(ERROR,
						(errcode(ERRCODE_INVALID_BINARY_REPRESENTATION),
						 errmsg("invalid ftsquery operator operands")));
			if (ops[i] != FTS_OP_NOT)
				depth--;
		}
	}
	if (depth != (nitems == 0 ? 0u : 1u))
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_BINARY_REPRESENTATION),
				 errmsg("invalid ftsquery expression")));

	{
		Size		total = FTS_QUERY_HDRSIZE +
			(Size) nitems * sizeof(FtsQueryItem) + textbytes;

		q = (FtsQuery) palloc0(total);
		SET_VARSIZE(q, total);
		q->version = FTS_QUERY_VERSION;
		q->flags = 0;
		q->nitems = nitems;

		items = q->items;
		textbase = FTS_QUERY_TEXTBASE(q);
		for (i = 0; i < nitems; i++)
		{
			items[i].type = types[i];
			items[i].op = ops[i];
			items[i].flags = flags[i];
			items[i].distance = dists[i];
			if (types[i] == FTS_QI_VAL)
			{
				items[i].termoff = off;
				items[i].termlen = lens[i];
				memcpy(textbase + off, terms[i], lens[i]);
				off += lens[i];
			}
		}
	}

	PG_RETURN_FTSQUERY(q);
}

Datum
ftsquery_send(PG_FUNCTION_ARGS)
{
	FtsQuery	q = PG_GETARG_FTSQUERY(0);
	FtsQueryItem *items = q->items;
	StringInfoData buf;
	uint32		i;

	pq_begintypsend(&buf);
	pq_sendint16(&buf, q->version);
	pq_sendint32(&buf, q->nitems);
	for (i = 0; i < q->nitems; i++)
	{
		pq_sendint8(&buf, items[i].type);
		pq_sendint8(&buf, items[i].op);
		pq_sendint16(&buf, items[i].flags);
		pq_sendint32(&buf, items[i].distance);
		if (items[i].type == FTS_QI_VAL)
		{
			pq_sendint32(&buf, items[i].termlen);
			pq_sendbytes(&buf, FTS_QUERY_ITEMTEXT(q, &items[i]),
						 items[i].termlen);
		}
	}

	PG_FREE_IF_COPY(q, 0);
	PG_RETURN_BYTEA_P(pq_endtypsend(&buf));
}
