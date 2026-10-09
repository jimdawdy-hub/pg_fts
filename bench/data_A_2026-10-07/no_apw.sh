#!/bin/bash
B=/nvme/pgs/bin; P="$B/psql -h /tmp -p 55440 -U postgres -X -q -At"
$P -c "ALTER SYSTEM SET pg_prewarm.autoprewarm = off" >/dev/null
$B/pg_ctl -D /nvme/bench_s -w restart -l /nvme/bench_s/server.log >/dev/null
[ -f /nvme/bench_s/autoprewarm.blocks ] && mv /nvme/bench_s/autoprewarm.blocks /nvme/autoprewarm.blocks.saved
echo "autoprewarm=$($P -c "SHOW pg_prewarm.autoprewarm")"
