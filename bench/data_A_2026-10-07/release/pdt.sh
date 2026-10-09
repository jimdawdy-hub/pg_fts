#!/bin/bash
# run sql/pending_delete.sql against a binary; print the result rows
set -uo pipefail
W=/tmp/upq111; B=$W/$1/bin
D=$W/pdt_$1; [ -d $D ] && mv $D $D.old.$$
$B/initdb -D $D -U postgres --no-locale -E UTF8 >/dev/null 2>&1
printf "port=55455\nunix_socket_directories='/tmp'\nlisten_addresses=''\n" >> $D/postgresql.conf
$B/pg_ctl -D $D -l $D/log -w start >/dev/null
P="$B/psql -h /tmp -p 55455 -U postgres -X -q"
$P -c "CREATE EXTENSION pg_fts" >/dev/null
$P -a -f /home/gburd/ws/pg_fts/sql/pending_delete.sql > $W/pending_delete_$1.out 2>&1
$B/pg_ctl -D $D -w stop >/dev/null
echo "== $1 ($(md5sum $W/$1/lib/postgresql/pg_fts.so | cut -c1-8))"; grep -A3 -E "truth|bitmap_rows|ranked_rows" $W/pending_delete_$1.out | grep -E "^ +[0-9]" ; grep ERROR $W/pending_delete_$1.out | head -3
