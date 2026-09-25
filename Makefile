# pg_fts -- standalone PGXS build
#
# Build against an installed PostgreSQL (>= 17):
#     make PG_CONFIG=/path/to/pg_config
#     make install PG_CONFIG=/path/to/pg_config
#     make installcheck PG_CONFIG=/path/to/pg_config   # regression + isolation
#
# PG_CONFIG defaults to whatever `pg_config` is on PATH.

MODULE_big = pg_fts
OBJS = \
	$(WIN32RES) \
	pg_fts_analyze.o \
	pg_fts_tsanalyze.o \
	pg_fts_doc.o \
	pg_fts_query.o \
	pg_fts_rank.o \
	pg_fts_am.o \
	pg_fts_customscan.o \
	pg_fts_aux.o \
	pg_fts_migrate.o \
	pg_fts_trgm.o \
	vendor/sm.o \
	pg_fts_match.o

EXTENSION = pg_fts
DATA = pg_fts--1.8.3.sql pg_fts--0.2.0--0.2.1.sql pg_fts--0.2.1--0.2.2.sql pg_fts--0.2.2--0.2.3.sql pg_fts--0.2.3--0.2.4.sql pg_fts--0.2.4--0.3.0.sql pg_fts--0.3.0--0.3.1.sql pg_fts--0.3.1--0.3.2.sql pg_fts--0.3.2--0.3.3.sql pg_fts--0.3.3--0.3.4.sql pg_fts--0.3.4--0.3.5.sql pg_fts--0.3.5--0.3.6.sql pg_fts--0.3.6--1.0.0.sql pg_fts--1.0.0--1.0.1.sql pg_fts--1.0.1--1.0.2.sql pg_fts--1.0.2--1.0.3.sql pg_fts--1.0.3--1.0.4.sql pg_fts--1.0.4--1.0.5.sql pg_fts--1.0.5--1.0.6.sql pg_fts--1.0.6--1.0.7.sql pg_fts--1.0.7--1.0.8.sql pg_fts--1.0.8--1.1.0.sql pg_fts--1.1.0--1.1.1.sql pg_fts--1.1.1--1.1.2.sql pg_fts--1.1.2--1.1.3.sql pg_fts--1.1.3--1.1.4.sql pg_fts--1.1.4--1.1.5.sql pg_fts--1.1.5--1.1.6.sql pg_fts--1.1.6--1.1.7.sql pg_fts--1.1.7--1.2.0.sql pg_fts--1.2.0--1.2.1.sql pg_fts--1.2.1--1.2.2.sql pg_fts--1.2.2--1.3.0.sql pg_fts--1.3.0--1.3.1.sql pg_fts--1.3.1--1.3.2.sql pg_fts--1.3.2--1.4.0.sql pg_fts--1.4.0--1.4.1.sql pg_fts--1.4.1--1.5.0.sql pg_fts--1.5.0--1.5.1.sql pg_fts--1.5.1--1.5.2.sql pg_fts--1.5.2--1.5.3.sql pg_fts--1.5.3--1.5.4.sql pg_fts--1.5.4--1.5.5.sql pg_fts--1.5.5--1.5.6.sql pg_fts--1.5.6--1.5.7.sql pg_fts--1.5.7--1.5.8.sql pg_fts--1.5.8--1.5.9.sql pg_fts--1.5.9--1.5.10.sql pg_fts--1.5.10--1.6.0.sql pg_fts--1.6.0--1.6.1.sql pg_fts--1.6.1--1.7.0.sql pg_fts--1.7.0--1.7.1.sql pg_fts--1.7.1--1.7.2.sql pg_fts--1.7.2--1.8.0.sql pg_fts--1.8.0--1.8.1.sql pg_fts--1.8.1--1.8.2.sql pg_fts--1.8.2--1.8.3.sql
PGFILEDESC = "pg_fts - full-text search with BM25 ranking"

REGRESS = pg_fts unicode_fold idx_scan_stats legal_proximity
ISOLATION = bm25_concurrency bm25_cic
TAP_TESTS = 1

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

# Vendored sparsemap uses C99 mixed declarations and its own /* FALLTHROUGH */
# comment convention (not recognized by -Wimplicit-fallthrough=5); suppress those
# warnings for it only (public symbols are namespaced to __pg_bm25_* via
# pg_fts_sm.h).
vendor/sm.o: CFLAGS += -Wno-declaration-after-statement -Wno-implicit-fallthrough

# --- Source distribution (PGXN release artifact) ---------------------------
# `make dist` produces pg_fts-$(DISTVERSION).zip in PGXN layout (all files under
# a pg_fts-$(DISTVERSION)/ prefix) straight from the committed tree via
# git archive, so it always matches the tag and never includes build artifacts.
# DISTVERSION is read from META.json (single source of truth).
DISTVERSION = $(shell grep -m1 '"version"' META.json | sed -E 's/.*"version": *"([^"]+)".*/\1/')
DISTNAME = pg_fts-$(DISTVERSION)

.PHONY: dist
dist:
	@test -n "$(DISTVERSION)" || { echo "could not read version from META.json" >&2; exit 1; }
	git archive --format=zip --prefix=$(DISTNAME)/ -o $(DISTNAME).zip HEAD
	@echo "created $(DISTNAME).zip"

# --- Pure-ASCII install SQL guard -------------------------------------------
# A non-ASCII byte anywhere in an install/upgrade .sql (e.g. a UTF-8 default
# like ellipsis '\u2026') makes CREATE EXTENSION FAIL on a non-UTF-8 server
# database (LATIN1, EUC_JP, ...) with "invalid byte sequence for encoding".
# This guard keeps the shipped SQL installable on every server encoding.
# Run standalone (`make check-ascii`); also runnable in CI.
.PHONY: check-ascii
check-ascii:
	@bad=$$(grep -lP '[^\x00-\x7F]' pg_fts--*.sql pg_fts.control 2>/dev/null); \
	if [ -n "$$bad" ]; then \
		echo "ERROR: non-ASCII bytes in install SQL (breaks CREATE EXTENSION on non-UTF-8 servers):" >&2; \
		for f in $$bad; do echo "  $$f:"; grep -nP '[^\x00-\x7F]' "$$f" | head; done >&2; \
		exit 1; \
	fi; \
	echo "install SQL is pure ASCII (installs on any server encoding)"

# Allocation-safety lint: flag any palloc/repalloc sized from a corpus/
# vocabulary-scale quantity that is not huge-safe (the class behind the
# 0.3.4/1.0.1/1.0.2/1.0.3 crashes).  Run standalone (`make check-alloc`); in CI.
.PHONY: check-alloc
check-alloc:
	@bash ci/check-alloc.sh

# --- Rendered HTML docs -----------------------------------------------------
# Render the DocBook fragment doc/pg_fts.sgml to standalone HTML in doc/html/.
# Needs xsltproc + a docbook-xsl-ns stylesheet (auto-detected; override with
# DOCBOOK_XSL=/path/to/html/docbook.xsl). Under Nix use `nix run .#docs-html`.
.PHONY: html
html:
	doc/build-html.sh
