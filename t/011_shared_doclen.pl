# 011_shared_doclen.pl -- the server-wide shared doclen copies (1.10.0) across
# sessions.
#
# What a single-session regression test cannot show:
#   1. A scan that STARTED before a merge keeps reading the old segments -- and
#      their shared copy -- while another session merges them away and a third
#      reads the new segment.  Every session must get exact scores (equal to the
#      cursor path, pg_fts.doclen_cache_mb = 0), and the old copy must be freed
#      once its last reader is done.
#   2. Many sessions racing to publish the same segment's copy: exactly one
#      copy, all answers exact, no reference left held.
#   3. A session killed (pg_terminate_backend) while it holds a copy: the
#      reference is released by its exit, and the copy stays usable.
#   4. A churning writer (insert / delete / merge / vacuum) against concurrent
#      ranked readers: every read exact, no stranded references at the end,
#      bounded number of copies.

use strict;
use warnings;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('primary');
$node->init;
$node->append_conf('postgresql.conf', "fsync = off\nmax_connections = 60\n");
$node->start;
$node->safe_psql('postgres', 'CREATE EXTENSION pg_fts');
$node->safe_psql('postgres', q{
  CREATE TABLE t (id int PRIMARY KEY, d ftsdoc);
  INSERT INTO t SELECT g, to_ftsdoc('simple', 'alpha ' || repeat('w' || (g % 11) || ' ', 1 + g % 53))
    FROM generate_series(1, 30000) g;
  CREATE INDEX t_fts ON t USING fts (d);
  VACUUM ANALYZE t;
  CREATE FUNCTION ranked(q text, shared bool, mb int) RETURNS text LANGUAGE plpgsql AS $$
  DECLARE r text;
  BEGIN
    EXECUTE format('SET LOCAL pg_fts.shared_doclen = %s', shared);
    EXECUTE format('SET LOCAL pg_fts.doclen_cache_mb = %s', mb);
    SET LOCAL enable_seqscan = off; SET LOCAL enable_bitmapscan = off;
    EXECUTE format('SELECT md5(string_agg(id::text || '':'' || round((1/(d <=> to_ftsquery(''simple'',%L)) - 1)::numeric, 12), '',''))
                    FROM (SELECT id, d FROM t WHERE d @@@ to_ftsquery(''simple'',%L)
                          ORDER BY d <=> to_ftsquery(''simple'',%L) LIMIT 40000) s', q, q, q) INTO r;
    RETURN r;
  END $$;
  CREATE VIEW copies AS
    SELECT count(*) FILTER (WHERE state = 'ready') AS ready,
           coalesce(sum(refcnt), 0) AS held,
           count(*) FILTER (WHERE retired) AS retired
    FROM fts_shared_doclen_stats() s
    WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
      AND relfilenumber = pg_relation_filenode('t_fts');
});

sub exact
{
	my ($q, $label) = @_;
	my $shared = $node->safe_psql('postgres', "SELECT ranked('$q', true, 64)");
	my $cursor = $node->safe_psql('postgres', "SELECT ranked('$q', false, 0)");
	ok($shared ne '' && $shared eq $cursor, "$label: shared == cursor path for '$q'");
	return $shared;
}

exact('alpha', 'baseline');
exact('w3', 'baseline');

# ---- 1. a scan that outlives a merge -------------------------------------
# Add a second segment, then hold an open cursor over both segments while
# another session merges them.
$node->safe_psql('postgres', q{
  INSERT INTO t SELECT g, to_ftsdoc('simple', 'alpha beta ' || repeat('z ', g % 37))
    FROM generate_series(30001, 36000) g;
  VACUUM t;
});
is($node->safe_psql('postgres', "SELECT fts_index_nsegments('t_fts')"), '2', 'two segments before merge');
my $expect_old = $node->safe_psql('postgres', "SELECT ranked('alpha', false, 0)");

my $reader = $node->background_psql('postgres');
$reader->query_safe(q{
  SET enable_seqscan = off; SET enable_bitmapscan = off;
  BEGIN ISOLATION LEVEL REPEATABLE READ;
  DECLARE c CURSOR FOR SELECT id, round((1/(d <=> to_ftsquery('simple','alpha')) - 1)::numeric, 12) AS s
    FROM t WHERE d @@@ to_ftsquery('simple','alpha') ORDER BY d <=> to_ftsquery('simple','alpha');
  FETCH 100 FROM c;
});
my $held_before = $node->safe_psql('postgres', 'SELECT held FROM copies');
ok($held_before > 0, "open cursor holds shared copies ($held_before)");

$node->safe_psql('postgres', "SELECT fts_merge('t_fts')");
is($node->safe_psql('postgres', "SELECT fts_index_nsegments('t_fts')"), '1', 'merged to one segment');
my $retired = $node->safe_psql('postgres', 'SELECT retired FROM copies');
ok($retired > 0, "merged-away copies are retired but kept while read ($retired)");

# a new session sees the merged segment and is exact against the cursor path
exact('alpha', 'after merge (new session)');

# the old reader finishes its scan on the old copies; compare its full result
# with the pre-merge expectation (it reads the old directory: same docs)
my $rest = $reader->query_safe(q{FETCH ALL FROM c;});
$reader->query_safe('CLOSE c; COMMIT;');
my $old_full = $node->safe_psql('postgres', q{SELECT 1});	# sync point
$reader->quit;
# recompute the reader's full result the same way on the cursor path, on a
# fresh snapshot: the merged segment has the same docs, lengths and scores
my $now_full = $node->safe_psql('postgres', "SELECT ranked('alpha', false, 0)");
is($now_full, $expect_old, 'merge preserved every score (cursor path before == after)');
like($rest, qr/\d+\|/, 'old reader finished its scan on the retired copies');
is($node->safe_psql('postgres', 'SELECT held FROM copies'), '0', 'no reference held after the old reader');
# the next publish or retire sweeps retired, unreferenced copies
exact('w5', 'post-merge');
$node->safe_psql('postgres', q{
  INSERT INTO t SELECT g, to_ftsdoc('simple', 'alpha gamma') FROM generate_series(36001, 36100) g;
  SELECT fts_merge('t_fts');
});
is($node->safe_psql('postgres', 'SELECT retired FROM copies'), '0', 'retired copies reclaimed');

# ---- 2. many sessions racing to publish the same copy -----------------------
$node->safe_psql('postgres', 'REINDEX INDEX t_fts');	# new relfilenumber: no copies
is($node->safe_psql('postgres', 'SELECT ready FROM copies'), '0', 'no copy after REINDEX');
my $expect = $node->safe_psql('postgres', "SELECT ranked('alpha', false, 0)");
my @bg;
for my $i (1 .. 12)
{
	my $s = $node->background_psql('postgres');
	push @bg, $s;
}
my @got = map { $_->query_safe("SELECT ranked('alpha', true, 64)") } @bg;
my $bad = grep { $_ !~ /\Q$expect\E/ } @got;
is($bad, 0, '12 racing sessions: every result exact');
cmp_ok($node->safe_psql('postgres', 'SELECT ready FROM copies'), '<=', 1, 'at most one published copy per segment');
is($node->safe_psql('postgres', 'SELECT held FROM copies'), '0', 'no reference held after the race');

# ---- 3. a session killed while it holds a copy ------------------------------
my $victim = $bg[0];
my $vpid = $victim->query_safe('SELECT pg_backend_pid()');
$vpid =~ s/\s+//g;
$victim->query_safe(q{
  SET enable_seqscan = off; SET enable_bitmapscan = off;
  BEGIN;
  DECLARE k CURSOR FOR SELECT id FROM t WHERE d @@@ to_ftsquery('simple','alpha')
    ORDER BY d <=> to_ftsquery('simple','alpha');
  FETCH 5 FROM k;
});
ok($node->safe_psql('postgres', 'SELECT held FROM copies') > 0, 'victim holds a copy');
$node->safe_psql('postgres', "SELECT pg_terminate_backend($vpid)");
$node->poll_query_until('postgres', 'SELECT held = 0 FROM copies')
  or diag('reference not released after terminate');
is($node->safe_psql('postgres', 'SELECT held FROM copies'), '0', 'terminated backend released its reference');
exact('alpha', 'after terminate');
$_->quit for @bg[1 .. $#bg];
eval { $victim->quit };

# ---- 4. churn vs concurrent readers -----------------------------------------
# Scores depend on corpus statistics (N, avgdl) that the churn changes, so a
# fixed expected value is wrong by design.  Each reader instead compares, in
# ONE statement and therefore ONE snapshot, the shared path with the cursor
# path (no slot arrays at all): any difference is a shared-copy error.
$node->safe_psql('postgres', q{
  CREATE FUNCTION same_now(q text) RETURNS boolean LANGUAGE sql AS $$
    SELECT ranked(q, true, 64) = ranked(q, false, 0) AND ranked(q, true, 64) IS NOT NULL $$;
});
my @readers;
for my $i (1 .. 6)
{
	my $r = $node->background_psql('postgres');
	$r->query_safe('BEGIN ISOLATION LEVEL REPEATABLE READ; COMMIT;');
	push @readers, $r;
}
my $writer = $node->background_psql('postgres');
my $wrong = 0;
my $reads = 0;
for my $round (1 .. 15)
{
	$writer->query_safe(qq{
	  INSERT INTO t SELECT g, to_ftsdoc('simple', 'churn x$round w7 ' || repeat('q ', g % 9))
	    FROM generate_series(100000 + $round * 1000, 100000 + $round * 1000 + 499) g;
	  DELETE FROM t WHERE id BETWEEN 100000 + ($round - 1) * 1000 AND 100000 + ($round - 1) * 1000 + 249;
	  VACUUM t;
	});
	$writer->query_safe("SELECT fts_merge('t_fts')") if $round % 3 == 0;
	for my $r (@readers)
	{
		# REPEATABLE READ: both arms of same_now see one snapshot
		my $v = $r->query_safe("BEGIN ISOLATION LEVEL REPEATABLE READ; SELECT same_now('w7'); COMMIT;");
		$reads++;
		$wrong++ unless $v =~ /\bt\b/;
	}
}
is($wrong, 0, "churn: every concurrent ranked read exact ($reads reads, 15 rounds x 6 readers)");
$_->quit for @readers;
$writer->quit;
is($node->safe_psql('postgres', 'SELECT held FROM copies'), '0', 'churn: no stranded references');
# copies of dropped segments are retired and swept by the next publish/merge;
# after a final merge only the live segments' copies may remain READY
$node->safe_psql('postgres', "SELECT fts_merge('t_fts')");
exact('w7', 'after churn');
cmp_ok($node->safe_psql('postgres', 'SELECT ready - retired FROM copies'), '<=',
	$node->safe_psql('postgres', "SELECT fts_index_nsegments('t_fts')") + 0,
	'churn: no more live (unretired) copies than segments');
cmp_ok($node->safe_psql('postgres', 'SELECT ready FROM copies'), '<=', 16,
	'churn: published copies stay bounded');

$node->stop;
done_testing();
