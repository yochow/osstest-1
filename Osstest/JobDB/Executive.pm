
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

sub begin_work ($$$) { #method
    my ($jd, $dbh,$tables) = @_;
    
    return if $ENV{'OSSTEST_DEBUG_NOSQLLOCK'};
    foreach my $tab (@$tables) {
        $dbh->do("LOCK TABLE $tab IN ACCESS EXCLUSIVE MODE");
    }
}

sub current_flight ($) { #method
    return $ENV{'OSSTEST_FLIGHT'};
}

sub open ($) { #method
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

sub flight_create ($) { #method
    my ($jd) = @_;
    $dbh_tests->do(<<END, {}, $branch, $intended);
             INSERT INTO flights
                         (flight,  started, blessing,       branch, intended)
                  VALUES (DEFAULT, DEFAULT, 'constructing', ?,      ?)
END
    my $fl= $dbh_tests->
        selectrow_array('SELECT MAX(flight) FROM flights');
    return $fl
}

sub job_ensure_started ($) { #method
    my ($jd) = @_;

    my ($count) = $dbh_tests->selectrow_array(<<END,{}, $flight, $job);
            SELECT count(*) FROM jobs WHERE flight=? AND job=?
END
die "$flight.$job $count" unless $count==1;

    $count= $dbh_tests->do(<<END);
           UPDATE flights SET blessing='running'
               WHERE flight=$flight AND blessing='constructing'
END
    logm("starting $flight") if $count>0;

    $count= $dbh_tests->do(<<END);
           UPDATE flights SET started=$now
               WHERE flight=$flight AND started=0
END
    logm("starting $flight started=$now") if $count>0;
}

sub host_check_allocated ($$) { #method
    my ($jd, $ho) = @_;
    $ho->{Shared}= resource_check_allocated('host', $name);
    $ho->{SharedReady}=
        $ho->{Shared} &&
        $ho->{Shared}{State} eq 'ready' &&
        !! grep { $_ eq "share-".$ho->{Shared}{Type} } get_hostflags($ident);
    $ho->{SharedOthers}=
        $ho->{Shared} ? $ho->{Shared}{Others} : 0;
    
    die if $ho->{SharedOthers} && !$ho->{SharedReady};
}

1;
