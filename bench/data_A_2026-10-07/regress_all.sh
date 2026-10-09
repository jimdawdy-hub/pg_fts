#!/bin/bash
cd /nvme/fts_a; B=/nvme/pg17/bin
make -s PG_CONFIG=$B/pg_config -j16 >/dev/null 2>&1 && make -s PG_CONFIG=$B/pg_config install >/dev/null 2>&1
$B/pg_ctl -D /nvme/rg -l /nvme/rg/log -w restart >/dev/null 2>&1
echo "so=$(md5sum $($B/pg_config --pkglibdir)/pg_fts.so | cut -c1-8)"
make PG_CONFIG=$B/pg_config installcheck PGHOST=/tmp PGPORT=55432 PGUSER=postgres PROVE_TESTS=ci/noop.pl 2>&1 | grep -E "^(ok|not ok)|tests passed|failed|isolation" | head -30
