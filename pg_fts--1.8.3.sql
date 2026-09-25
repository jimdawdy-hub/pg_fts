/* pg_fts--0.3.6.sql */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION pg_fts" to load this file. \quit

--
-- ftsdoc: an analyzed full-text document (terms + term frequencies).
-- to_ftsdoc() records per-term token positions (ftsdoc format v2), which the
-- phrase-query syntax ("a b c") relies on.
--
CREATE TYPE ftsdoc;

CREATE FUNCTION ftsdoc_in(cstring)
RETURNS ftsdoc
AS 'MODULE_PATHNAME'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION ftsdoc_out(ftsdoc)
RETURNS cstring
AS 'MODULE_PATHNAME'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION ftsdoc_recv(internal)
RETURNS ftsdoc
AS 'MODULE_PATHNAME'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION ftsdoc_send(ftsdoc)
RETURNS bytea
AS 'MODULE_PATHNAME'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE TYPE ftsdoc (
    INPUT          = ftsdoc_in,
    OUTPUT         = ftsdoc_out,
    RECEIVE        = ftsdoc_recv,
    SEND           = ftsdoc_send,
    INTERNALLENGTH = VARIABLE,
    STORAGE        = extended
);

--
-- ftsquery: a parsed boolean query.  Supports boolean operators, phrase
-- syntax ("a b c"), prefix (term*), fuzzy (term~k) and regex (/re/) terms.
--
CREATE TYPE ftsquery;

CREATE FUNCTION ftsquery_in(cstring)
RETURNS ftsquery
AS 'MODULE_PATHNAME'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION ftsquery_out(ftsquery)
RETURNS cstring
AS 'MODULE_PATHNAME'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION ftsquery_recv(internal)
RETURNS ftsquery
AS 'MODULE_PATHNAME'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION ftsquery_send(ftsquery)
RETURNS bytea
AS 'MODULE_PATHNAME'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE TYPE ftsquery (
    INPUT          = ftsquery_in,
    OUTPUT         = ftsquery_out,
    RECEIVE        = ftsquery_recv,
    SEND           = ftsquery_send,
    INTERNALLENGTH = VARIABLE,
    STORAGE        = extended
);

--
-- Constructors from text.
--
CREATE FUNCTION to_ftsdoc(text)
RETURNS ftsdoc
AS 'MODULE_PATHNAME'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION to_ftsquery(text)
RETURNS ftsquery
AS 'MODULE_PATHNAME'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

-- Analyzer that reuses an installed text search configuration (pg_ts_config):
-- the configured parser + dictionary chain (stemming, stopwords, synonyms,
-- thesaurus) is applied, rather than the built-in simple tokenizer.
CREATE FUNCTION to_ftsdoc(regconfig, text)
RETURNS ftsdoc
AS 'MODULE_PATHNAME', 'to_ftsdoc_byid'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

-- Build an ftsdoc directly from an existing tsvector (no re-analysis of source
-- text): the adoption on-ramp for a table that already materializes a tsvector
-- column.  A tsvector's lexemes are sorted+distinct with ascending positions,
-- exactly ftsdoc's shape; positions are kept iff every lexeme has them.
CREATE FUNCTION to_ftsdoc(tsvector)
RETURNS ftsdoc
AS 'MODULE_PATHNAME', 'to_ftsdoc_from_tsvector'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

-- to_ftsquery(regconfig, text): parse query text AND normalize each plain term
-- through the given text search configuration (stemming, case, stopwords), so
-- query terms match the same lexemes an index built with the same config
-- stores.  Prefix (term*), fuzzy (term~k) and regex (/re/) terms stay literal.
-- Use this (not the raw text->ftsquery cast) whenever the indexed ftsdoc was
-- built with to_ftsdoc(regconfig, ...).
CREATE FUNCTION to_ftsquery(regconfig, text)
RETURNS ftsquery
AS 'MODULE_PATHNAME', 'to_ftsquery_byid'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

--
-- Support functions.
--
CREATE FUNCTION ftsdoc_length(ftsdoc)
RETURNS integer
AS 'MODULE_PATHNAME'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

--
-- The @@@ match operator.
--
CREATE FUNCTION fts_match(ftsdoc, ftsquery)
RETURNS boolean
AS 'MODULE_PATHNAME'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION fts_match_commutator(ftsquery, ftsdoc)
RETURNS boolean
AS 'MODULE_PATHNAME'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE OPERATOR @@@ (
    LEFTARG    = ftsdoc,
    RIGHTARG   = ftsquery,
    PROCEDURE  = fts_match,
    COMMUTATOR = @@@,
    RESTRICT   = tsmatchsel,
    JOIN       = tsmatchjoinsel
);

CREATE OPERATOR @@@ (
    LEFTARG    = ftsquery,
    RIGHTARG   = ftsdoc,
    PROCEDURE  = fts_match_commutator,
    COMMUTATOR = @@@,
    RESTRICT   = tsmatchsel,
    JOIN       = tsmatchjoinsel
);

--
-- BM25 relevance scoring.
--
-- BM25 relevance score of a document against a query.
--   n_docs : total documents in the corpus (N)
--   avgdl  : average document length (in tokens)
--   dfs    : optional float8[] of per-query-term document frequencies, in the
--            order the query's distinct terms appear; NULL treats terms as rare
CREATE FUNCTION fts_bm25(ftsdoc, ftsquery, n_docs float8, avgdl float8,
                         dfs float8[] DEFAULT NULL)
RETURNS float8
AS 'MODULE_PATHNAME', 'fts_bm25'
LANGUAGE C IMMUTABLE PARALLEL SAFE;

-- BM25 with selectable variant and explicit k1/b, for reproducing reference
-- implementations (Lucene, Robertson/classic, ATIRE, BM25+).
CREATE FUNCTION fts_bm25_opts(ftsdoc, ftsquery,
                              n_docs float8, avgdl float8,
                              k1 float8, b float8,
                              variant text,
                              dfs float8[] DEFAULT NULL)
RETURNS float8
AS 'MODULE_PATHNAME', 'fts_bm25_opts'
LANGUAGE C IMMUTABLE PARALLEL SAFE;

-- BM25F: multi-field BM25.  Pass one ftsdoc per field (e.g. title, body), a
-- weight per field, and an avgdl per field.  Per-field term frequencies are
-- length-normalized per field and combined by weight before tf-saturation
-- (the Robertson/Zaragoza BM25F formulation).
CREATE FUNCTION fts_bm25f(docs ftsdoc[], query ftsquery,
                          weights float8[], n_docs float8, avgdls float8[],
                          dfs float8[] DEFAULT NULL)
RETURNS float8
AS 'MODULE_PATHNAME', 'fts_bm25f'
LANGUAGE C IMMUTABLE PARALLEL SAFE;

-- Zone-weighted BM25 over a single labeled ftsdoc (field boost): weights is
-- one float8 per zone A,B,C,D (missing zones default to 1.0; at most four).
-- Per-zone term frequencies sum as zone weight x zone tf before the ordinary
-- tf-saturation.  This boosts zones within one concatenated labeled ftsdoc;
-- for multi-document field weighting with per-field length norms use fts_bm25f.
CREATE FUNCTION fts_bm25(ftsdoc, ftsquery, n_docs float8, avgdl float8,
                         dfs float8[], weights float8[])
RETURNS float8
AS 'MODULE_PATHNAME', 'fts_bm25_w'
LANGUAGE C IMMUTABLE PARALLEL SAFE;

-- Zone-weighted BM25 distance (1/(1+score)) for ORDER BY, agreeing with
-- fts_bm25(doc, query, 1.0, doclen, NULL, weights) under the same weights.
CREATE FUNCTION fts_distance(ftsdoc, ftsquery, weights float8[])
RETURNS float8
AS 'MODULE_PATHNAME', 'fts_distance_w'
LANGUAGE C IMMUTABLE PARALLEL SAFE;

--
-- Highlighting and snippets.
--
-- Highlight query terms in the source text.
CREATE FUNCTION fts_highlight(doc text, query ftsquery,
                              pre text DEFAULT '<b>', post text DEFAULT '</b>')
RETURNS text
AS 'MODULE_PATHNAME', 'fts_highlight'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

-- Best-matching window (snippet) of the source text.
CREATE FUNCTION fts_snippet(doc text, query ftsquery,
                            pre text DEFAULT '<b>', post text DEFAULT '</b>',
                            ellipsis text DEFAULT '...', max_tokens int DEFAULT 15)
RETURNS text
AS 'MODULE_PATHNAME', 'fts_snippet'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

--
-- tsquery migration.
--
-- Migration helper: mechanically convert a tsquery to an ftsquery.
-- & -> AND, | -> OR, ! -> NOT.  The phrase operator <-> degrades to AND with
-- a NOTICE (phrase search is a later stage).
CREATE FUNCTION tsquery_to_ftsquery(tsquery)
RETURNS ftsquery
AS 'MODULE_PATHNAME', 'tsquery_to_ftsquery'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

-- Convenience cast so existing tsquery values flow into @@@ queries.
CREATE CAST (tsquery AS ftsquery)
    WITH FUNCTION tsquery_to_ftsquery(tsquery) AS ASSIGNMENT;

--
-- The bm25 index access method: an inverted index over an ftsdoc column that
-- answers the @@@ operator by bitmap scan and maintains corpus statistics.
-- The storage engine is segment-based: inserts flush to new segments, and a
-- size-tiered merge compacts them so query cost stays bounded.  An expression
-- index on to_ftsdoc(text_column) is the external-content model -- the text
-- lives in the base table and the index stores only postings.
--
CREATE FUNCTION fts_handler(internal)
RETURNS index_am_handler
AS 'MODULE_PATHNAME'
LANGUAGE C;

CREATE ACCESS METHOD fts TYPE INDEX HANDLER fts_handler;

COMMENT ON ACCESS METHOD fts IS 'fts inverted index for full-text search with BM25 ranking';

-- Operator class: strategy 1 is @@@ (ftsdoc @@@ ftsquery).
CREATE OPERATOR CLASS ftsdoc_fts_ops
DEFAULT FOR TYPE ftsdoc USING fts AS
    OPERATOR 1 @@@ (ftsdoc, ftsquery);

--
-- Index-maintained corpus statistics, so BM25 can be scored from the values
-- the bm25 index keeps rather than caller-supplied guesses.
--
CREATE FUNCTION fts_index_stats(regclass,
                                OUT ndocs float8, OUT avgdl float8,
                                OUT nterms bigint)
RETURNS record
AS 'MODULE_PATHNAME', 'fts_index_stats'
LANGUAGE C STRICT PARALLEL SAFE;

-- Per-query-term document frequencies from the index (for fts_bm25's dfs arg).
CREATE FUNCTION fts_index_df(regclass, ftsquery)
RETURNS float8[]
AS 'MODULE_PATHNAME', 'fts_index_df'
LANGUAGE C STRICT PARALLEL SAFE;

-- Number of live segments in a bm25 index.  Useful for observing/tuning merge
-- behavior.
CREATE FUNCTION fts_index_nsegments(regclass)
RETURNS integer
AS 'MODULE_PATHNAME', 'fts_index_nsegments'
LANGUAGE C STRICT PARALLEL SAFE;

--
-- Index-only BM25 top-k search.  Scores are computed entirely from the index
-- (postings, dictionary df/max-tf, metapage N/avgdl) with no heap access; the
-- result is the top-k (ctid, score) pairs.  Join back to the table on ctid to
-- fetch rows.  A WAND upper-bound prunes documents that cannot enter the top-k.
--
CREATE FUNCTION fts_search(index regclass, query ftsquery, k int DEFAULT 10,
                           OUT ctid tid, OUT score float8)
RETURNS SETOF record
AS 'MODULE_PATHNAME', 'fts_search'
LANGUAGE C STRICT PARALLEL SAFE;

--
-- Lexical anomaly detection: the top-k most anomalous documents in the index,
-- i.e. those containing globally RARE terms.  A document's anomaly score is the
-- max idf over its terms (driven by its single rarest term), idf being the same
-- rarity value BM25 uses: log(1 + (N-df+0.5)/(df+0.5)) on the GLOBAL df.  It is
-- cheap because only the LOW-df tail of the dictionary is walked -- common terms
-- are skipped before any posting is decoded, so this is not a full-corpus scan.
-- `max_df` caps which terms count as rare (only df <= max_df contribute); NULL
-- defaults to max(N/1000, 1).  Returns the heap ctid, the score, the rarest term
-- driving the doc, and that term's global df, ordered by score DESC limit k.
-- The ctids are index-resident heap pointers (like fts_search); join back to
-- the table and filter for visibility if needed.  Per-segment tombstones are
-- honored so deleted docs are not reported.
CREATE FUNCTION fts_anomalous_docs(index regclass, k int DEFAULT 100,
                                   max_df int DEFAULT NULL,
                                   OUT ctid tid, OUT score float8,
                                   OUT rarest_term text, OUT min_df int)
RETURNS SETOF record
AS 'MODULE_PATHNAME', 'fts_anomalous_docs'
LANGUAGE C PARALLEL SAFE;

-- MVCC-correct count of documents matching a query, computed in bulk from the
-- bm25 index (visibility via the visibility map, heap probed only for
-- not-all-visible pages) without the per-tuple executor round-trips of a scan.
CREATE FUNCTION fts_count(regclass, ftsquery)
RETURNS bigint
AS 'MODULE_PATHNAME', 'fts_count'
LANGUAGE C STRICT PARALLEL SAFE;

--
-- BM25 distance operator for ORDER BY.  distance = 1/(1+score), so ascending
-- distance is descending relevance.  When used against a bm25 index it drives
-- an index ordering scan (block-max WAND top-k) with no sort node.
--
CREATE FUNCTION fts_distance(ftsdoc, ftsquery)
RETURNS float8
AS 'MODULE_PATHNAME', 'fts_distance'
LANGUAGE C IMMUTABLE PARALLEL SAFE;

CREATE FUNCTION fts_distance_commutator(ftsquery, ftsdoc)
RETURNS float8
AS 'MODULE_PATHNAME', 'fts_distance_commutator'
LANGUAGE C IMMUTABLE PARALLEL SAFE;

CREATE OPERATOR <=> (
    LEFTARG    = ftsdoc,
    RIGHTARG   = ftsquery,
    PROCEDURE  = fts_distance,
    COMMUTATOR = <=>
);

CREATE OPERATOR <=> (
    LEFTARG    = ftsquery,
    RIGHTARG   = ftsdoc,
    PROCEDURE  = fts_distance_commutator,
    COMMUTATOR = <=>
);

-- Add the ORDER BY operator (strategy 2) to the fts operator class so
-- "ORDER BY col <=> query LIMIT k" uses an index ordering scan.
ALTER OPERATOR FAMILY ftsdoc_fts_ops USING fts ADD
    OPERATOR 2 <=> (ftsdoc, ftsquery) FOR ORDER BY pg_catalog.float_ops;

--
-- Pending-list / segment maintenance.  INSERT appends to an in-index pending
-- list; VACUUM (amvacuumcleanup) folds pending documents into the main
-- posting structure, and these functions do it on demand.
--
-- fts_merge(regclass): merge the pending list into the main segments.
CREATE FUNCTION fts_merge(regclass)
RETURNS boolean
AS 'MODULE_PATHNAME', 'fts_merge'
LANGUAGE C STRICT;

-- fts_vacuum(regclass): on-demand full compaction + truncation, reclaiming
-- the dead pages left by prior merges (shrinks the physical index file).
CREATE FUNCTION fts_vacuum(regclass)
RETURNS boolean
AS 'MODULE_PATHNAME', 'fts_vacuum'
LANGUAGE C STRICT;

-- Privilege model.  Most functions operate on values the caller already holds
-- (to_ftsdoc / to_ftsquery / fts_bm25* / fts_highlight / operators / I/O) and
-- stay executable by PUBLIC.  Two functions take an index by OID and emit its
-- internal content -- heap TIDs, scores, and (fts_anomalous_docs) indexed term
-- text -- which can widen content visibility past table-level permissions.
-- Revoke them from PUBLIC; the index owner (and superusers) keep access, and an
-- owner can grant them explicitly.  (The maintenance functions fts_merge /
-- fts_vacuum enforce ownership in C and additionally refuse to run during
-- recovery, so they need no REVOKE here.)
REVOKE ALL ON FUNCTION fts_search(regclass, ftsquery, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION fts_anomalous_docs(regclass, int, int) FROM PUBLIC;

-- Field-targeted (weight-zone) search (v1.4.0).  Tag a sub-document with a
-- weight label A/B/C/D and concatenate labelled sub-documents so a query term
-- can restrict itself to a field zone (tsvector-style term:A).  Labels live in
-- the ftsdoc value only (no index format change, no REINDEX); a field-restricted
-- query is answered via the heap recheck.
CREATE FUNCTION to_ftsdoc(regconfig, text, "char")
RETURNS ftsdoc
AS 'MODULE_PATHNAME', 'to_ftsdoc_byid_weight'
LANGUAGE C IMMUTABLE PARALLEL SAFE;

CREATE FUNCTION setftsweight(ftsdoc, "char")
RETURNS ftsdoc
AS 'MODULE_PATHNAME', 'setftsweight'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION ftsdoc_concat(ftsdoc, ftsdoc)
RETURNS ftsdoc
AS 'MODULE_PATHNAME', 'ftsdoc_concat'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE OPERATOR || (
    LEFTARG = ftsdoc, RIGHTARG = ftsdoc, FUNCTION = ftsdoc_concat
);

