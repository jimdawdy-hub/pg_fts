# meson.build for pg_fts (Windows / MSVC out-of-tree build)
#
# The primary build path is the PGXS Makefile (Linux, macOS, *BSD).  This
# meson recipe exists only for Windows/MSVC, where PostgreSQL itself is built
# with meson and PGXS is unavailable.
#
# PREREQUISITE: an MSVC-built PostgreSQL >= 17 built from source with the same
# Visual Studio toolchain (`meson setup ... && ninja install`).  A
# MinGW/Strawberry PostgreSQL will NOT work: it ships a GCC-flavored pg_config.h
# (HAVE_STRINGS_H=1, PG_INT128_TYPE=__int128) that MSVC cannot consume, and no
# postgres.lib backend import library to link against.  The pg_fts C sources are
# MSVC-clean (vendored sparsemap carries full _MSC_VER shims, including
# _M_ARM64).  Validated on Windows 11 ARM64 (x64-emulated cl) under both VS2022
# (cl 19.44) and VS2026-preview (cl 19.50): builds clean and @@@/<=>/fts_count
# pass against a from-source MSVC PostgreSQL 17.10.
#
# Build (from an "x64 Native Tools" prompt, or after vcvars64.bat):
#   meson setup build -Dpg_dir=C:/pgsql --buildtype=release
#   ninja -C build
#   ninja -C build install   # pg_fts.dll -> <pg>/lib, .control/.sql -> share/extension
#
# Note: build recipe only; the regress/isolation/TAP harness on Windows is
# separate PGXS-style plumbing, add when installcheck actually runs on Windows.

project('pg_fts', 'c',
  version: '1.9.0',
  default_options: ['c_std=c11', 'warning_level=2'])

fs = import('fs')
pg_dir = get_option('pg_dir')            # e.g. C:/pgsql (MSVC-built PG >= 17)

# A meson/nixpkgs-built PostgreSQL installs headers under
# include/postgresql/server and extension files under share/postgresql/extension;
# the older/MSVC layout uses include/server and share/extension.  Detect which.
if fs.is_dir(pg_dir / 'include' / 'postgresql' / 'server')
  pg_include_server = pg_dir / 'include' / 'postgresql' / 'server'
  pg_extension_dir  = pg_dir / 'share' / 'postgresql' / 'extension'
else
  pg_include_server = pg_dir / 'include' / 'server'
  pg_extension_dir  = pg_dir / 'share' / 'extension'
endif
pg_lib = pg_dir / 'lib'

cc = meson.get_compiler('c')

# The backend import library.  An MSVC PG build ships postgres.lib here.
postgres_lib = cc.find_library('postgres', dirs: [pg_lib], required: true)

incdirs = include_directories(
  pg_include_server,                     # <postgres.h>, fmgr.h, ...
  pg_include_server / 'port' / 'win32',  # win32 port shims
  pg_include_server / 'port' / 'win32_msvc',
  pg_dir / 'include',
)

# Mirrors the Makefile OBJS list.  pg_fts_am_scan.c, pg_fts_lev.c and
# pg_fts_trgm_index.c are #included into pg_fts_am.c (not separate TUs), so they
# are intentionally NOT listed here.
sources = files(
  'pg_fts_analyze.c',
  'pg_fts_tsanalyze.c',
  'pg_fts_doc.c',
  'pg_fts_query.c',
  'pg_fts_rank.c',
  'pg_fts_am.c',
  'pg_fts_customscan.c',
  'pg_fts_aux.c',
  'pg_fts_migrate.c',
  'pg_fts_trgm.c',
  'pg_fts_match.c',
  'vendor/sm.c',                         # already carries full _MSC_VER shims
)

# -DWIN32 + the CRT quiet macro; /wd4267 /wd4244 silence the size_t/__int64 ->
# int narrowing warnings exactly as PostgreSQL's own build suppresses them (they
# also bleed out of PG's headers, so suppressing here quiets both).
c_args = [
  '-DWIN32',
  '-D_CRT_SECURE_NO_WARNINGS',
  '/wd4267',
  '/wd4244',
]

pg_fts = shared_module('pg_fts',
  sources,
  include_directories: incdirs,
  dependencies: [postgres_lib],
  c_args: c_args,
  name_prefix: '',                       # -> pg_fts.dll, not libpg_fts.dll
  install: true,
  install_dir: pg_lib,
)

# Control + SQL script into the extension dir (layout auto-detected above).
# Install script + upgrades for the 1.0.0 release (the private incremental upgrade
# series was collapsed).
install_data('pg_fts.control', install_dir: pg_extension_dir)
install_data('pg_fts--1.9.0.sql', install_dir: pg_extension_dir)
install_data('pg_fts--0.2.0--0.2.1.sql', install_dir: pg_extension_dir)
install_data('pg_fts--0.2.1--0.2.2.sql', install_dir: pg_extension_dir)
install_data('pg_fts--0.2.2--0.2.3.sql', install_dir: pg_extension_dir)
install_data('pg_fts--0.2.3--0.2.4.sql', install_dir: pg_extension_dir)
install_data('pg_fts--0.2.4--0.3.0.sql', install_dir: pg_extension_dir)
install_data('pg_fts--0.3.0--0.3.1.sql', install_dir: pg_extension_dir)
install_data('pg_fts--0.3.1--0.3.2.sql', install_dir: pg_extension_dir)
install_data('pg_fts--0.3.2--0.3.3.sql', install_dir: pg_extension_dir)
install_data('pg_fts--0.3.3--0.3.4.sql', install_dir: pg_extension_dir)
install_data('pg_fts--0.3.4--0.3.5.sql', install_dir: pg_extension_dir)
install_data('pg_fts--0.3.5--0.3.6.sql', install_dir: pg_extension_dir)
install_data('pg_fts--0.3.6--1.0.0.sql', install_dir: pg_extension_dir)
install_data('pg_fts--1.0.0--1.0.1.sql', install_dir: pg_extension_dir)
install_data('pg_fts--1.0.1--1.0.2.sql', install_dir: pg_extension_dir)
install_data('pg_fts--1.0.2--1.0.3.sql', install_dir: pg_extension_dir)
install_data('pg_fts--1.0.3--1.0.4.sql', install_dir: pg_extension_dir)
install_data('pg_fts--1.0.4--1.0.5.sql', install_dir: pg_extension_dir)
install_data('pg_fts--1.0.5--1.0.6.sql', install_dir: pg_extension_dir)
install_data('pg_fts--1.0.6--1.0.7.sql', install_dir: pg_extension_dir)
install_data('pg_fts--1.0.7--1.0.8.sql', install_dir: pg_extension_dir)
install_data('pg_fts--1.0.8--1.1.0.sql', install_dir: pg_extension_dir)
install_data('pg_fts--1.1.0--1.1.1.sql', install_dir: pg_extension_dir)
install_data('pg_fts--1.1.1--1.1.2.sql', install_dir: pg_extension_dir)
install_data('pg_fts--1.1.2--1.1.3.sql', install_dir: pg_extension_dir)
install_data('pg_fts--1.1.3--1.1.4.sql', install_dir: pg_extension_dir)
install_data('pg_fts--1.1.4--1.1.5.sql', install_dir: pg_extension_dir)
install_data('pg_fts--1.1.5--1.1.6.sql', install_dir: pg_extension_dir)
install_data('pg_fts--1.1.6--1.1.7.sql', install_dir: pg_extension_dir)
install_data('pg_fts--1.1.7--1.2.0.sql', install_dir: pg_extension_dir)
install_data('pg_fts--1.2.0--1.2.1.sql', install_dir: pg_extension_dir)
install_data('pg_fts--1.2.1--1.2.2.sql', install_dir: pg_extension_dir)
install_data('pg_fts--1.2.2--1.3.0.sql', install_dir: pg_extension_dir)
install_data('pg_fts--1.3.0--1.3.1.sql', install_dir: pg_extension_dir)
install_data('pg_fts--1.3.1--1.3.2.sql', install_dir: pg_extension_dir)
install_data('pg_fts--1.3.2--1.4.0.sql', install_dir: pg_extension_dir)
install_data('pg_fts--1.4.0--1.4.1.sql', install_dir: pg_extension_dir)
install_data('pg_fts--1.4.1--1.5.0.sql', install_dir: pg_extension_dir)
install_data('pg_fts--1.5.0--1.5.1.sql', install_dir: pg_extension_dir)
install_data('pg_fts--1.5.1--1.5.2.sql', install_dir: pg_extension_dir)
install_data('pg_fts--1.5.2--1.5.3.sql', install_dir: pg_extension_dir)
install_data('pg_fts--1.5.3--1.5.4.sql', install_dir: pg_extension_dir)
install_data('pg_fts--1.5.4--1.5.5.sql', install_dir: pg_extension_dir)
install_data('pg_fts--1.5.5--1.5.6.sql', install_dir: pg_extension_dir)
install_data('pg_fts--1.5.6--1.5.7.sql', install_dir: pg_extension_dir)
install_data('pg_fts--1.5.7--1.5.8.sql', install_dir: pg_extension_dir)
install_data('pg_fts--1.5.8--1.5.9.sql', install_dir: pg_extension_dir)
install_data('pg_fts--1.5.9--1.5.10.sql', install_dir: pg_extension_dir)
install_data('pg_fts--1.5.10--1.6.0.sql', install_dir: pg_extension_dir)
install_data('pg_fts--1.6.0--1.6.1.sql', install_dir: pg_extension_dir)
install_data('pg_fts--1.6.1--1.7.0.sql', install_dir: pg_extension_dir)
install_data('pg_fts--1.7.0--1.7.1.sql', install_dir: pg_extension_dir)
install_data('pg_fts--1.7.1--1.7.2.sql', install_dir: pg_extension_dir)
install_data('pg_fts--1.7.2--1.8.0.sql', install_dir: pg_extension_dir)
install_data('pg_fts--1.8.0--1.8.1.sql', install_dir: pg_extension_dir)
install_data('pg_fts--1.8.1--1.8.2.sql', install_dir: pg_extension_dir)
install_data('pg_fts--1.8.2--1.8.3.sql', install_dir: pg_extension_dir)
install_data('pg_fts--1.8.3--1.8.4.sql', install_dir: pg_extension_dir)
install_data('pg_fts--1.8.4--1.8.5.sql', install_dir: pg_extension_dir)
install_data('pg_fts--1.8.5--1.8.6.sql', install_dir: pg_extension_dir)
install_data('pg_fts--1.8.6--1.9.0.sql', install_dir: pg_extension_dir)
