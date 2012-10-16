
package Osstest::JobDB::Standalone;

use strict;
use warnings;

use Osstest;

BEGIN {
    use Exporter ();
    our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
    $VERSION     = 1.00;
    @ISA         = qw(Exporter);
    @EXPORT      = qw();
    %EXPORT_TAGS = ( );

    @EXPORT_OK   = qw();
}

augmentconfigdefaults(
    JobDBStandaloneFilename => 'standalone.db',
);

sub new { return bless {}, $_[0]; };

sub begin_work { }
sub dbfl_check { }

sub open ($) {
    my $dbi = "dbi:SQLite:dbname=$c{JobDBStandaloneFilename}";
    
    my $dbh= DBI->connect($dbi, '','', {
        AutoCommit => 1,
        RaiseError => 1,
        ShowErrorStatement => 1,
        })
        or die "could not open standalone db $dbi";
    return $dbh;
}

sub flight_create ($$$) {
    my ($obj, $branch, $intended) = @_;
    my $fl = $ENV{'OSSTEST_FLIGHT'};
    die "flight names may not contain ." if $fl =~ m/\./;
    $fl = 'standalone' if !length $fl;
    foreach my $table (qw(runvars jobs flights)) {
	$dbh_tests->do(<<END, {}, $fl)
	     DELETE FROM $table WHERE flight = ?
END
    }
    $dbh_tests->do(<<END, {}, $fl, $branch, $intended);
             INSERT INTO flights
                         (flight, branch, intended)
                  VALUES (?, ?, ?)
END
    return $fl
}

sub current_flight ($) {
    return $ENV{'OSSTEST_FLIGHT'} || 'standalone';
}

sub job_ensure_started ($) { }

sub host_check_allocated ($$) { #method
    my ($jd, $ho) = @_;

    if ($ENV{'OSSTEST_HOST_REUSE'}) {
	logm("OSSTEST_HOST_REUSE");
	$ho->{SharedReady}= 1;
    }
}

sub jobdb_postfork ($) { }

sub gen_ether_offset ($$) { #method
    my ($mo,$ho,$fl) = @_;
    return $< & 0xffff;
}
sub jobdb_resource_shared_mark_ready { }


1;
