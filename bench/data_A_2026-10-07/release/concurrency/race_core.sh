#!/bin/bash
# reproduce the segfault with core dumps enabled; print the backtrace
sudo sysctl -q kernel.core_pattern=/nvme/cores/core.%p
mkdir -p /nvme/cores; chmod 777 /nvme/cores
ulimit -c unlimited
cd /nvme/fts_gate && make -s PG_CONFIG=/nvme/pg17/bin/pg_config install >/dev/null 2>&1
for try in 1 2 3; do
  DUR=60 bash /tmp/race.sh core$try 2>&1 | tail -1
  c=$(ls -t /nvme/cores/core.* 2>/dev/null | head -1)
  if [ -n "$c" ]; then echo "core: $c"; gdb -q -batch -ex bt /nvme/pg17/bin/postgres "$c" 2>&1 | grep -E "^#" | head -25; break; fi
done
