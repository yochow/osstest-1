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


package Osstest::Executive;

use strict;
use warnings;

use Osstest;

use POSIX;
use IO::File;
use File::Copy;
use DBI;
use Socket;
use IPC::Open2;
use IO::Handle;
use JSON;
use File::Basename;
use IO::Socket::INET;
use HTML::Entities;
#use Data::Dumper;

use Osstest;
use Osstest::TestSupport;
use Osstest::Executive;

BEGIN {
    use Exporter ();
    our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
    $VERSION     = 1.00;
    @ISA         = qw(Exporter);
    @EXPORT      = qw(get_harness_rev grabrepolock_reexec
                      findtask @all_lock_tables
                      restrictflight_arg restrictflight_cond
                      report_run_getinfo report_altcolour
                      report_altchangecolour
                      report_blessingscond report_find_push_age_info
                      tcpconnect_queuedaemon plan_search
                      alloc_resources alloc_resources_rollback_begin_work
                      resource_check_allocated resource_shared_mark_ready
                      duration_estimator
                      db_pg_dsn opendb opendb_state
                      );
    %EXPORT_TAGS = ( colours => [qw($green $red $yellow $purple $blue)] );

    @EXPORT_OK   = @{ $EXPORT_TAGS{colours} };
}

# DATABASE TABLE LOCK HIERARCHY
#
#  Lock first
#
#   flights
#            must be locked for any query modifying
#                   flights_flight_seq
#                   flights_harness_touched
#                   jobs
#                   steps
#                   runvars
#
#   resources
#            must be locked for any query modifying
#                   tasks
#                   tasks_taskid_seq
#                   resource_sharing 
#                   hostflags
#                   resource_properties
#
#   any other tables or databases
#
our (@all_lock_tables) = qw(flights resources);
#
#  Lock last
#
# READS:
#
#  Nontransactional reads are also permitted
#  Transactional reads must take out locks as if they were modifying

augmentconfigdefaults(
    ControlDaemonHost => 'control-daemons',
    OwnerDaemonPort => 4031,
    QueueDaemonPort => 4032,
    QueueDaemonRetry => 120, # seconds
    QueueDaemonHoldoff => 30, # seconds
    QueueThoughtsTimeout => 30, # seconds
    QueueResourcePollInterval => 60, # seconds
    QueuePlanUpdateInterval => 300, # seconds
    Repos => "$ENV{'HOME'}/repos",
    BisectionRevisonGraphSize => '600x300',
);

augmentconfigdefaults(
    OwnerDaemonHost => $c{ControlDaemonHost},
    QueueDaemonHost => $c{ControlDaemonHost},
);

#---------- configuration reader etc. ----------

sub opendb_tests () {
    $dbh_tests ||= $mjobdb->open();
}

sub grabrepolock_reexec {
    my (@org_argv) = @_;
    my $repos_lock= "$c{Repos}/lock";
    my $repos_locked= $ENV{OSSTEST_REPOS_LOCK_LOCKED};
    unless (defined $repos_locked && $repos_locked eq $repos_lock) {
        $ENV{OSSTEST_REPOS_LOCK_LOCKED}= $repos_lock;
        exec "with-lock-ex","-w",$repos_lock, $0,@org_argv;
        die $!;
    }
}

sub get_harness_rev () {
    $!=0; $?=0;  my $rev= `git rev-parse HEAD^0`;
    die "$? $!" unless defined $rev;

    $rev =~ s/\n$//;
    die "$rev ?" unless $rev =~ m/^[0-9a-f]+$/;

    my $diffr= system 'git diff --exit-code HEAD >/dev/null';
    if ($diffr) {
        die "$diffr $! ?" if $diffr != 256;
        $rev .= '+';
    }

    return $rev;
}

#---------- database access ----------#

sub opendb_state () {
    return opendb('statedb');
}

our $whoami;

sub db_pg_dsn ($) {
    my ($dbname) = @_;
    my $pg= $c{"ExecutiveDbname_$dbname"};

    if (!defined $pg) {
	if (!defined $whoami) {
	    $whoami = `whoami`;  die if $?;  chomp $whoami;
	}
        my $pat= $c{ExecutiveDbnamePat};
        my %vars= ('dbname' => $dbname,
                   'whoami' => $whoami);
        $pat =~ s#\<(\w+)\>#
            my $val=$vars{$1};  defined $val or die "$pat $1 ?";
            $val;
        #ge;
        $pat =~ s#\<(([.~]?)(/[^<>]+))\>#
            my $path= $2 eq '~' ? "$ENV{HOME}/$3" : $1;
            my $data= get_filecontents_core_quiet($path);
            chomp $data;
            $data;
        #ge;
        $pat =~ s#\<([][])\># $1 eq '[' ? '<' : '>' #ge;

        $pg = $c{"ExecutiveDbname_$dbname"} = $pat;
    }
    return $pg;
}

sub opendb ($) {
    my ($dbname) = @_;

    my $pg= db_pg_dsn($dbname);

    my $dbh= DBI->connect("dbi:Pg:$pg", '','', {
        AutoCommit => 1,
        RaiseError => 1,
        ShowErrorStatement => 1,
        })
        or die "could not open state db $pg";
    return $dbh;
}

#---------- history reporting ----------

our $restrictflight_cond = 'TRUE';

sub restrictflight_arg ($) {
    my ($arg) = @_;
    if ($arg =~ m/^--max-flight\=([1-9]\d*)$/) {
	$restrictflight_cond .= " AND flight <= $1";
	return 1;
    } elsif ($arg =~ m/^--exclude-flights=([0-9,]+)$/) {
        $restrictflight_cond .= " AND flights.flight != $_"
	    foreach split /,/, $1;
	return 1;
    } else {
	return 0;
    }
}

sub restrictflight_cond () {
    return "($restrictflight_cond)";
}

our $green=  '#008800';
our $red=    '#ff8888';
our $yellow= '#ffff00';
our $purple= '#ff00ff';
our $blue=   '#0000ff';

sub report_run_getinfo ($) {
    # $f is a joined flight/job row, must contain at least
    #    flight job status
    my ($f) = @_;
    my $status= $f->{status};

    my $single = sub {
	my ($summary, $colour) = @_;
	return {
	    Content => encode_entities($summary),
	    ColourAttr => "bgcolor=\"$colour\"",
	};
    };

    if ($status eq 'pass') {
        return $single->("($status)", $green);
    } elsif ($status eq 'fail' or $status eq 'broken') {
	my $failcolour = $status eq 'fail' ? $red : $yellow;
	our $failstepq //= db_prepare(<<END);
	    SELECT * FROM steps
	     WHERE flight=? AND job=?
	       AND status!='pass'
	  ORDER BY stepno
END
        $failstepq->execute($f->{flight}, $f->{job});
	my @content;
	while (my $fs = $failstepq->fetchrow_hashref()) {
	    my $summary = $fs->{testid};
	    my $colour;
	    if ($fs->{status} eq 'fail') {
		$colour = $red;
	    } elsif ($fs->{status} eq 'broken') {
		$summary .= " broken";
		$colour = $yellow;
	    } else {
		$summary .= " $fs->{status}";
		$colour = $failcolour;
	    }
	    push @content, "<span style=\"background-color: $colour\">".
		encode_entities($summary)."</span>";
        }
	if (!@content) {
	    return $single->("(unknown)", $yellow);
	}
	return {
	    Content => (join " | ", @content),
	    ColourAttr => "bgcolor=\"$failcolour\"",
	};
    } elsif ($status eq 'blocked') {
        return $single->("blocked", $purple),
    } else {
        return $single->("($f->{status})", $yellow);
    }
}

sub report_altcolour ($) {
    my ($bool) = @_;
    return "bgcolor=\"#".(qw(d0d0d0 ffffff))[$bool]."\"";
}

sub report_altchangecolour ($$) {
    my ($stateref, $thisvalue) = @_;
    my $state = $$stateref //= { Bool => 0 };
    my $same =
	!!defined($thisvalue) == !!defined($state->{LastValue}) &&
	(!defined $thisvalue || $thisvalue eq $state->{LastValue});
    $state->{Bool} ^= !$same;
    $state->{LastValue} = $thisvalue;
    return report_altcolour($state->{Bool});
}

sub report_blessingscond ($) {
    my ($blessings) = @_;
    my $flightcond= restrictflight_cond();
    my $blessingscond= '('.join(' OR ', map {
	die if m/[^-_.0-9a-z]/;
	"blessing='$_'"
				} @$blessings).')';
    return "( $flightcond AND $blessingscond )";
    return $blessingscond;
}

sub report__find_test ($$$$$$$) {
    my ($blessings, $branches, $tree,
	$revision, $selection, $extracond, $sortlimit) = @_;
    # Reports information about a flight which tried to test $revision
    # of $tree.  ($revision may be undef);

    my @params;

    my $querytext = <<END;
        SELECT $selection
	 FROM flights f
	WHERE
END

    if (defined $revision) {
	if ($tree eq 'osstest') {
	    $querytext .= <<END;
		EXISTS (
		   SELECT 1
		    FROM flights_harness_touched t
		   WHERE t.harness=?
		     AND t.flight=f.flight
		 )
END
            push @params, $revision;
	} else {
	    $querytext .= <<END;
		EXISTS (
		   SELECT 1
		    FROM runvars r
		   WHERE name=?
		     AND val=?
		     AND r.flight=f.flight
                     AND ${\ main_revision_job_cond('r.job') }
		 )
END
            push @params, "revision_$tree", $revision;
        }
    } else {
	$querytext .= <<END;
	    TRUE
END
    }

    my $blessingscond = report_blessingscond($blessings);
    $querytext .= <<END;
	  AND $blessingscond
END

    my $branchescond = join ' OR ', map { "branch=?" } @$branches;
    $querytext .= <<END;
	  AND ($branchescond)
END
    push @params, @$branches;

    $querytext .= $extracond;
    $querytext .= $sortlimit;

    my $query = db_prepare($querytext);
    $query->execute(@params);

    my $row = $query->fetchrow_hashref();
    $query->finish();
    return $row;
}

sub report_find_push_age_info ($$$$$) {
    my ($blessings, $branches, $tree,
	$basis_revision, $tip_revision) = @_;
    # Reports information about tests of $tree.
    # (Subject to @$blessings, $maxflight, @$branches)
    # Returns {
    #    Basis           =>  row for last test of basis
    #    FirstAfterBasis =>  row for first test after basis
    #    FirstTip        =>  row for first test of tip (after Basis)
    #    LastTip         =>  row for last test of tip (after Basis)
    #    CountAfterBasis =>  count of runs strictly after Basis
    #    CountTip        =>  count of runs on Tip
    #  }
    # where
    #  row for ... is from fetchrow_hashref of SELECT * FROM flights
    #                 (or undef if no such thing exists)
    #  Count       is a scalar integer.
    #
    # Only flights which specified the exact revision specified
    # are considered (not ones which specified a tag, for example).

    my $findtest = sub {
	my ($revision,$selection,$extracond,$sortlimit) = @_;
	report__find_test($blessings,$branches,$tree,
			 $revision,$selection,$extracond,$sortlimit);
    };

    my $findcount = sub {
	my ($revision,$extracond,$sortlimit) = @_;
	my $row = $findtest->($revision, 'COUNT(*) AS count',
			      $extracond, $sortlimit);
	return $row->{count} // die "$revision $extracond $sortlimit ?";
    };

    my $out = { };
    $out->{Basis} = $findtest->($basis_revision, '*', '', <<END);
        ORDER BY flight DESC
        LIMIT 1
END

    my $afterbasis = $out->{Basis} ? <<END : '';
        AND flight > $out->{Basis}{flight}
END

    $out->{FirstAfterBasis} = $findtest->(undef, '*', $afterbasis, <<END)
        ORDER BY flight ASC
	LIMIT 1
END
        if $afterbasis;

    $out->{FirstTip} = $findtest->($tip_revision, '*', $afterbasis, <<END);
        ORDER BY flight ASC
        LIMIT 1
END

    my $likelytip = $out->{FirstTip} ? <<END : '';
        AND flight >= $out->{FirstTip}{flight}
END

    $out->{LastTip} = $findtest->($tip_revision, '*', $likelytip, <<END)
        ORDER BY flight DESC
        LIMIT 1
END
        if $out->{FirstTip};

    $out->{CountAfterBasis} = $findcount->(undef, $afterbasis, '')
        if $afterbasis;

    $out->{CountTip} =
	$out->{FirstTip} ? $findcount->($tip_revision, $likelytip, '')
	: 0;

    return $out;
}

#---------- host (and other resource) allocation ----------

our $taskid;

sub findtask () {
    return $taskid if defined $taskid;
    
    my $spec= $ENV{'OSSTEST_TASK'};
    my $q;
    my $what;
    if (!defined $spec) {
        $!=0; $?=0; my $whoami= `whoami`;   defined $whoami or die "$? $!";
        $!=0; $?=0; my $node=   `uname -n`; defined $node   or die "$? $!";
        chomp($whoami); chomp($node); $node =~ s/\..*//;
        my $refkey= "$whoami\@$node";
        $what= "static $refkey";
        $q= $dbh_tests->prepare(<<END);
            SELECT * FROM tasks
                    WHERE type='static' AND refkey=?
END
        $q->execute($refkey);
    } else {
        my @l = split /\s+/, $spec;
        @l==3 or die "$spec ".scalar(@l)." ?";
        $what= $spec;
        $q= $dbh_tests->prepare(<<END);
            SELECT * FROM tasks
                    WHERE taskid=? AND type=? AND refkey=?
END
        $q->execute(@l);
    }
    my $row= $q->fetchrow_hashref();
    die "no task $what ?" unless defined $row;
    die "task $what dead" unless $row->{live};
    $q->finish();

    foreach my $k (qw(username comment)) {
        next if defined $row->{$k};
        $row->{$k}= "[no $k]";
    }

    my $newspec= "$row->{taskid} $row->{type} $row->{refkey}";
    logm("task $newspec: $row->{username} $row->{comment}");

    $taskid= $row->{taskid};
    $ENV{'OSSTEST_TASK'}= $newspec if !defined $spec;

    return $taskid;
}        

sub alloc_resources_rollback_begin_work () {
    $dbh_tests->rollback();
    db_begin_work($dbh_tests, \@all_lock_tables);
}

our $alloc_resources_waitstart;

sub tcpconnect_queuedaemon () {
    my $qserv= tcpconnect($c{QueueDaemonHost}, $c{QueueDaemonPort});
    $qserv->autoflush(1);

    $_= <$qserv>;  defined && m/^OK ms-queuedaemon\s/ or die "$_?";

    return $qserv;
}

sub plan_search ($$$$) {
    my ($plan, $dbgprint, $duration, $requestlist) = @_;
    #
    # Finds first place where $requestlist can be made to fit in $oldplan
    # returns {
    #     Start =>        start time from now in seconds,
    #     ShareReuse =>   no of allocations which are a share reuse
    #   }
    #
    #  $requestlist->[]{Reso}
    #  $requestlist->[]{Ident}
    #  $requestlist->[]{Shared}          may be undef
    #  $requestlist->[]{SharedMaxWear}   undef iff Shared is undef
    #  $requestlist->[]{SharedMaxTasks}  undef iff Shared is undef

    my $reqix= 0;
    my $try_time= 0;
    my $confirmedok= 0;
    my $share_wear;
    my $share_reuse= 0;

    for (;;) {
	my $req= $requestlist->[$reqix];
        my $reso= $req->{Reso};
	my $events= $plan->{Events}{$reso};

        $events ||= [ ];

	# can we do $req at $try_time ?  If not, when later can we ?
      PERIOD:
	foreach (my $ix=0; $ix<@$events; $ix++) {
	    $dbgprint->("PLAN LOOP reqs[$reqix]=$req->{Ident}".
		" evtix=$ix try=$try_time confirmed=$confirmedok".
		(defined($share_wear) ? " wear=$share_wear" : ""));

	    # check the period from $events[$ix] to next event
	    my $startevt= $events->[$ix];
	    my $endevt= $ix+1<@$events ? $events->[$ix+1] : { Time=>1e100 };

	    last PERIOD if $startevt->{Time} >= $try_time + $duration;
            # this period is entirely after the proposed slot;
            # so no need to check this or any later periods

	    next PERIOD if $endevt->{Time} <= $try_time;
            # this period is entirely before the proposed slot;
            # it doesn't overlap, but most check subsequent periods

	  CHECK:
	    {
		$dbgprint->("PLAN LOOP   OVERLAP");
		last CHECK unless $startevt->{Avail};
		my $eshare= $startevt->{Share};
		if ($eshare) {
		    $dbgprint->("PLAN LOOP   OVERLAP ESHARE");
		    last CHECK unless defined $req->{Shared};
		    last CHECK unless $req->{Shared} eq $eshare->{Type};
		    if (defined $share_wear) {
			$share_wear++ if $startevt->{Type} eq 'Start';
		    } else {
			$share_wear= $eshare->{Wear}+1;
		    }
		    last CHECK if $share_wear > $req->{SharedMaxWear};
		    last CHECK if $eshare->{Shares} != $req->{SharedMaxTasks};
		}
		# We have suitable availability for this period
		$dbgprint->("PLAN LOOP   OVERLAP AVAIL OK");
		next PERIOD;
	    };
		
	    # nope
	    $try_time= $endevt->{Time};
	    $confirmedok= 0;
	    undef $share_wear;
	    $share_reuse= 0;
	    $dbgprint->("PLAN LOOP   OVERLAP BAD $try_time");
	}
	$dbgprint->("PLAN NEXT reqs[$reqix]=$req->{Ident}".
	    " try=$try_time confirmed=$confirmedok reuse=$share_reuse".
	    (defined($share_wear) ? " wear=$share_wear" : ""));

	$confirmedok++;
	$share_reuse++ if defined $share_wear;
	$reqix++;
	$reqix %= @$requestlist;
	last if $confirmedok==@$requestlist;
    }

    return {
        Start => $try_time,
        ShareReuse => $share_reuse,
    };
}

sub alloc_resources {
    my ($resourcecall) = pop @_; # $resourcecall->($plan, $mayalloc);
    my (%xparams) = @_;
    # $resourcecall should die (abort) or return ($ok, $bookinglist)
    #
    #  values of $ok
    #            0  rollback, wait and try again
    #            1  commit, completed ok
    #  $bookinglist should be undef or a hash for making a booking
    #
    # $resourcecall should not look at tasks.live
    #  instead it should look for resources.owntaskid == the allocatable task
    # $resourcecall runs with all tables locked (see above)

    my $qserv;
    my $retries=0;
    my $ok=0;

    logm("resource allocation: starting...");

    my $debugfh = $xparams{DebugFh};
    my $debugm = $debugfh
	? sub { print $debugfh @_, "\n" or die $!; }
        : sub { };

    my $set_info= sub {
        return if grep { !defined } @_;
        my @s;
        foreach my $s (@_) {
            local ($_) = ($s);
            if (m#[^-+_.,/0-9a-z]# || !m/./) {
                s/[\\\"]/\\$&/g;
                s/^/\"/;
                s/$/\"/;
            }
            push @s, $_;
        }
        print $qserv "set-info @s\n";
        $_= <$qserv>;  defined && m/^OK/ or die "$_ ?";
    };

    my $priority= $ENV{OSSTEST_RESOURCE_PRIORITY};
    if (!defined $priority) {
        if (open TTY_TEST, "/dev/tty") {
            close TTY_TEST;
            $priority= -10;
            logm("resource allocation: on tty, priority=$priority");
        }
    }

    while ($ok==0) {
        my $bookinglist;
        if (!eval {
            if (!defined $qserv) {
                $qserv= tcpconnect_queuedaemon();

                my $waitstart= $xparams{WaitStart};
                if (!$waitstart) {
                    if (!defined $alloc_resources_waitstart) {
                        print $qserv "time\n" or die $!;
                        $_= <$qserv>;
                        defined or die $!;
                        if (m/^OK time (\d+)$/) {
                            $waitstart= $alloc_resources_waitstart= $1;
                        }
                    }
                }

                $set_info->('priority', $priority);
                $set_info->('sub-priority',$ENV{OSSTEST_RESOURCE_SUBPRIORITY});
                $set_info->('preinfo',     $ENV{OSSTEST_RESOURCE_PREINFO});

                if (defined $waitstart) {
                    $set_info->('wait-start',$waitstart);
                }

                my $adjust= $xparams{WaitStartAdjust};
                if (defined $adjust) {
                    $set_info->('wait-start-adjust',$adjust);
                }

                my $jobinfo= $xparams{JobInfo};
                if (!defined $jobinfo and defined $flight and defined $job) {
                    $jobinfo= "$flight.$job";
                }
                $set_info->('job', $jobinfo);

                print $qserv "wait\n" or die $!;
                $_= <$qserv>;  defined && m/^OK wait\s/ or die "$_ ?";
            }

            $dbh_tests->disconnect() if $dbh_tests;
            undef $dbh_tests;

            logm("resource allocation: awaiting our slot...");

            $_= <$qserv>;  defined && m/^\!OK think\s$/ or die "$_ ?";

            opendb_tests();

            my ($plan);

	    db_retry($flight,'running', $dbh_tests, \@all_lock_tables,
		     [ sub {
		print $qserv "get-plan\n" or die $!;
		$_= <$qserv>; defined && m/^OK get-plan (\d+)\s/ or die "$_ ?";

		my $jplanlen= $1;
		my $jplan;
		read($qserv, $jplan, $jplanlen) == $jplanlen or die $!;
		my $jplanprint= $jplan;
		chomp $jplanprint;
		logm("resource allocation: obtained base plan.");
		$debugm->("base plan = ", $jplanprint);
		$plan= from_json($jplan);
	    }, sub {
		if (!eval {
		    ($ok, $bookinglist) = $resourcecall->($plan, 1);
		    1;
		}) {
		    warn "resourcecall $@";
		    $ok=-1;
		}
		return db_retry_abort() unless $ok>0;
	    }]);

	    if ($bookinglist && $ok!=-1) {
		my $jbookings= to_json($bookinglist);
                chomp($jbookings);
                logm("resource allocation: booking.");
		$debugm->("bookings = ", $jbookings);

		printf $qserv "book-resources %d\n", length $jbookings
		    or die $!;
		$_= <$qserv>; defined && m/^SEND\s/ or die "$_ ?";

		print $qserv $jbookings or die $!;
		$_= <$qserv>; defined && m/^OK book-resources\s/ or die "$_ ?";

		logm("resource allocation: we are in the plan.");
	    }

            if ($ok==1) {
                print $qserv "thought-done\n" or die $!;
            } elsif ($ok<0) {
                return 1;
            } else { # 0
                logm("resource allocation: deferring");
                print $qserv "thought-wait\n" or die $!;
            }
            $_= <$qserv>;  defined && m/^OK thought\s$/ or die "$_ ?";
            
            1;
        }) {
            $retries++;
            die "trouble $@" if $retries > 60;
            chomp $@;
            logm("resource allocation: queue-server trouble ($@)");
            if ($bookinglist) {
                # If we have allocated things but not managed to book them
                # then we need to free them, or we won't reallocate them
                # when we retry.
                db_retry($flight,'running',$dbh_tests,\@all_lock_tables, sub {
                    my $freetask= findtask();
                    foreach my $book (@{ $bookinglist->{Bookings} }) {
                        my $alloc= $book->{Allocated};
                        next unless $alloc;
                        my @reskey= ((split / /, $book->{Reso}, 2),
                                     $alloc->{Shareix});
                        $reskey[0]= "share-$reskey[0]" if $reskey[2];
                        logm("resource allocation: unwinding ".
			     join '/', @reskey);
                        my $undone= $dbh_tests->do(<<END,{},$freetask,@reskey);
                            UPDATE resources
                               SET owntaskid=(SELECT taskid FROM tasks
                                        WHERE type='magic' AND refkey='idle')
                             WHERE owntaskid=?
                               AND restype=? AND resname=? AND shareix=?
END
                        die "$freetask @reskey $undone" unless $undone;
                    }
                });
            }
            logm("resource allocation: will retry in $c{QueueDaemonRetry}s");
            sleep $c{QueueDaemonRetry};
            undef $qserv;
            $ok= 0;
        }
    }
    die unless $ok==1;
    logm("resource allocation: successful.");
}

sub resource_check_allocated ($$) {
    my ($restype,$resname) = @_;
    return db_retry($dbh_tests, [qw(resources)], sub {
        return resource_check_allocated_core($restype,$resname);
    });
}

sub resource_check_allocated_core ($$) {
    # must run in db_retry with resources locked
    my ($restype,$resname) = @_;
    my $tid= findtask();
    my $shared;

    my $res= $dbh_tests->selectrow_hashref(<<END,{}, $restype, $resname);
        SELECT * FROM resources LEFT JOIN tasks
                   ON taskid=owntaskid
                WHERE restype=? AND resname=?
END
    die "resource $restype $resname not found" unless $res;
    die "resource $restype $resname no task" unless defined $res->{taskid};

    if ($res->{type} eq 'magic' && $res->{refkey} eq 'shared') {
        my $shr= $dbh_tests->selectrow_hashref(<<END,{}, $restype,$resname);
                SELECT * FROM resource_sharing
                        WHERE restype=? AND resname=?
END
        die "host $resname shared but no share?" unless $shr;

        my $shrestype= 'share-'.$restype;
        my $shrt= $dbh_tests->selectrow_hashref
            (<<END,{}, $shrestype,$resname,$tid);
                SELECT * FROM resources LEFT JOIN tasks ON taskid=owntaskid
                        WHERE restype=? AND resname=? AND owntaskid=?
END

        die "resource $restype $resname not shared by $tid" unless $shrt;
        die "resource $resname $resname share $shrt->{shareix} task $tid dead"
            unless $shrt->{live};

        my $others= $dbh_tests->selectrow_hashref
            (<<END,{}, $shrt->{restype}, $shrt->{resname}, $shrt->{shareix});
                SELECT count(*) AS ntasks
                         FROM resources LEFT JOIN tasks ON taskid=owntaskid
                        WHERE restype=? AND resname=? AND shareix!=?
                          AND live
                          AND owntaskid != (SELECT taskid FROM tasks
                                             WHERE type='magic'
                                               AND refkey='preparing')
END

        $shared= { Type => $shr->{sharetype},
                   State => $shr->{state},
                   ResType => $shrestype,
                   Others => $others->{ntasks} };
    } else {
        die "resource $restype $resname task $res->{owntaskid} not $tid"
            unless $res->{owntaskid} == $tid;
    }
    die "resource $restype $resname task $res->{taskid} dead"
        unless $res->{live};

    return $shared;
}

sub resource_shared_mark_ready ($$$) {
    my ($restype, $resname, $sharetype) = @_;
    # must run outside transaction

    my $what= "resource $restype $resname";
    $sharetype .= ' '.get_harness_rev();

    db_retry($dbh_tests, [qw(resources)], sub {
        my $oldshr= resource_check_allocated_core($restype, $resname);
        if (defined $oldshr) {
            die "$what shared $oldshr->{Type} not $sharetype"
                unless $oldshr->{Type} eq $sharetype;
            die "$what shared state $oldshr->{State} not prep"
                unless $oldshr->{State} eq 'prep';
            my $nrows= $dbh_tests->do(<<END,{}, $restype,$resname,$sharetype);
                UPDATE resource_sharing
                   SET state='ready'
                 WHERE restype=? AND resname=? AND sharetype=?
END
            die "unexpected not updated state $what $sharetype $nrows"
                unless $nrows==1;

            $dbh_tests->do(<<END,{}, $oldshr->{ResType}, $resname);
                UPDATE resources
                   SET owntaskid=(SELECT taskid FROM tasks
                                   WHERE type='magic' AND refkey='idle')
                 WHERE owntaskid=(SELECT taskid FROM tasks
                                   WHERE type='magic' AND refkey='preparing')
                   AND restype=? AND resname=?
END
        }
    });
    if (!eval {
       my $qserv = tcpconnect_queuedaemon();
       print $qserv "prod\n" or die $!;
       $_ = <$qserv>;  defined && m/^OK prod\b/ or die "$_ ?";
       1;
    }) {
       logm("post-mark-ready queue daemon prod failed: $@");
    }
    logm("$restype $resname shared $sharetype marked ready");
}

#---------- duration estimator ----------

sub duration_estimator ($$;$) {
    my ($branch, $blessing, $debug) = @_;
    # returns a function which you call like this
    #    $durest->($job, $hostidname, $onhost)
    # and returns one of
    #    ($seconds, $samehostlaststarttime, $samehostlaststatus)
    #    ($seconds, undef, undef)
    #    ()
    # $debug should be something like sub { print DEBUG "@_\n"; }.
    # Pass '' for $hostidname and $onhost for asking about on any host

    my $recentflights_q= $dbh_tests->prepare(<<END);
            SELECT f.flight AS flight,
		   f.started AS started,
                   j.status AS status
		     FROM flights f
                     JOIN jobs j USING (flight)
                     JOIN runvars r
                             ON  f.flight=r.flight
                            AND  r.name=?
                    WHERE  j.job=r.job
                      AND  f.blessing=?
                      AND  f.branch=?
                      AND  j.job=?
                      AND  r.val=?
		      AND  (j.status='pass' OR j.status='fail')
                      AND  f.started IS NOT NULL
                      AND  f.started >= ?
                 ORDER BY f.started DESC
END

    my $duration_anyref_q= $dbh_tests->prepare(<<END);
            SELECT f.flight AS flight
		      FROM steps s JOIN flights f
		        ON s.flight=f.flight
		     WHERE s.job=? AND f.blessing=? AND f.branch=?
                       AND s.finished IS NOT NULL
                       AND f.started IS NOT NULL
                       AND f.started >= ?
                     ORDER BY s.finished DESC
END
    # s J J J # fix perl-mode

    my $duration_duration_q= $dbh_tests->prepare(<<END);
            SELECT sum(finished-started) AS duration FROM steps
		          WHERE flight=? AND job=?
                            AND step != 'ts-hosts-allocate'
END

    return sub {
        my ($job, $hostidname, $onhost) = @_;

        my $dbg= $debug ? sub {
            $debug->("DUR $branch $blessing $job $hostidname $onhost @_");
        } : sub { };

        my $refs=[];
        my $limit= time - 86400*14;

        if ($hostidname ne '') {
            $recentflights_q->execute($hostidname,
                                      $blessing,
                                      $branch,
                                      $job,
                                      $onhost,
                                      $limit);
            $refs= $recentflights_q->fetchall_arrayref({});
            $recentflights_q->finish();
            $dbg->("SAME-HOST GOT ".scalar(@$refs));
        }

        if (!@$refs) {
            $duration_anyref_q->execute($job, $blessing, $branch, $limit);
            $refs= $duration_anyref_q->fetchall_arrayref({});
            $duration_anyref_q->finish();
            $dbg->("ANY-HOST GOT ".scalar(@$refs));
        }

        if (!@$refs) {
            $dbg->("NONE");
            return ();
        }

        my $duration_max= 0;
        foreach my $ref (@$refs) {
            $duration_duration_q->execute($ref->{flight}, $job);
            my ($duration) = $duration_duration_q->fetchrow_array();
            $duration_duration_q->finish();
            if ($duration) {
                $dbg->("REF $ref->{flight} DURATION $duration ".
		       ($ref->{status} // ''));
                $duration_max= $duration
                    if $duration > $duration_max;
            }
        }

        return ($duration_max, $refs->[0]{started}, $refs->[0]{status});
    };
}

1;
