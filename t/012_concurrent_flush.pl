# 012_concurrent_flush.pl -- inserts racing the pending-list flush and tail truncation.
#
# Two defects found by the 1.11.0 release churn gate, both present in every earlier release:
#
#  1. bm25_flush_pending read the pending list under a SHARE lock, folded it, and
#     then emptied the WHOLE list -- every document an inserter appended in
#     between was lost from the index (count below the heap count, rows missing
#     from every scan until REINDEX).
#  2. A merge / VACUUM truncated the index file's free tail under a lock that
#     admits inserters: an inserter's pinned pending page was dropped under it
#     (SIGSEGV in GenericXLogFinish), extensions failed with "unexpected data
#     beyond EOF", scans read past the new end.
#
# and two found while fixing them, hit by readers racing the same maintenance:
#
#  3. bm25_free_page stored the free-time XID in the page's nextblk, so a scan
#     still walking the chain from an older directory snapshot followed the XID
#     as a block number ("could not read blocks N..N", or a live page read as a
#     "corrupt tombstone bitmap").
#  4. bm25_collect_matches freed its tombstone maps twice when the directory
#     generation moved mid-scan (SIGSEGV in sm_contains_many).
#
# pgbench drives 6 concurrent inserting clients (small autocommit batches into
# the pending list) and 2 ranked/count reader clients while a psql session loops
# fts_merge() -- which flushes the pending list and truncates -- with a delete +
# VACUUM every few iterations.  Afterwards the index must agree with the heap
# exactly, and nothing may have errored or crashed.

use strict;
use warnings;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use IPC::Run qw(start finish);

my $node = PostgreSQL::Test::Cluster->new('primary');
$node->init;
$node->append_conf('postgresql.conf', "fsync = off\n");
$node->append_conf('postgresql.conf', "shared_buffers = 32MB\n");
$node->append_conf('postgresql.conf', "maintenance_work_mem = 1MB\n");
$node->append_conf('postgresql.conf', "autovacuum = off\n");
$node->start;

$node->safe_psql('postgres', 'CREATE EXTENSION pg_fts');
$node->safe_psql('postgres', q{
    CREATE TABLE docs (id bigserial PRIMARY KEY, s int, d ftsdoc);
    INSERT INTO docs(s, d)
      SELECT 0, to_ftsdoc('simple', 'anchorterm w' || (g % 50) || ' doc' || g)
      FROM generate_series(1, 2000) g;
    CREATE INDEX docs_fts ON docs USING fts (d);
    VACUUM ANALYZE docs;
});

my $secs = 20;
my $conn = $node->connstr('postgres');

# Maintenance: fts_merge in a loop (each a separate statement and transaction),
# a delete + VACUUM every second iteration, for about as long as pgbench runs.
my $maint = "\\set ON_ERROR_STOP 0\n";
for my $i (1 .. 150) {
    $maint .= "SELECT fts_merge('docs_fts');\nSELECT pg_sleep(0.1);\n";
    $maint .= "INSERT INTO docs(s, d) SELECT 99, to_ftsdoc('simple', 'gone ' || g) FROM generate_series(1, 200) g;\n"
      . "DELETE FROM docs WHERE s = 99;\nVACUUM docs;\n" if $i % 2 == 0;
}
# Concurrent inserters, started first so the maintenance loop below overlaps
# them for its whole run.
my $script = $node->basedir . '/ins.sql';
open(my $fh, '>', $script) or die;
print $fh "INSERT INTO docs(s, d) SELECT 1, to_ftsdoc('simple', 'churnterm w' || ((random() * 50)::int)) FROM generate_series(1, 5) g;\n";
close($fh);
my $rscript = $node->basedir . '/read.sql';
open($fh, '>', $rscript) or die;
print $fh "SELECT count(*) FROM (SELECT id FROM docs WHERE d @@@ 'churnterm'::ftsquery ORDER BY d <=> 'churnterm'::ftsquery LIMIT 10) s;\n"
  . "SELECT count(*) FROM (SELECT id FROM docs WHERE d @@@ 'anchorterm & w5'::ftsquery ORDER BY d <=> 'anchorterm & w5'::ftsquery LIMIT 10) s;\n"
  . "SELECT count(*) FROM docs WHERE d @@@ 'gone | anchorterm'::ftsquery;\n";
close($fh);
my ($bout, $berr) = ('', '');
my $bh = start(['pgbench', '-n', '-c', '6', '-j', '6', '-T', $secs, '-f', $script,
                '-h', $node->host, '-p', $node->port, 'postgres'],
               '>', \$bout, '2>', \$berr);
my ($rout, $rerr) = ('', '');
my $rh = start(['pgbench', '-n', '-c', '2', '-j', '2', '-T', $secs, '-f', $rscript,
                '-h', $node->host, '-p', $node->port, 'postgres'],
               '>', \$rout, '2>', \$rerr);
sleep(1);

# Maintenance in the foreground while pgbench runs.
my ($min, $mout, $merr) = ($maint, '', '');
my $mh = start(['psql', '-X', '-q', '-d', $conn], '<', \$min, '>', \$mout, '2>', \$merr);
finish($mh);
finish($bh);
finish($rh);

my $bench_ok = ($bout =~ /number of failed transactions: 0 / && $berr !~ /error|aborted/i) ? 1 : 0;
diag("pgbench:\n$bout\n$berr") unless $bench_ok;
ok($bench_ok, 'every insert transaction succeeded while flush, merge, VACUUM and truncation ran');
my $read_ok = ($rout =~ /number of transactions actually processed: [1-9]/
               && $rout =~ /number of failed transactions: 0 / && $rerr !~ /error|aborted/i) ? 1 : 0;
diag("reader pgbench:\n$rout\n$rerr") unless $read_ok;
ok($read_ok, 'every concurrent ranked/count read succeeded');
my @merrs = grep { /\bERROR:|FATAL:|server closed/ } split /\n/, $merr;
diag("maintenance errors:\n" . join("\n", @merrs[0 .. ($#merrs < 9 ? $#merrs : 9)])) if @merrs;
is(scalar(@merrs), 0, 'no ERROR in the maintenance session');

my $log = slurp_file($node->logfile);
is(($log =~ /terminated by signal/) ? 1 : 0, 0, 'no backend terminated by a signal');
my $eof = () = ($log =~ /beyond EOF|could not read blocks|previous segment is only|corrupt tombstone/g);
is($eof, 0, 'no beyond-EOF / short-read / stale-chain errors in the server log');

# Every inserted row must be in the index.
$node->safe_psql('postgres', q{SELECT fts_merge('docs_fts')});
my $heap = $node->safe_psql('postgres',
    q{SELECT count(*) FROM docs WHERE fts_match(d, 'churnterm'::ftsquery)});
my $pushdown = $node->safe_psql('postgres',
    q{SELECT count(*) FROM docs WHERE d @@@ 'churnterm'::ftsquery});
my $bitmap = $node->safe_psql('postgres',
    q{SET enable_seqscan = off; SET enable_indexscan = off;
      SELECT count(*) FROM (SELECT id FROM docs WHERE d @@@ 'churnterm'::ftsquery OFFSET 0) s});
ok($heap > 1000, "inserters wrote rows ($heap)");
is($pushdown, $heap, 'count(*) pushdown == heap count after the race');
is($bitmap, $heap, 'bitmap scan row count == heap count after the race');
is($node->safe_psql('postgres', q{SELECT count(*) FROM docs WHERE d @@@ 'anchorterm'::ftsquery}),
   2000, 'pre-existing rows still exact');
is($node->safe_psql('postgres', q{SELECT count(*) FROM docs WHERE d @@@ 'gone'::ftsquery}),
   0, 'deleted rows are not in the index');

$node->stop;
done_testing();
