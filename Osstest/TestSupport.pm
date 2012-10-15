
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
 flight_otherjob

                      target_cmd_root target_cmd target_cmd_build
                      target_cmd_output_root target_cmd_output
                      target_getfile target_getfile_root
                      target_putfile target_putfile_root
                      target_putfilecontents_stash
		      target_putfilecontents_root_stash
                      target_editfile_root target_file_exists
                      target_install_packages target_install_packages_norec
                      target_extract_jobdistpath
poll_loop
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

sub flight_otherjob ($$) {
    my ($thisflight, $otherflightjob) = @_;    
    return $otherflightjob =~ m/^([^.]+)\.([^.]+)$/ ? ($1,$2) :
           $otherflightjob =~ m/^\.?([^.]+)$/ ? ($thisflight,$1) :
           die "$otherflightjob ?";
}

sub otherflightjob ($) {
    return flight_otherjob($flight,$_[0]);
}

#---------- running commands eg on targets ----------

sub cmd {
    my ($timeout,$stdout,@cmd) = @_;
    my $child= fork;  die $! unless defined $child;
    if (!$child) {
        if (defined $stdout) {
            open STDOUT, '>&', $stdout
                or die "STDOUT $stdout $cmd[0] $!";
        }
        exec @cmd;
        die "$cmd[0]: $!";
    }
    my $start= time;
    my $r;
    eval {
        local $SIG{ALRM} = sub { die "alarm\n"; };
        alarm($timeout);
        $r= waitpid $child, 0;
        alarm(0);
    };
    if ($@) {
        die unless $@ eq "alarm\n";
        logm("command timed out [$timeout]: @cmd");
        return '(timed out)';
    } else {
	my $finish= time;
	my $took= $finish-$start;
	my $warn= $took > 0.5*$timeout;
	logm(sprintf "execution took %d seconds%s: %s",
	     $took, ($warn ? " [**>$timeout/2**]" : "[<=2x$timeout]"), "@cmd")
	    if $warn or $took > 60;
    }
    die "$r $child $!" unless $r == $child;
    logm("command nonzero waitstatus $?: @cmd") if $?;
    return $?;
}

sub remote_perl_script_open ($$$) {
    my ($userhost, $what, $script) = @_;
    my ($readh,$writeh);
    my ($sshopts) = sshopts();
    my $pid= open2($readh,$writeh, "ssh @$sshopts $userhost perl");
    print $writeh $script."\n__DATA__\n" or die "$what $!";
    my $thing= {
        Read => $readh,
        Write => $writeh,
        Pid => $pid,
        Wait => $what,
        };
    return $thing;
}
sub remote_perl_script_done ($) {
    my ($thing) = @_;
    $thing->{Write}->close() or die "$thing->{What} $!";
    $thing->{Read}->close() or die "$thing->{What} $!";
    $!=0; my $got= waitpid $thing->{Pid}, 0;
    $got==$thing->{Pid} or die "$thing->{What} $!";
    !$? or die "$thing->{What} $?";
}

sub sshuho ($$) { my ($user,$ho)= @_; return "$user\@$ho->{Ip}"; }

sub sshopts () {
    return [ qw(-o StrictHostKeyChecking=no
                -o BatchMode=yes
                -o ConnectTimeout=100
                -o ServerAliveInterval=100
                -o PasswordAuthentication=no
                -o ChallengeResponseAuthentication=no),
             '-o', "UserKnownHostsFile=tmp/t.known_hosts_$flight.$job"
             ];
}

sub tcmdex {
    my ($timeout,$stdout,$cmd,$optsref,@args) = @_;
    logm("executing $cmd ... @args");
    my $r= cmd($timeout,$stdout, $cmd,@$optsref,@args);
    $r and die "status $r";
}

sub tgetfileex {
    my ($ruser, $ho,$timeout, $rsrc,$ldst) = @_;
    unlink $ldst or $!==&ENOENT or die "$ldst $!";
    tcmdex($timeout,undef,
           'scp', sshopts(),
           sshuho($ruser,$ho).":$rsrc", $ldst);
} 
sub target_getfile ($$$$) {
    my ($ho,$timeout, $rsrc,$ldst) = @_;
    tgetfileex('osstest', @_);
}
sub target_getfile_root ($$$$) {
    my ($ho,$timeout, $rsrc,$ldst) = @_;
    tgetfileex('root', @_);
}

sub tputfileex {
    my ($ruser, $ho,$timeout, $lsrc,$rdst, $rsync) = @_;
    my @args= ($lsrc, sshuho($ruser,$ho).":$rdst");
    if (!defined $rsync) {
        tcmdex($timeout,undef,
               'scp', sshopts(),
               @args);
    } else {
        unshift @args, $rsync if length $rsync;
        tcmdex($timeout,undef,
               'rsync', [ '-e', 'ssh '.join(' ',@{ sshopts() }) ],
               @args);
    }
}
sub target_putfile ($$$$;$) {
    # $ho,$timeout,$lsrc,$rdst,[$rsync_opt]
    tputfileex('osstest', @_);
}
sub target_putfile_root ($$$$;$) {
    tputfileex('root', @_);
}
sub target_install_packages {
    my ($ho, @packages) = @_;
    target_cmd_root($ho, "apt-get -y install @packages",
                    300 + 100 * @packages);
}
sub target_install_packages_norec {
    my ($ho, @packages) = @_;
    target_cmd_root($ho,
                    "apt-get --no-install-recommends -y install @packages",
                    300 + 100 * @packages);
}

sub target_somefile_getleaf ($$$) {
    my ($lleaf_ref, $rdest, $ho) = @_;
    if (!defined $$lleaf_ref) {
        $$lleaf_ref= $rdest;
        $$lleaf_ref =~ s,.*/,,;
    }
    $$lleaf_ref= "$ho->{Name}--$$lleaf_ref";
}

sub tpfcs_core {
    my ($tputfilef,$ho,$timeout,$filedata, $rdest,$lleaf) = @_;
    target_somefile_getleaf(\$lleaf,$rdest,$ho);

    my $h= new IO::File "$stash/$lleaf", 'w' or die "$lleaf $!";
    print $h $filedata or die $!;
    close $h or die $!;
    $tputfilef->($ho,$timeout, "$stash/$lleaf", $rdest);
}
sub target_putfilecontents_stash ($$$$;$) {
    my ($ho,$timeout,$filedata,$rdest, $lleaf) = @_;
    tpfcs_core(\&target_putfile, @_);
}
sub target_putfilecontents_root_stash ($$$$;$) {
    my ($ho,$timeout,$filedata,$rdest, $lleaf) = @_;
    tpfcs_core(\&target_putfile_root, @_);
}

sub target_file_exists ($$) {
    my ($ho,$rfile) = @_;
    my $out= target_cmd_output_root($ho, "if test -e $rfile; then echo y; fi");
    return 1 if $out =~ m/^y$/;
    return 0 if $out !~ m/\S/;
    die "$rfile $out ?";
}

sub target_editfile_root ($$$;$$) {
    my $code= pop @_;
    my ($ho,$rfile,$lleaf,$rdest) = @_;

    if (!defined $rdest) {
        $rdest= $rfile;
    }
    target_somefile_getleaf(\$lleaf,$rdest,$ho);
    my $lfile;
    
    for (;;) {
        $lfile= "$stash/$lleaf";
        if (!lstat $lfile) {
            $! == &ENOENT or die "$lfile $!";
            last;
        }
        $lleaf .= '+';
    }
    if ($rdest eq $rfile) {
        logm("editing $rfile as $lfile".'{,.new}');
    } else {
        logm("editing $rfile to $rdest as $lfile".'{,.new}');
    }

    target_getfile($ho, 60, $rfile, $lfile);
    open '::EI', "$lfile" or die "$lfile: $!";
    open '::EO', "> $lfile.new" or die "$lfile.new: $!";

    &$code;

    '::EI'->error and die $!;
    close '::EI' or die $!;
    close '::EO' or die $!;
    target_putfile_root($ho, 60, "$lfile.new", $rdest);
}

sub target_cmd_build ($$$$) {
    my ($ho,$timeout,$builddir,$script) = @_;
    target_cmd($ho, <<END.$script, $timeout);
	set -xe
        LC_ALL=C; export LC_ALL
        PATH=/usr/lib/ccache:\$PATH:/usr/lib/git-core
        exec </dev/null
        cd $builddir
END
}

sub target_ping_check_core {
    my ($ho, $exp) = @_;
    my $out= `ping -c 5 $ho->{Ip} 2>&1`;
    $out =~ s/\b(?:\d+(?:\.\d+)?\/)*\d+(?:\.\d+)? ?ms\b/XXXms/g;
    report_once($ho, 'ping_check',
		"ping $ho->{Ip} ".(!$? ? 'up' : $?==256 ? 'down' : "$? ?"));
    return undef if $?==$exp;
    $out =~ s/\n/ | /g;
    return "ping gave ($?): $out";
}
sub target_ping_check_down ($) { return target_ping_check_core(@_,256); }
sub target_ping_check_up ($) { return target_ping_check_core(@_,0); }

sub target_await_down ($$) {
    my ($ho,$timeout) = @_;
    poll_loop($timeout,5,'reboot-down', sub {
        return target_ping_check_down($ho);
    });
}    

sub tcmd { # $tcmd will be put between '' but not escaped
    my ($stdout,$user,$ho,$tcmd,$timeout) = @_;
    $timeout=30 if !defined $timeout;
    tcmdex($timeout,$stdout,
           'ssh', sshopts(),
           sshuho($user,$ho), $tcmd);
}
sub target_cmd ($$;$) { tcmd(undef,'osstest',@_); }
sub target_cmd_root ($$;$) { tcmd(undef,'root',@_); }

sub tcmdout {
    my $stdout= IO::File::new_tmpfile();
    tcmd($stdout,@_);
    $stdout->seek(0,0) or die "$stdout $!";
    my $r;
    { local ($/) = undef;
      $r= <$stdout>; }
    die "$stdout $!" if !defined $r or $stdout->error or !close $stdout;
    chomp($r);
    return $r;
}

sub target_cmd_output ($$;$) { tcmdout('osstest',@_); }
sub target_cmd_output_root ($$;$) { tcmdout('root',@_); }

sub poll_loop ($$$&) {
    my ($maxwait, $interval, $what, $code) = @_;
    # $code should return undef when all is well
    
    logm("$what: waiting ${maxwait}s...");
    my $start= time;  die $! unless defined $start;
    my $wantwaited= 0;
    my $waited= 0;
    my $bad;
    my $reported= '';
    my $logmtmpfile;

    my $org_logm_handle= $logm_handle;
    my $undivertlogm= sub {
        print $org_logm_handle "...\n";
        seek $logmtmpfile,0,0;
        File::Copy::copy($logmtmpfile, $org_logm_handle);
    };

    for (;;) {
        $logmtmpfile= IO::File::new_tmpfile or die $!;

        if (!eval {
            local ($Osstest::logm_handle) = ($logmtmpfile);
            $bad= $code->();
            1;
        }) {
            $undivertlogm->();
            die "$@";
        }

        my $now= time;  die $! unless defined $now;
        $waited= $now - $start;
        last if !defined $bad;

	if ($reported ne $bad) {
	    logm("$what: $bad (waiting) ...");
	    $reported= $bad;
	}
        last unless $waited <= $maxwait;

        $wantwaited += $interval;
        my $needwait= $wantwaited - $waited;
        sleep($needwait) if $needwait > 0;
    }
    if (defined $bad) {
        $undivertlogm->();
        fail("$what: wait timed out: $bad.");
    }
    logm("$what: ok. (${waited}s)");
}

1;
