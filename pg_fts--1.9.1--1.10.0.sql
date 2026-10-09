/* pg_fts 1.9.1 -> 1.10.0
 *
 * One server-wide shared copy of each index segment's document-length array
 * (pg_fts.shared_doclen, default on), and a function to inspect it.
 *
 * No on-disk format change (BM25_VERSION unchanged): no REINDEX required.
 */
CREATE FUNCTION fts_shared_doclen_stats(
    OUT dbid oid, OUT relfilenumber oid, OUT doclenstart bigint, OUT ndocs float8,
    OUT state text, OUT refcnt integer, OUT retired boolean, OUT bytes bigint)
RETURNS SETOF record
AS 'MODULE_PATHNAME', 'fts_shared_doclen_stats'
LANGUAGE C STRICT VOLATILE PARALLEL RESTRICTED;
