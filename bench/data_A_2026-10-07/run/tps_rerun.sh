#!/bin/bash
B=/nvme/pg17/bin; D=/nvme/pgdata; LIB=$($B/pg_config --pkglibdir); P="$B/psql -h /tmp -U postgres -X -q -At"
for arm in ${ARMS:-110 a}; do
  $B/pg_ctl -D $D -w stop >/dev/null 2>&1; cp /nvme/pg_fts_$arm.so $LIB/pg_fts.so; $B/pg_ctl -D $D -l $D/server.log -w start >/dev/null
  $P -c "SELECT indexrelid::regclass FROM pg_index WHERE indrelid='docs'::regclass" | tr '\n' ' '; echo
  bash /tmp/tps2_110.sh fts /nvme/out/tps_settled_${arm}${SUFFIX:-}.txt > /dev/null 2>&1
  echo "arm=$arm"; grep -E "pass=|loadavg" /nvme/out/tps_settled_${arm}${SUFFIX:-}.txt
done
