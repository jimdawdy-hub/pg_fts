#!/bin/bash
# usage: setup_host.sh <fts|pgts>
set -euo pipefail
ENG=$1
exec > /tmp/setup.log 2>&1
DEV=$(lsblk -dn -o NAME,SIZE | awk '$2=="884.8G"{print "/dev/"$1; exit}')
sudo mkfs.xfs -f $DEV >/dev/null; sudo mkdir -p /nvme; sudo mount $DEV /nvme; sudo chown ec2-user /nvme
sudo dnf -y -q install gcc make bison flex readline-devel zlib-devel libicu-devel perl bc unzip git python3-pip gdb perf sysstat >/dev/null
pip3 install -q --user pyarrow huggingface_hub
cd /nvme
curl -sfLO https://ftp.postgresql.org/pub/source/v17.10/postgresql-17.10.tar.bz2; tar xjf postgresql-17.10.tar.bz2
cd postgresql-17.10
./configure --prefix=/nvme/pg17 CFLAGS="-O2 -g -fno-omit-frame-pointer" >/nvme/cfg.log 2>&1
make -s -j16 >/nvme/mk.log 2>&1; make -s install >/dev/null; (cd contrib/pg_prewarm && make -s install >/dev/null)
cd /nvme
if [ "$ENG" = fts ]; then
  unzip -qo /tmp/pg_fts-1.8.6.zip; cd pg_fts-1.8.6; make -s PG_CONFIG=/nvme/pg17/bin/pg_config -j16 >/dev/null 2>&1; make -s PG_CONFIG=/nvme/pg17/bin/pg_config install >/dev/null
  md5sum /nvme/pg17/lib/postgresql/pg_fts.so; grep SM_VERSION_STRING vendor/sm.h
else
  git clone -q https://github.com/timescale/pg_textsearch.git; cd pg_textsearch; git checkout -q v1.4.0; git log -1 --format='pgts %h %ad' --date=short
  make -s PG_CONFIG=/nvme/pg17/bin/pg_config -j16 >/dev/null 2>&1; make -s PG_CONFIG=/nvme/pg17/bin/pg_config install >/dev/null
fi
# corpus: first 2,188,038 articles of the pinned HF dataset, id<TAB>title + ' ' + body
cat > /nvme/corpus.py <<'PY'
import sys, os, pyarrow.parquet as pq
from huggingface_hub import list_repo_files, hf_hub_download
REPO="wikimedia/wikipedia"; CONFIG="20231101.en"; N=2188038
files=sorted(f for f in list_repo_files(REPO, repo_type="dataset") if f.startswith(CONFIG+"/") and f.endswith(".parquet"))
out=open("/nvme/c.tsv","w",encoding="utf-8"); n=0
for f in files:
    p=hf_hub_download(REPO, f, repo_type="dataset", cache_dir="/nvme/hf")
    t=pq.read_table(p, columns=["id","title","text"])
    for i,ti,b in zip(t.column("id").to_pylist(), t.column("title").to_pylist(), t.column("text").to_pylist()):
        c=((ti or "")+" "+(b or "")).replace("\t"," ").replace("\n"," ").replace("\r"," ").replace("\\"," ")
        out.write(f"{i}\t{c}\n"); n+=1
        if n==N: break
    os.remove(os.path.realpath(p))
    print(f"{f} -> {n}", file=sys.stderr)
    if n==N: break
out.close(); print("ROWS", n)
PY
python3 /nvme/corpus.py
wc -l /nvme/c.tsv; md5sum /nvme/c.tsv
# cluster
B=/nvme/pg17/bin; $B/initdb -D /nvme/pgdata -U postgres --no-locale -E UTF8 >/dev/null
cat >> /nvme/pgdata/postgresql.conf <<C
listen_addresses=''
unix_socket_directories='/tmp'
max_connections=200
shared_buffers=${SB:-64GB}
maintenance_work_mem=16GB
work_mem=256MB
jit=off
autovacuum=off
max_wal_size=64GB
max_parallel_maintenance_workers=8
max_parallel_workers=16
max_worker_processes=24
shared_preload_libraries='pg_prewarm$( [ "$ENG" = pgts ] && echo ",pg_textsearch")'
C
$B/pg_ctl -D /nvme/pgdata -l /nvme/pgdata/server.log -w start >/dev/null
$B/psql -h /tmp -U postgres -X -q -c "CREATE TABLE docs(id bigint, content text)" -c "\copy docs FROM '/nvme/c.tsv' WITH (FORMAT csv, DELIMITER E'\t', QUOTE E'\b')" -c "SELECT 'rows', count(*) FROM docs"
echo SETUP_DONE
