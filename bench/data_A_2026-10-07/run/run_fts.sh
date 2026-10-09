#!/bin/bash
bash /tmp/cluster3.sh fts > /tmp/cluster.log 2>&1
cd /tmp; bash /tmp/fts_ab.sh /nvme/out > /nvme/fts_ab.log 2>&1
echo RUN_DONE >> /nvme/fts_ab.log
