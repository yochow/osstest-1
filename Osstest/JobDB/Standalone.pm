
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

sub new { return bless {}, $_[0]; };

sub begin_work { }
sub dbfl_check { }

sub open ($) {
    my $dbfn = $c{'job-db-standalone-filename'} || "standalone.db";
    my $dbi = $c{'job-db-standalone-ds'} || "dbi:SQLite:dbname=".$dbfn;
    
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

1;
