
package Osstest::JobDB::Executive;

use strict;
use warnings;

use Osstest::Executive;

BEGIN {
    use Exporter ();
    our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
    $VERSION     = 1.00;
    @ISA         = qw(Exporter);
    @EXPORT      = qw();
    %EXPORT_TAGS = ( );

    @EXPORT_OK   = qw();
}

sub new { return bless {}, Osstest::JobDB::Standalone };

sub begin_work ($$) {
    my ($dbh,$tables) = @_;
    
    return if $ENV{'OSSTEST_DEBUG_NOSQLLOCK'};
    foreach my $tab (@$tables) {
        $dbh->do("LOCK TABLE $tab IN ACCESS EXCLUSIVE MODE");
    }
}

sub open () {
    return opendb('osstestdb');
}

sub dbfl_check ($$) {
    my ($fl,$flok) = @_;
    # must be inside db_retry qw(flights)

    if (!ref $flok) {
        $flok= [ split /,/, $flok ];
    }
    die unless ref($flok) eq 'ARRAY';

    my ($bless) = $dbh_tests->selectrow_array(<<END, {}, $fl);
        SELECT blessing FROM flights WHERE flight=?
END

    die "modifying flight $fl but flight not found\n"
        unless defined $bless;
    return if $bless =~ m/\bplay\b/;
    die "modifying flight $fl blessing $bless expected @$flok\n"
        unless grep { $_ eq $bless } @$flok;

    my $rev = get_harness_rev();

    my $already= $dbh_tests->selectrow_hashref(<<END, {}, $fl,$rev);
        SELECT * FROM flights_harness_touched WHERE flight=? AND harness=?
END

    if (!$already) {
        $dbh_tests->do(<<END, {}, $fl,$rev);
            INSERT INTO flights_harness_touched VALUES (?,?)
END
    }
}

sub flight_create () {
    $dbh_tests->do(<<END, {}, $branch, $intended);
             INSERT INTO flights
                         (flight,  started, blessing,       branch, intended)
                  VALUES (DEFAULT, DEFAULT, 'constructing', ?,      ?)
END
    my $fl= $dbh_tests->
        selectrow_array('SELECT MAX(flight) FROM flights');
    return $fl
}
