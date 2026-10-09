#!/bin/bash
ENG=$1
bash /tmp/cluster3.sh $ENG > /tmp/cluster.log 2>&1
cd /tmp; bash /tmp/lat3.sh $ENG /nvme/out > /nvme/lat.log 2>&1
bash /tmp/extra_bands.sh $ENG /nvme/out > /nvme/extra.log 2>&1
echo RUN_DONE >> /nvme/lat.log
