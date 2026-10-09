#!/bin/bash
ulimit -c unlimited
sudo sysctl -q kernel.core_pattern=/nvme/cores/core.%p
mkdir -p /nvme/cores; chmod 777 /nvme/cores; mv /nvme/cores /nvme/cores.old.$$; mkdir -p /nvme/cores; chmod 777 /nvme/cores
cd /nvme/pg_fts-1.10.0 && make -s PG_CONFIG=/nvme/pg17/bin/pg_config install >/dev/null 2>&1
echo "so $(md5sum /nvme/pg17/lib/postgresql/pg_fts.so | cut -c1-8)"
for try in 1 2 3; do
  ( ulimit -v 16000000; DUR=40 bash /tmp/race.sh r110_$try ) 2>&1 | tail -1
  echo "  try $try: crashes=$(grep -c 'terminated by signal' /nvme/race_r110_$try/log) $(grep 'terminated by signal' /nvme/race_r110_$try/log | head -1 | sed 's/.*terminated/terminated/')"
  /nvme/pg17/bin/pg_ctl -D /nvme/race_r110_$try -m immediate -w stop >/dev/null 2>&1
done
for c in /nvme/cores/core.*; do [ -f "$c" ] || continue; echo "== $c"; gdb -q -batch -ex "bt 6" /nvme/pg17/bin/postgres "$c" 2>&1 | grep -E "^#" | head -6 | cut -c1-160; done
