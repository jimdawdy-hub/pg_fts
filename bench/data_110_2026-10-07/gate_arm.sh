#!/bin/bash
cd /nvme; [ -d fts_gate ] && mv fts_gate fts_gate.old.$$; tar xzf /tmp/fts_gate.tgz; cd fts_gate; tar xzf /tmp/fts_ci.tgz
B=/nvme/pg17/bin
echo "== tree: $(grep default_version pg_fts.control) shdoclen=$(md5sum < pg_fts_shdoclen.c | cut -c1-8)"
echo "== fuzz"; bash test/fuzz/run.sh 2>&1 | grep -E "^PASS|^FAIL|ALL CLEAN" | tail -12
echo "== build"; make -s PG_CONFIG=$B/pg_config clean >/dev/null 2>&1; make -s PG_CONFIG=$B/pg_config -j16 2>&1 | grep -cE "warning:|error:"; make -s PG_CONFIG=$B/pg_config install >/dev/null 2>&1
$B/pg_ctl -D /nvme/rg -l /nvme/rg/log -w restart >/dev/null 2>&1 || $B/pg_ctl -D /nvme/rg -l /nvme/rg/log -w start >/dev/null 2>&1
echo "== regress+isolation"; make PG_CONFIG=$B/pg_config installcheck PGHOST=/tmp PGPORT=55432 PGUSER=postgres 2>&1 | grep -E "^(ok|not ok)" | awk '{print $1,$2,$4}' | tr '\n' ';'; echo
echo "== tap (all t/*)"; make PG_CONFIG=$B/pg_config installcheck REGRESS= ISOLATION= 2>&1 | grep -E "^t/.*(ok|FAIL|Dubious)|^Result|^Files=" | tail -14
$B/pg_ctl -D /nvme/rg -w stop >/dev/null 2>&1
echo "== coverage"; PG_CONFIG=$B/pg_config PGBIN=$B bash ci/coverage.sh 2>&1 | grep -E "PASS|FAIL|coverage" | tail -6
