
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

logm 
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

sub logm ($) {
    my ($m) = @_;
    my @t = gmtime;
    printf $logm_handle "%04d-%02d-%02d %02d:%02d:%02d Z %s\n",
        $t[5]+1900,$t[4]+1,$t[3], $t[2],$t[1],$t[0],
        $m
    or die $!;
    $logm_handle->flush or die $!;
}

1;
