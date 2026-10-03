#!/bin/bash
# usage: regress_arm.sh <arm> <port> <tests...>
ARM=$1; PORT=$2; shift 2; B=/nvme/pg$ARM/bin; D=/nvme/rg_$ARM
[ -d $D ] || { $B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null; printf "port=$PORT\nunix_socket_directories='/tmp'\nlisten_addresses=''\nlog_min_messages=info\n" >> $D/postgresql.conf; }
$B/pg_ctl -D $D -l $D/log -w start >/dev/null 2>&1
cd /nvme/fts_$ARM
make -s PG_CONFIG=$B/pg_config installcheck PGHOST=/tmp PGPORT=$PORT PGUSER=postgres REGRESS="$*" 2>&1 | tail -4
$B/pg_ctl -D $D -w stop >/dev/null 2>&1
