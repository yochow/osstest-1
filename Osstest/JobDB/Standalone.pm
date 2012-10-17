
package Osstest::JobDB::Standalone;

use strict;
use warnings;

use Osstest;
use Osstest::TestSupport;

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

sub jobdb_resource_shared_mark_ready { } #method

sub jobdb_check_other_job { } #method

sub jobdb_flight_started_for_log_capture ($$) { #method
    my ($mo, $flight) = @_;
    return time - 1; # just the most recent serial log then
}

1;
