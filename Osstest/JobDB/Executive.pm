# This is part of "osstest", an automated testing framework for Xen.
# Copyright (C) 2009-2013 Citrix Inc.
# 
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
# 
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.


package Osstest::JobDB::Executive;

use strict;
use warnings;

use Osstest;
use Osstest::TestSupport;
use Osstest::Executive;

BEGIN {
    use Exporter ();
    our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
    $VERSION     = 1.00;
    @ISA         = qw(Exporter);
    @EXPORT      = qw(dbfl_check);
    %EXPORT_TAGS = ( );

    @EXPORT_OK   = qw();
}

sub new { return bless {}, $_[0] };

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

sub flight_create ($$$) { #method
    my ($jd,$intended,$branch) = @_;
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
    my $now = time;

    $count= $dbh_tests->do(<<END);
           UPDATE flights SET started=$now
               WHERE flight=$flight AND started=0
END
    logm("starting $flight started=$now") if $count>0;
}

sub host_check_allocated ($$) { #method
    my ($jd, $ho) = @_;
    $ho->{Shared}= resource_check_allocated('host', $ho->{Name});
    $ho->{SharedReady}=
        $ho->{Shared} &&
        $ho->{Shared}{State} eq 'ready' &&
        !! (grep { $_ eq "share-".$ho->{Shared}{Type} }
	    get_hostflags($ho->{Ident}));
    $ho->{SharedOthers}=
        $ho->{Shared} ? $ho->{Shared}{Others} : 0;
    
    die if $ho->{SharedOthers} && !$ho->{SharedReady};
}

sub jobdb_postfork ($) { #method
    my ($jd) = @_;
    $dbh_tests->{InactiveDestroy}= 1;  undef $dbh_tests;
}

sub gen_ether_offset ($$) { #method
    my ($mo,$ho,$fl) = @_;
    return $flight & 0xff;
}

sub jobdb_resource_shared_mark_ready { #method
    my ($mo, $restype, $resname, $sharetype) = @_;
    resource_shared_mark_ready($restype, $resname, $sharetype);
}

sub jobdb_check_other_job { #method
    my ($mo, $flight,$job, $oflight,$ojob);

    if ("$oflight.$ojob" ne "$flight.$job") {
        my $jstmt= <<END;
            SELECT * FROM jobs WHERE flight=? AND job=?
END
        my $jrow= $dbh_tests->selectrow_hashref($jstmt,{}, $oflight,$ojob);
        $jrow or broken("job $oflight.$ojob not found (looking for $param)");
        my $jstatus= $jrow->{'status'};

        defined $jstatus or broken("job $oflight.$ojob no status?!");
        if ($jstatus eq 'pass') {
            # fine
        } elsif ($jstatus eq 'queued') {
            $jrow= $dbh_tests->selectrow_hashref($jstmt,{}, $flight,$job);
            $jrow or broken("our job $flight.$job not found!");
            my $ourstatus= $jrow->{'status'};
            if ($ourstatus eq 'queued') {
                logm("not running under sg-execute-*:".
                     " $oflight.$ojob queued ok, for $param");
            } else {
                die "job $oflight.$ojob (for $param) queued (we are $ourstatus)";
            }
        } else {
            broken("job $oflight.$ojob (for $param) $jstatus", 'blocked');
        }
    }
}

sub jobdb_flight_started_for_log_capture ($$) { #method
    my ($mo, $flight) = @_;
    my $started= $dbh_tests->selectrow_array(<<END);
        SELECT started FROM flights WHERE flight=$flight
END
    return $started;
}

sub jobdb_enable_log_capture ($) { #method
    my ($mo) = @_;
    return 1;
}

sub jobdb_db_glob ($$) { #method
    my ($mo, $str) = @_;
    # $str must be a glob pattern; returns a glob clause
    # [...] and ? in the glob are not supported
    # ' and \ may not occur either
    $str =~ s/\*/%/;
    $str =~ s/_/\\_/g;
    return "LIKE E'$str'";
}

1;
