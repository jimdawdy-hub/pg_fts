#!/bin/bash
# free-space layout of a freshly built index: fraction free per 10% band of the file (FSM view)
B=/nvme/pgs/bin; P="$B/psql -h /tmp -p 55440 -U postgres -X -q -At"
$P -c "CREATE EXTENSION IF NOT EXISTS pg_freespacemap" >/dev/null
$P -c "DROP INDEX IF EXISTS docs_fts_b" >/dev/null
$P -c "SET client_min_messages=warning" -c "CREATE INDEX docs_fts_b ON docs USING fts (d)" >/dev/null
$P -c "VACUUM docs" >/dev/null 2>&1
$P -c "WITH f AS (SELECT blkno, avail FROM pg_freespace('docs_fts_b')), n AS (SELECT count(*) c FROM f)
SELECT (blkno*10/n.c) band, count(*) blocks, round(100.0*count(*) FILTER (WHERE avail >= 4096)/count(*),1) pct_free FROM f, n GROUP BY 1 ORDER BY 1"
