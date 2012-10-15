
package Osstest::TestSupport;

use strict;
use warnings;

use POSIX;
use DBI;
use IO::File;

use Osstest;

BEGIN {
    use Exporter ();
    our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
    $VERSION     = 1.00;
    @ISA         = qw(Exporter);
    @EXPORT      = qw(
                      tsreadconfig %r $flight $job $stash

fail logm

store_runvar get_runvar get_runvar_maybe get_runvar_default need_runvars

                      );
    %EXPORT_TAGS = ( );

    @EXPORT_OK   = qw();
}

our (%r,$flight,$job,$stash);

our $logm_handle= new IO::File ">& STDERR" or die $!;

#---------- test script startup ----------

sub tsreadconfig () {
    # must be run outside transaction
    csreadconfig();

    $flight= $mjobdb->current_flight();
    $job=    $ENV{'OSSTEST_JOB'};
    die unless defined $flight and defined $job;

    my $now= time;  defined $now or die $!;

    db_retry($flight,[qw(running constructing)],
             $dbh_tests,[qw(flights)], sub {
	$mjobdb->job_ensure_started();

        undef %r;

        logm("starting $flight.$job");

        my $q= $dbh_tests->prepare(<<END);
            SELECT name, val FROM runvars WHERE flight=? AND job=?
END
        $q->execute($flight, $job);
        my $row;
        while ($row= $q->fetchrow_hashref()) {
            $r{ $row->{name} }= $row->{val};
            logm("setting $row->{name}=$row->{val}");
        }
        $q->finish();
    });

    $stash= "$c{Stash}/$flight/$job";
    ensuredir("$c{Stash}/$flight");
    ensuredir($stash);
    ensuredir('tmp');
    eval {
        system_checked("find tmp -mtime +30 -name t.\\* -print0".
                       " | xargs -0r rm -rf --");
        1;
    } or warn $@;
}

#---------- general ----------

sub logm ($) {
    my ($m) = @_;
    my @t = gmtime;
    printf $logm_handle "%04d-%02d-%02d %02d:%02d:%02d Z %s\n",
        $t[5]+1900,$t[4]+1,$t[3], $t[2],$t[1],$t[0],
        $m
    or die $!;
    $logm_handle->flush or die $!;
}

sub fail ($) {
    my ($m) = @_;
    logm("FAILURE: $m");
    die "failure: $m\n";
}

sub broken ($;$) {
    my ($m, $newst) = @_;
    # must be run outside transaction
    my $affected;
    $newst= 'broken' unless defined $newst;
    db_retry($flight,'running', $dbh_tests,[qw(flights)], sub {
        $affected= $dbh_tests->do(<<END, {}, $newst, $flight, $job);
            UPDATE jobs SET status=?
             WHERE flight=? AND job=?
               AND (status='queued' OR status='running')
END
    });
    die "BROKEN: $m; ". ($affected>0 ? "marked $flight.$job $newst"
                         : "($flight.$job not marked $newst)");
}

#---------- runvars ----------

sub store_runvar ($$) {
    my ($param,$value) = @_;
    # must be run outside transaction
    logm("runvar store: $param=$value");
    db_retry($flight,'running', $dbh_tests,[qw(flights)], sub {
        $dbh_tests->do(<<END, undef, $flight, $job, $param);
	    DELETE FROM runvars
		  WHERE flight=? AND job=? AND name=? AND synth='t'
END
        $dbh_tests->do(<<END,{}, $flight,$job, $param,$value);
            INSERT INTO runvars VALUES (?,?,?,?,'t')
END
    });
    $r{$param}= get_runvar($param, "$flight.$job");
}

sub get_runvar ($$) {
    my ($param, $otherflightjob) = @_;
    # may be run outside transaction, or with flights locked
    my $r= get_runvar_maybe($param,$otherflightjob);
    die "need $param in $otherflightjob" unless defined $r;
    return $r;
}

sub get_runvar_default ($$$) {
    my ($param, $otherflightjob, $default) = @_;
    # may be run outside transaction, or with flights locked
    my $r= get_runvar_maybe($param,$otherflightjob);
    return defined($r) ? $r : $default;
}

sub get_runvar_maybe ($$) {
    my ($param, $otherflightjob) = @_;
    # may be run outside transaction, or with flights locked
    my ($oflight, $ojob) = otherflightjob($otherflightjob);

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

    my $row= $dbh_tests->selectrow_arrayref(<<END,{}, $oflight,$ojob,$param);
        SELECT val FROM runvars WHERE flight=? AND job=? AND name=?
END
    if (!$row) { return undef; }
    return $row->[0];
}

sub need_runvars {
    my @missing= grep { !defined $r{$_} } @_;
    return unless @missing;
    die "missing runvars @missing ";
}

1;
