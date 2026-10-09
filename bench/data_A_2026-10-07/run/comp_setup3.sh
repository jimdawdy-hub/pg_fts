#!/bin/bash
# usage: comp_setup.sh <pgts|psearch|vchord>   (same PG 17.10 source build + corpus as every host)
set -uo pipefail
ENG=$1
exec > /tmp/setup.log 2>&1
DEV=$(lsblk -dn -o NAME,SIZE | awk '$2=="884.8G"{print "/dev/"$1; exit}')
sudo apt-get update -qq; sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq build-essential bison flex libreadline-dev zlib1g-dev libicu-dev pkg-config perl bc unzip git python3-venv sysstat xfsprogs >/dev/null
sudo mkfs.xfs -f $DEV >/dev/null; sudo mkdir -p /nvme; sudo mount $DEV /nvme; sudo chown admin /nvme
python3 -m venv /nvme/venv; /nvme/venv/bin/pip install -q pyarrow huggingface_hub
cd /nvme; curl -sfLO https://ftp.postgresql.org/pub/source/v17.10/postgresql-17.10.tar.bz2; tar xjf postgresql-17.10.tar.bz2
cd postgresql-17.10; ./configure --prefix=/nvme/pg17 CFLAGS="-O2 -g -fno-omit-frame-pointer" >/nvme/cfg.log 2>&1
make -s -j16 >/nvme/mk.log 2>&1; make -s install >/dev/null; (cd contrib/pg_prewarm && make -s install >/dev/null)
echo PG_DONE
LIB=$(/nvme/pg17/bin/pg_config --pkglibdir); SHR=$(/nvme/pg17/bin/pg_config --sharedir)
case $ENG in
  fts)
    # the 1.10.0 release (from its PGXN zip) and the approach-a tree; both .so kept for the A/B
    cd /nvme; unzip -q /tmp/pg_fts-1.10.0.zip; cd pg_fts-1.10.0; make -s PG_CONFIG=/nvme/pg17/bin/pg_config -j16 >/nvme/ext_build_110.log 2>&1; make -s PG_CONFIG=/nvme/pg17/bin/pg_config install >/dev/null 2>&1; cp $LIB/pg_fts.so /nvme/pg_fts_110.so
    cd /nvme; tar xzf /tmp/fts_a.tgz; cd fts_a; make -s PG_CONFIG=/nvme/pg17/bin/pg_config -j16 >/nvme/ext_build_a.log 2>&1; make -s PG_CONFIG=/nvme/pg17/bin/pg_config install >/dev/null 2>&1; cp $LIB/pg_fts.so /nvme/pg_fts_a.so
    (cd /nvme/postgresql-17.10/contrib/pg_buffercache && make -s install >/dev/null)
    md5sum /nvme/pg_fts_110.so /nvme/pg_fts_a.so ;;
  pgts)
    cd /nvme; git clone -q https://github.com/timescale/pg_textsearch.git; cd pg_textsearch; git checkout -q v1.5.1
    echo "pgts $(git describe --tags) $(git log -1 --format=%h)"
    make -s PG_CONFIG=/nvme/pg17/bin/pg_config -j16 >/nvme/ext_build.log 2>&1; make -s PG_CONFIG=/nvme/pg17/bin/pg_config install >/dev/null 2>&1
    ls $LIB | grep -i textsearch ;;
  psearch|vchord)
    if [ $ENG = psearch ]; then
      # pg_search 0.26.0 hard-depends on pgvector and links libopenblas (1.10.0 run: same steps)
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq libopenblas0 >/dev/null
      cd /nvme; git clone -q --branch v0.8.7 https://github.com/pgvector/pgvector.git; cd pgvector
      make -s PG_CONFIG=/nvme/pg17/bin/pg_config -j16 >/nvme/pgvector_build.log 2>&1; make -s PG_CONFIG=/nvme/pg17/bin/pg_config install >/dev/null 2>&1
      echo "pgvector $(git describe --tags)"
    fi
    # official PGDG-layout .debs: unpack and place the payload into THIS PG's dirs
    for d in /tmp/*.deb; do mkdir -p /nvme/deb_$(basename $d .deb); dpkg-deb -x $d /nvme/deb_$(basename $d .deb); dpkg-deb -I $d | grep -E "Package|Version" ; done
    for x in /nvme/deb_*; do
      find $x -name "*.so" -path "*postgresql/17/lib*" -exec cp {} $LIB/ \;
      find $x -path "*postgresql/17/extension/*" -type f -exec cp {} $SHR/extension/ \;
    done
    ls $LIB | grep -iE "pg_search|vchord|tokenizer"; ls $SHR/extension | grep -iE "pg_search|vchord|tokenizer" | head ;;
esac
echo EXT_DONE
sed -n '/^cat > \/nvme\/corpus.py/,/^PY$/p' /tmp/setup_host.sh | sed '1d;$d' > /nvme/corpus.py
/nvme/venv/bin/python /nvme/corpus.py > /nvme/corpus.log 2>&1; md5sum /nvme/c.tsv >> /nvme/corpus.log
echo SETUP_DONE
