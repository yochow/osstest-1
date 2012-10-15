
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
#use Data::Dumper;

BEGIN {
    use Exporter ();
    our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
    $VERSION     = 1.00;
    @ISA         = qw(Exporter);
    @EXPORT      = qw();
    %EXPORT_TAGS = (
	);

    @EXPORT_OK   = qw();
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


BEGIN {
    use Exporter ();
    our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
    $VERSION     = 1.00;
    @ISA         = qw(Exporter);
    @EXPORT      = qw(
                      $logm_handle
                      %c %r $flight $job $stash
                      nonempty
                      dbfl_check get_harness_rev grabrepolock_reexec
                      get_runvar get_runvar_maybe get_runvar_default
                      store_runvar get_stashed open_unique_stashfile
                      broken fail
                      unique_incrementing_runvar system_checked
                      tcpconnect findtask @all_lock_tables
                      tcpconnect_queuedaemon plan_search
                      alloc_resources alloc_resources_rollback_begin_work
                      resource_check_allocated resource_shared_mark_ready
                      built_stash flight_otherjob duration_estimator
                      csreadconfig ts_get_host_guest
                      opendb_state selecthost get_hostflags
                      get_host_property get_timeout
                      need_runvars
                      host_involves_pcipassthrough host_get_pcipassthrough_devs
                      get_filecontents ensuredir postfork
                      poll_loop logm link_file_contents create_webfile
                      contents_make_cpio file_simple_write_contents
                      power_state power_cycle power_cycle_time
                      setup_pxeboot setup_pxeboot_local
                      await_webspace_fetch_byleaf await_tcp
                      remote_perl_script_open remote_perl_script_done sshopts
                      target_cmd_root target_cmd target_cmd_build
                      target_cmd_output_root target_cmd_output
                      target_getfile target_getfile_root
                      target_putfile target_putfile_root
                      target_putfilecontents_stash
		      target_putfilecontents_root_stash
                      target_editfile_root target_file_exists
                      target_install_packages target_install_packages_norec
                      target_extract_jobdistpath
                      host_reboot host_pxedir target_reboot target_reboot_hard
                      target_choose_vg target_umount_lv target_await_down
                      target_ping_check_down target_ping_check_up
                      target_kernkind_check target_kernkind_console_inittab
                      target_var target_var_prefix
                      selectguest prepareguest more_prepareguest_hvm
                      guest_var guest_var_commalist
                      prepareguest_part_lvmdisk prepareguest_part_xencfg
                      guest_umount_lv guest_await guest_await_dhcp_tcp
                      guest_checkrunning guest_check_ip guest_find_ether
                      guest_find_domid guest_check_up guest_check_up_quick
                      guest_get_state guest_await_reboot guest_destroy
                      guest_vncsnapshot_begin guest_vncsnapshot_stash
		      guest_check_remus_ok guest_editconfig
                      dir_identify_vcs build_clone
                      hg_dir_revision git_dir_revision vcs_dir_revision
                      store_revision store_vcs_revision
                      toolstack authorized_keys
                      );
    %EXPORT_TAGS = ( );

    @EXPORT_OK   = qw();
}

augmentconfigdefaults(
    'control-daemon-host' => 'woking.cam.xci-test.com',
    'owner-daemon-port' => 4031,
    'queue-daemon-port' => 4032,
    'queue-daemon-retry' => 120, # seconds
    'queue-daemon-holdoff' => 30, # seconds
    'queue-thoughts-timeout' => 30, # seconds
    'queue-resource-pollinterval' => 60, # seconds
    'queue-plan-update-interval' => 300, # seconds
);

our (%g,%r,$flight,$job,$stash);

our %timeout= qw(RebootDown   100
                 RebootUp     400
                 HardRebootUp 600);

our $logm_handle= new IO::File ">& STDERR" or die $!;

sub nonempty ($) {
    my ($v) = @_;
    return defined($v) && length($v);
}

#---------- configuration reader etc. ----------

sub opendb_tests () {
    $dbh_tests ||= $mjobdb->open();
}

sub csreadconfig () {
    readconfigonly();
    opendb_tests();
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

#---------- test script startup ----------

sub tsreadconfig () {
    # must be run outside transaction
    csreadconfig();

    $flight= $ENV{'OSSTEST_FLIGHT'};
    $job=    $ENV{'OSSTEST_JOB'};
    die unless defined $flight and defined $job;

    my $now= time;  defined $now or die $!;

    db_retry($flight,[qw(running constructing)],
             $dbh_tests,[qw(flights)], sub {
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

sub ts_get_host_guest { # pass this @ARGV
    my ($gn,$whhost) = reverse @_;
    $whhost ||= 'host';
    $gn ||= 'guest';

    my $ho= selecthost($whhost);
    my $gho= selectguest($gn,$ho);
    return ($ho,$gho);
}

#---------- database access ----------#

sub opendb_state () {
    return opendb('statedb');
}

our $whoami;

sub opendb ($) {
    my ($dbname) = @_;

    my $pg= $g{"executive-dbname-$dbname"};

    if (!defined $pg) {
	if (!defined $whoami) {
	    $whoami = `whoami`;  die if $?;  chomp $whoami;
	}
        my $pat= $g{'executive-dbname-pat'};
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

        $pg = $g{"executive-dbname-$dbname"} = $pat;
    }

    my $dbh= DBI->connect("dbi:Pg:$pg", '','', {
        AutoCommit => 1,
        RaiseError => 1,
        ShowErrorStatement => 1,
        })
        or die "could not open state db $pg";
    return $dbh;
}

sub open_unique_stashfile ($) {
    my ($leafref) = @_;
    my $dh;
    for (;;) {
        my $df= $$leafref;
        $dh= new IO::File "$stash/$df", O_WRONLY|O_EXCL|O_CREAT;
        last if $dh;
        die "$df $!" unless $!==&EEXIST;
        $$leafref .= '+';
    }
    return $dh;
}

#---------- runvars ----------

sub flight_otherjob ($$) {
    my ($thisflight, $otherflightjob) = @_;    
    return $otherflightjob =~ m/^([^.]+)\.([^.]+)$/ ? ($1,$2) :
           $otherflightjob =~ m/^\.?([^.]+)$/ ? ($thisflight,$1) :
           die "$otherflightjob ?";
}

sub otherflightjob ($) {
    return flight_otherjob($flight,$_[0]);
}

sub get_stashed ($$) {
    my ($param, $otherflightjob) = @_; 
    # may be run outside transaction, or with flights locked
    my ($oflight, $ojob) = otherflightjob($otherflightjob);
    my $path= get_runvar($param, $otherflightjob);
    die "$path $& " if
        $path =~ m,[^-+._0-9a-zA-Z/], or
        $path =~ m/\.\./;
    return "$c{Stash}/$oflight/$ojob/$path";
}

sub unique_incrementing_runvar ($$) {
    my ($param,$start) = @_;
    # must be run outside transaction
    my $value;
    db_retry($flight,'running', $dbh_tests,[qw(flights)], sub {
	my $row= $dbh_tests->selectrow_arrayref(<<END,{}, $flight,$job,$param);
            SELECT val FROM runvars WHERE flight=? AND job=? AND name=?
END
	$value= $row ? $row->[0] : $start;
	$dbh_tests->do(<<END, undef, $flight, $job, $param);
            DELETE FROM runvars WHERE flight=? AND job=? AND name=? AND synth
END
	$dbh_tests->do(<<END, undef, $flight, $job, $param, $value+1);
            INSERT INTO runvars VALUES (?,?,?,?,'t')
END
    });
    logm("runvar increment: $param=$value");
    return $value;
}

sub store_runvar ($$) {
    my ($param,$value) = @_;
    # must be run outside transaction
    logm("runvar store: $param=$value");
    db_retry($flight,'running', $dbh_tests,[qw(flights)], sub {
        $dbh_tests->do(<<END, undef, $flight, $job, $param);
	    DELETE FROM runvars WHERE flight=? AND job=? AND name=? AND synth
END
        $dbh_tests->do(<<END,{}, $flight,$job, $param,$value);
            INSERT INTO runvars VALUES (?,?,?,?,'t')
END
    });
    $r{$param}= get_runvar($param, "$flight.$job");
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

sub system_checked {
    $!=0; $?=0; system @_;
    die "@_: $? $!" if $? or $!;
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

#---------- other stuff ----------

sub logm ($) {
    my ($m) = @_;
    my @t = gmtime;
    printf $logm_handle "%04d-%02d-%02d %02d:%02d:%02d Z %s\n",
        $t[5]+1900,$t[4]+1,$t[3], $t[2],$t[1],$t[0],
        $m
    or die $!;
    $logm_handle->flush or die $!;
}

sub get_filecontents_core_quiet ($) { # ENOENT => undef
    my ($path) = @_;
    if (!open GFC, '<', $path) {
        $!==&ENOENT or die "$path $!";
        return undef;
    }
    local ($/);
    undef $/;
    my $data= <GFC>;
    defined $data or die "$path $!";
    close GFC or die "$path $!";
    return $data;
}

sub get_filecontents ($;$) {
    my ($path, $ifnoent) = @_;  # $ifnoent=undef => is error
    my $data= get_filecontents_core_quiet($path);
    if (!defined $data) {
        die "$path does not exist" unless defined $ifnoent;
        logm("read $path absent.");
        return $ifnoent;
    }
    logm("read $path ok.");
    return $data;
}

sub ensuredir ($) {
    my ($dir)= @_;
    mkdir($dir) or $!==&EEXIST or die "$dir $!";
}

sub postfork () {
    $dbh_tests->{InactiveDestroy}= 1;  undef $dbh_tests;
}

sub host_reboot ($) {
    my ($ho) = @_;
    target_reboot($ho);
    poll_loop(40,2, 'reboot-confirm-booted', sub {
        my $output;
        if (!eval {
            $output= target_cmd_output($ho,
                "stat /dev/shm/osstest-confirm-booted 2>&1 >/dev/null ||:",
                                       40);
            1;
        }) {
            return $@;
        }
        return length($output) ? $output : undef;
    });
}

sub target_reboot ($) {
    my ($ho) = @_;
    target_cmd_root($ho, "init 6");
    target_await_down($ho, $timeout{RebootDown});
    await_tcp(get_timeout($ho,'reboot',$timeout{RebootUp}), 5,$ho);
}

sub target_reboot_hard ($) {
    my ($ho) = @_;
    power_cycle($ho);
    await_tcp(get_timeout($ho,'reboot',$timeout{HardRebootUp}), 5, $ho);
}

sub tcpconnect ($$) {
    my ($host, $port) = @_;
    my $h= new IO::Handle;
    my $proto= getprotobyname('tcp');  die $! unless defined $proto;
    my $fixedaddr= inet_aton($host);
    my @addrs; my $atype;
    if (defined $fixedaddr) {
        @addrs= $fixedaddr;
        $atype= AF_INET;
    } else {
        $!=0; $?=0; my @hi= gethostbyname($host);
        @hi or die "host lookup failed for $host: $? $!";
        $atype= $hi[2];
        @addrs= @hi[4..$#hi];
        die "connect $host:$port: no addresses for $host" unless @addrs;
    }
    foreach my $addr (@addrs) {
        my $h= new IO::Handle;
        my $sin; my $pfam; my $str;
        if ($atype==AF_INET) {
            $sin= sockaddr_in $port, $addr;
            $pfam= PF_INET;
            $str= inet_ntoa($addr);
#        } elsif ($atype==AF_INET6) {
#            $sin= sockaddr_in6 $port, $addr;
#            $pfam= PF_INET6;
#            $str= inet_ntoa6($addr);
        } else {
            warn "connect $host:$port: unknown AF $atype";
            next;
        }
        if (!socket($h, $pfam, SOCK_STREAM, $proto)) {
            warn "connect $host:$port: unsupported PF $pfam";
            next;
        }
        if (!connect($h, $sin)) {
            warn "connect $host:$port: [$str]: $!";
            next;
        }
        return $h;

    }
    die "$host:$port all failed";
}

sub contents_make_cpio ($$$) {
    my ($fh, $format, $srcdir) = @_;
    my $child= fork;  defined $child or die $!;
    if (!$child) {
        postfork();
        chdir($srcdir) or die $!;
        open STDIN, 'find ! -name "*~" ! -name "#*" -type f -print0 |'
            or die $!;
        open STDOUT, '>&', $fh or die $!;
        system "cpio -H$format -o --quiet -0 -R 1000:1000";
        $? and die $?;
        $!=0; close STDIN; die "$! $?" if $! or $?;
        exit 0;
    }
    waitpid($child, 0) == $child or die $!;
    $? and die $?;
}

#---------- building, vcs's, etc. ----------

sub build_clone ($$$$) {
    my ($ho, $which, $builddir, $subdir) = @_;

    need_runvars("tree_$which", "revision_$which");

    my $tree= $r{"tree_$which"};
    my $timeout= 4000;

    my $vcs = $r{"treevcs_$which"};
    if (defined $vcs) {
    } elsif ($tree =~ m/\.hg$/) {
        $vcs= 'hg';
    } elsif ($tree =~ m/\.git$/) {
        $vcs= 'git';
    } else {
        die "unknown vcs for $which $tree ";
    }

    if ($vcs eq 'hg') {
        
        target_cmd_build($ho, $timeout, $builddir, <<END.
	    hg clone '$tree' $subdir
	    cd $subdir
END
                         (length($r{"revision_$which"}) ? <<END : ''));
	    hg update '$r{"revision_$which"}'
END
    } elsif ($vcs eq 'git') {

        target_cmd_build($ho, $timeout, $builddir, <<END.
            git clone '$tree' $subdir
            cd $subdir
END
                         (length($r{"revision_$which"}) ? <<END : ''));
	    git checkout '$r{"revision_$which"}'
END
    } else {
        die "$vcs $which $tree ?";
    }

    my $rev= vcs_dir_revision($ho, "$builddir/$subdir", $vcs);
    store_vcs_revision($which, $rev, $vcs);
}

sub dir_identify_vcs ($$) {
    my ($ho,$dir) = @_;
    return target_cmd_output($ho, <<END);
        set -e
        if ! test -e $dir; then echo none; exit 0; fi
        cd $dir
        (test -d .git && echo git) ||
        (test -d .hg && echo hg) ||
        (echo >&2 'unable to determine vcs'; fail)
END
}

sub store_revision ($$$;$) {
    my ($ho,$which,$dir,$optional) = @_;
    my $vcs= dir_identify_vcs($ho,$dir);
    return if $optional && $vcs eq 'none';
    my $rev= vcs_dir_revision($ho,$dir,$vcs);
    store_vcs_revision($which,$rev,$vcs);
}

sub store_vcs_revision ($$$) {
    my ($which,$rev,$vcs) = @_;
    store_runvar("built_vcs_$which", $vcs);
    store_runvar("built_revision_$which", $rev);
}

sub built_stash ($$$$) {
    my ($ho, $builddir, $distroot, $item) = @_;
    target_cmd($ho, <<END, 300);
	set -xe
	cd $builddir
        cd $distroot
        tar zcf $builddir/$item.tar.gz *
END
    my $build= "build";
    my $stashleaf= "$build/$item.tar.gz";
    ensuredir("$stash/$build");
    target_getfile($ho, 300,
                   "$builddir/$item.tar.gz",
                   "$stash/$stashleaf");
    store_runvar("path_$item", $stashleaf);
}

sub vcs_dir_revision ($$$) {
    my ($ho,$builddir,$vcs) = @_;
    no strict qw(refs);
    return &{"${vcs}_dir_revision"}($ho,$builddir);
}

sub hg_dir_revision ($$) {
    my ($ho,$builddir) = @_;
    my $rev= target_cmd_output($ho, "cd $builddir && hg identify -ni", 100);
    $rev =~ m/^([0-9a-f]{10,}\+?) (\d+\+?)$/ or die "$builddir $rev ?";
    return "$2:$1";
}

sub git_dir_revision ($$) {
    my ($ho,$builddir) = @_;
    my $rev= target_cmd_output($ho, "cd $builddir && git rev-parse HEAD^0");
    $rev =~ m/^([0-9a-f]{10,})$/ or die "$builddir $rev ?";
    return "$1";
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
    my $qserv= tcpconnect($c{ControlDaemonHost}, $c{QueueDaemonPort});
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
    my ($resourcecall) = pop @_;
    my (%xparams) = @_;
    # $resourcecall should die (abort) or return ($ok, $bookinglist)
    #
    #  values of $ok
    #            0  rollback, wait and try again
    #            1  commit, completed ok
    #            2  commit, wait and try again
    #  $bookinglist should be undef or a hash for making a booking
    #
    # $resourcecall should not look at tasks.live
    #  instead it should look for resources.owntaskid == the allocatable task
    # $resourcecall runs with all tables locked (see above)

    my $qserv;
    my $retries=0;
    my $ok=0;

    logm("resource allocation: starting...");

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

    while ($ok==0 || $ok==2) {
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
		logm("resource allocation: base plan $jplanprint");
		$plan= from_json($jplan);
	    }, sub {
		if (!eval {
		    ($ok, $bookinglist) = $resourcecall->($plan);
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
                logm("resource allocation: booking $jbookings");

		printf $qserv "book-resources %d\n", length $jbookings
		    or die $!;
		$_= <$qserv>; defined && m/^SEND\s/ or die "$_ ?";

		print $qserv $jbookings or die $!;
		$_= <$qserv>; defined && m/^OK book-resources\s/ or die "$_ ?";

                $bookinglist= undef; # no need to undo these then

		logm("resource allocation: we are in the plan.");
	    }

            if ($ok==1) {
                print $qserv "thought-done\n" or die $!;
            } elsif ($ok<0) {
                return 1;
            } else { # 0 or 2
                logm("resource allocation: deferring") if $ok==0;
                logm("resource allocation: partial commit, deferring");
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
                        logm("resource allocation: unwinding @reskey");
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
                $dbg->("REF $ref->{flight} DURATION $duration");
                $duration_max= $duration
                    if $duration > $duration_max;
            }
        }

        return ($duration_max, $refs->[0]{started}, $refs->[0]{status});
    };
}

#---------- hosts and guests ----------

sub get_hostflags ($) {
    my ($ident) = @_;
    # may be run outside transaction, or with flights locked
    my $flags= get_runvar_default('all_hostflags',     $job, '').','.
               get_runvar_default("${ident}_hostflags", $job, '');
    return grep /./, split /\,/, $flags;
}

sub get_host_property ($$;$) {
    my ($ho, $prop, $defval) = @_;
    my $row= $ho->{Properties}{$prop};
    return $defval unless $row && defined $row->{val};
    return $row->{val};
}

sub host_involves_pcipassthrough ($) {
    my ($ho) = @_;
    return !!grep m/^pcipassthrough\-/, get_hostflags($ho->{Ident});
}

sub host_get_pcipassthrough_devs ($) {
    my ($ho) = @_;
    my @devs;
    foreach my $prop (values %{ $ho->{Properties} }) {
        next unless $prop->{name} =~ m/^pcipassthrough (\w+)$/;
        my $devtype= $1;
        next unless grep { m/^pcipassthrough-$devtype$/ } get_hostflags($ho);
        $prop->{val} =~ m,^([0-9a-f]+\:[0-9a-f]+\.\d+)/, or
            die "$ho->{Ident} $prop->{val} ?";
        push @devs, {
            DevType => $devtype,
            Bdf => $1,
            Info => $' #'
            };
    }
    return @devs;
}

sub selecthost ($) {
    my ($ident) = @_;
    # must be run outside transaction
    my $name;
    if ($ident =~ m/=/) {
        $ident= $`;
        $name= $'; #'
        $r{$ident}= $name;
    } else {
        $name= $r{$ident};
        die "no specified $ident" unless defined $name;
    }

    my $ho= {
        Ident => $ident,
        Name => $name,
        TcpCheckPort => 22,
        Fqdn => "$name.$c{TestHostDomain}",
        Info => [],
        Suite => get_runvar_default("${ident}_suite",$job,$c{Suite}),
    };

    $ho->{Properties}= $dbh_tests->selectall_hashref(<<END, 'name', {}, $name);
        SELECT * FROM resource_properties
            WHERE restype='host' AND resname=?
END

    my $getprop= sub {
        my ($k,$r) = @_;
        my $row= $ho->{Properties}{$r};
        return unless $row;
        $ho->{$k}= $row->{val};
    };
    $ho->{Ether}= get_host_property($ho,'ether');
    $ho->{Power}= get_host_property($ho,'power-method');
    $ho->{DiskDevice}= get_host_property($ho,'disk-device');
    $ho->{DhcpLeases}= get_host_property($ho,'dhcp-leases',$c{Dhcp3Leases});

    if (!$ho->{Ether} || !$ho->{Power}) {
        my $dbh_config= opendb('configdb');
        my $selname= $ho->{Fqdn};
        my $sth= $dbh_config->prepare(<<END);
            SELECT * FROM ips WHERE reverse_dns = ?
END
        $sth->execute($selname);
        my $row= $sth->fetchrow_hashref();
        die "$ident $name $selname ?" unless $row;
        die if $sth->fetchrow_hashref();
        $sth->finish();
        my $get= sub {
            my ($k,$nowarn) = @_;
            my $v= $row->{$k};
            defined $v or $nowarn or
                warn "host $name: undefined $k in configdb::ips\n";
            return $v;
        };
        $ho->{Asset}= $get->('asset',1);
        $ho->{Ether} ||= $get->('hardware');
        $ho->{Power} ||= "statedb $ho->{Asset}";
        push @{ $ho->{Info} }, "(asset=$ho->{Asset})" if defined $ho->{Asset};
        $dbh_config->disconnect();
    }

    my $ip_packed= gethostbyname($ho->{Fqdn});
    die "$ho->{Fqdn} ?" unless $ip_packed;
    $ho->{Ip}= inet_ntoa($ip_packed);
    die "$ho->{Fqdn} ?" unless defined $ho->{Ip};

    $ho->{Flags}= { };
    my $flagsq= $dbh_tests->prepare(<<END);
        SELECT hostflag FROM hostflags WHERE hostname=?
END
    $flagsq->execute($name);
    while (my ($flag) = $flagsq->fetchrow_array()) {
        $ho->{Flags}{$flag}= 1;
    }
    $flagsq->finish();

    $ho->{Shared}= resource_check_allocated('host', $name);
    $ho->{SharedReady}=
        $ho->{Shared} &&
        $ho->{Shared}{State} eq 'ready' &&
        !! grep { $_ eq "share-".$ho->{Shared}{Type} } get_hostflags($ident);
    $ho->{SharedOthers}=
        $ho->{Shared} ? $ho->{Shared}{Others} : 0;

    logm("host: selected $ho->{Name} $ho->{Ether} $ho->{Ip}".
         (!$ho->{Shared} ? '' :
          sprintf(" - shared %s %s %d", $ho->{Shared}{Type},
                  $ho->{Shared}{State}, $ho->{Shared}{Others}+1)));
    
    return $ho;
}

sub get_timeout ($$$) {
    my ($ho,$which,$default) = @_;
    return $default + get_host_property($ho, "$which-time-extra", 0);
}

sub guest_find_tcpcheckport ($) {
    my ($gho) = @_;
    $gho->{TcpCheckPort}= $r{"$gho->{Guest}_tcpcheckport"};
    $gho->{PingBroken}= $r{"$gho->{Guest}_pingbroken"};
}

sub selectguest ($$) {
    my ($gn,$ho) = @_;
    my $gho= {
        Guest => $gn,
        Name => $r{"${gn}_hostname"},
        CfgPath => $r{"${gn}_cfgpath"},
	Host => $ho,
    };
    foreach my $opt (guest_var_commalist($gho,'options')) {
        $gho->{Options}{$opt}++;
    }
    guest_find_lv($gho);
    guest_find_ether($gho);
    guest_find_tcpcheckport($gho);
    return $gho;
}

sub guest_find_lv ($) {
    my ($gho) = @_;
    my $gn= $gho->{Guest};
    $gho->{Vg}= $r{"${gn}_vg"};
    $gho->{Lv}= $r{"${gn}_disk_lv"};
    $gho->{Lvdev}= (defined $gho->{Vg} && defined $gho->{Lv})
        ? '/dev/'.$gho->{Vg}.'/'.$gho->{Lv} : undef;
}

sub guest_find_ether ($) {
    my ($gho) = @_;
    $gho->{Ether}= $r{"$gho->{Guest}_ether"};
}

sub report_once ($$$) {
    my ($ho, $what, $msg) = @_;
    my $k= "Lastmsg_$what";
    return if defined($ho->{$k}) and $ho->{$k} eq $msg;
    logm($msg);
    $ho->{$k}= $msg;
}

sub guest_check_ip ($) {
    my ($gho) = @_;

    guest_find_ether($gho);

    my $leases;
    my $leasesfn = $gho->{DhcpLeases} || $gho->{Host}{DhcpLeases};

    if ($leasesfn =~ m,/,) {
	$leases= new IO::File $leasesfn, 'r';
	if (!defined $leases) { return "open $leasesfn: $!"; }
    } else {
	$leases= new IO::Socket::INET(PeerAddr => $leasesfn);
    }

    my $lstash= "dhcpleases-$gho->{Guest}";
    my $inlease;
    my $props;
    my $best;
    my @warns;

    my $copy= new IO::File "$stash/$lstash.new", 'w';
    $copy or die "$lstash.new $!";

    my $saveas= sub {
        my ($fn,$keep) = @_;

        while (<$leases>) { print $copy $_ or die $!; }
        die $! unless $leases->eof;

        my $rename= sub {
            my ($src,$dst) = @_;
            rename "$stash/$src", "$stash/$dst"
                or $!==&ENOENT
                or die "rename $fn.$keep $!";
        };
        while (--$keep>0) {
            $rename->("$fn.$keep", "$fn.".($keep+1));
        }
        if ($keep>=0) {
            die if $keep;
            $rename->("$fn", "$fn.$keep");
        }
        $copy->close();
        rename "$stash/$lstash.new", "$stash/$fn" or die "$lstash.new $fn $!";
        logm("warning: $_") foreach grep { defined } @warns[0..5];
        logm("$fn: rotated and stashed current leases");
    };

    my $badleases= sub {
        my ($m) = @_;
        $m= "$leasesfn:$.: unknown syntax";
        $saveas->("$lstash.bad", 7);
        return $m;
    };

    while (<$leases>) {
        print $copy $_ or die $!;

        chomp; s/^\s+//; s/\s+$//;
        next if m/^\#/;  next unless m/\S/;
        if (m/^lease\s+([0-9.]+)\s+\{$/) {
            return $badleases->("lease inside lease") if defined $inlease;
            $inlease= $1;
            $props= { };
            next;
        }
        if (!m/^\}$/) {
            s/^( hardware \s+ ethernet |
                 binding \s+ state
               ) \s+//x
               or
            s/^( [-a-z0-9]+
               ) \s+//x
               or
              return $badleases->("unknown syntax");
            my $prop= $1;
            s/\s*\;$// or return $badleases->("missing semicolon");
            $props->{$prop}= $_;
            next;
        }
        return $badleases->("end lease not inside lease")
            unless defined $inlease;

        $props->{' addr'}= $inlease;
        undef $inlease;

        # got a lease in $props

        # ignore old leases
        next if exists $props->{'binding state'} &&
            lc $props->{'binding state'} ne 'active';

        # ignore leases we don't understand
        my @missing= grep { !defined $props->{$_} }
            ('binding state', 'hardware ethernet', 'ends');
        if (@missing) {
            push @warns, "$leasesfn:$.: lease without \`$_'"
                foreach @missing;
            next;
        }

        # ignore leases for other hosts
        next unless lc $props->{'hardware ethernet'} eq lc $gho->{Ether};

        $props->{' ends'}= $props->{'ends'};
        $props->{' ends'} =~
            s/^[0-6]\s+(\S+)\s+(\d+)\:(\d+\:\d+)$/
                sprintf "%s %02d:%s", $1,$2,$3 /e
                or return $badleases->("unexpected syntax for ends");

        next if $best &&
            $best->{' ends'} gt $props->{' ends'};
        $best= $props;
    }

    if (!$best) {
        $saveas->("$lstash.nolease", 3);
        return "no active lease";
    }
    $gho->{Ip}= $best->{' addr'};

    report_once($gho, 'guest_check_ip', 
		"guest $gho->{Name}: $gho->{Ether} $gho->{Ip}");
    return undef;
}

sub guest_editconfig ($$$) {
    my ($ho, $gho, $code) = @_;
    target_editfile_root($ho, "$gho->{CfgPath}", sub {
        while (<::EI>) {
            $code->();
            print ::EO or die $!;
        }
        die $! if ::EI->error;
    });
}

sub guest_await_reboot ($$$) {
    my ($ho,$gho, $timeout) = @_;
    poll_loop($timeout, 30, "await reboot request from $gho->{Guest}", sub {
        my $st= guest_get_state($ho,$gho);
        return undef if $st eq 'sr';
        fail("guest unexpectedly shutdown; state is '$st'")
            if $st =~ m/^s/ || $st eq '';
        return "guest state is $st";
    });
}

sub guest_destroy ($$) {
    my ($ho,$gho) = @_;
    target_cmd_root($ho, toolstack()->{Command}." destroy $gho->{Name}", 40);
}    

sub target_choose_vg ($$) {
    my ($ho, $mbneeded) = @_;
    my $vgs= target_cmd_output_root($ho, 'vgdisplay --colon');
    my $bestkb= 1.0e90;
    my $bestvg;
    foreach my $l (split /\n/, $vgs) {
        $l =~ s/^\s+//; $l =~ s/\s+$//;
        my @l= split /\:/, $l;
        my $tvg= $l[0];
        my $pesize= $l[12];
        my $freepekb= $l[15];
        my $tkb= $l[12] * 1.0 * $l[15];
        if ($tkb < $mbneeded*1024.0) {
            logm("vg $tvg ${tkb}kb free - too small");
            next;
        }
        if ($tkb < $bestkb) {
            $bestvg= $tvg;
            $bestkb= $tkb;
        }
    }
    die "no vg of sufficient size"
        unless defined $bestvg;
    logm("vg $bestvg ${bestkb}kb free - will use");
    return $bestvg;
}

sub select_ether ($) {
    my ($vn) = @_;
    # must be run outside transaction
    my $ether= $r{$vn};
    return $ether if defined $ether;
    my $prefix= sprintf "%s:%02x", $c{GenEtherPrefix}, $flight & 0xff;

    db_retry($flight,'running', $dbh_tests,[qw(flights)], sub {
        my $previous= $dbh_tests->selectrow_array(<<END, {}, $flight);
            SELECT max(val) FROM runvars WHERE flight=?
                AND name LIKE E'%\\_ether'
                AND val LIKE '$prefix:%'
END
        if (defined $previous) {
            $previous =~ m/^\w+:\w+:\w+:\w+:([0-9a-f]+):([0-9a-f]+)$/i
                or die "$previous ?";
            my $val= (hex($1)<<8) | hex($2);
            $val++;  $val &= 0xffff;
            $ether= sprintf "%s:%02x:%02x", $prefix, $val >> 8, $val & 0xff;
            logm("select_ether $prefix:... $ether (previous $previous)");
        } else {
            $ether= "$prefix:00:01";
            logm("select_ether $prefix:... $ether (first in flight)");
        }
        $dbh_tests->do(<<END, {}, $flight,$job,$vn,$ether);
            INSERT INTO runvars VALUES (?,?,?,?,'t')
END
        my $chkrow= $dbh_tests->selectrow_hashref(<<END,{}, $flight);
	    SELECT val, count(*) FROM runvars WHERE flight=?
                AND name LIKE E'%\\_ether'
                AND val LIKE '$prefix:%'
		GROUP BY val
		HAVING count(*) <> 1
		LIMIT 1
END
	die "$chkrow->{val} $chkrow->{count}" if $chkrow;
    });
    $r{$vn}= $ether;
    return $ether;
}

sub guest_var ($$$) {
    my ($gho, $runvartail, $default) = @_;
    my $val= $r{ $gho->{Guest}."_".$runvartail };  return $val if defined $val;
    $val= $r{ "guests_$runvartail" };              return $val if defined $val;
    return $default;
}

sub guest_var_commalist ($$) {
    my ($gho,$runvartail) = @_;
    return split /\,/, guest_var($gho,$runvartail,'');
}

sub prepareguest ($$$$$$) {
    my ($ho, $gn, $hostname, $tcpcheckport, $mb,
        $boot_timeout) = @_;
    # must be run outside transaction

    # If we are passing through a nic, use its mac address not a generated one
    my $ptnichostident= $r{"${gn}_pcipassthrough_nic"};
    if (!$ptnichostident) {
        select_ether("${gn}_ether");
    } else {
        my $ptnicho= selecthost($ptnichostident);
        my $ptnicinfo= get_host_property($ptnicho,'pcipassthrough nic');
        $ptnicinfo =~ m,/, or die "$ptnichostident $ptnicinfo ?";
        my $ptether= $'; #'
        $r{"${gn}_ether"}= $ptether;
        logm("passthrough nic from $ptnichostident ether $ptether");
    }

    store_runvar("${gn}_hostname", $hostname);
    store_runvar("${gn}_disk_lv", $r{"${gn}_hostname"}.'-disk');
    store_runvar("${gn}_tcpcheckport", $tcpcheckport);
    store_runvar("${gn}_boot_timeout", $boot_timeout);

    my $gho= selectguest($gn, $ho);
    store_runvar("${gn}_domname", $gho->{Name});

    store_runvar("${gn}_vg", '');
    if (!length $r{"${gn}_vg"}) {
        store_runvar("${gn}_vg", target_choose_vg($ho, $mb));
    }

    guest_find_lv($gho);
    guest_find_ether($gho);
    guest_find_tcpcheckport($gho);
    return $gho;
}

sub prepareguest_part_lvmdisk ($$$) {
    my ($ho, $gho, $disk_mb) = @_;
    target_cmd_root($ho, "lvremove -f $gho->{Lvdev} ||:");
    target_cmd_root($ho, "lvcreate -L ${disk_mb}M -n $gho->{Lv} $gho->{Vg}");
    target_cmd_root($ho, "dd if=/dev/zero of=$gho->{Lvdev} count=10");
}    

sub prepareguest_part_xencfg ($$$$$) {
    my ($ho, $gho, $ram_mb, $xopts, $cfgrest) = @_;
    my $onreboot= $xopts->{OnReboot} || 'restart';
    my $vcpus= guest_var($gho, 'vcpus', $xopts->{DefVcpus} || 2);
    my $xoptcfg= $xopts->{ExtraConfig};
    $xoptcfg='' unless defined $xoptcfg;
    my $xencfg= <<END;
name        = '$gho->{Name}'
memory = ${ram_mb}
vif         = [ 'type=ioemu,mac=$gho->{Ether}' ]
#
on_poweroff = 'destroy'
on_reboot   = '$onreboot'
on_crash    = 'preserve'
#
vcpus = $vcpus
#
$cfgrest
#
$xoptcfg
END

    my $cfgpath= "/etc/xen/$gho->{Name}.cfg";
    store_runvar("$gho->{Guest}_cfgpath", "$cfgpath");
    $gho->{CfgPath}= $cfgpath;

    target_putfilecontents_root_stash($ho,30,$xencfg, $cfgpath);

    return $cfgpath;
}

sub more_prepareguest_hvm ($$$$;@) {
    my ($ho, $gho, $ram_mb, $disk_mb, %xopts) = @_;
    
    my $passwd= 'xenvnc';

    prepareguest_part_lvmdisk($ho, $gho, $disk_mb);
    
    my $specimage= $r{"$gho->{Guest}_image"};
    die "$gho->{Guest} ?" unless $specimage;
    my $limage= $specimage =~ m,^/, ? $specimage : "$c{Images}/$specimage";
    $gho->{Rimage}= "/root/$flight.$job.".basename($specimage);
    target_putfile_root($ho, 1000, $limage,$gho->{Rimage}, '-p');

    my $postimage_hook= $xopts{PostImageHook};
    $postimage_hook->() if $postimage_hook;

    my $cfg = <<END;
kernel      = 'hvmloader'
builder     = 'hvm'
#
disk        = [
            'phy:$gho->{Lvdev},hda,w',
            'file:$gho->{Rimage},hdc:cdrom,r'
            ]
#
usb=1
usbdevice='tablet'
#
#stdvga=1
keymap='en-gb';
#
sdl=0
opengl=0
vnc=1
vncunused=1
vncdisplay=0
vnclisten='$ho->{Ip}'
vncpasswd='$passwd'

serial='file:/dev/stderr'
#
boot = 'dc'
END

    my $devmodel = $r{'device_model_version'};
    if (defined $devmodel) {
        $cfg .= "device_model_version='$devmodel'\n";
    }

    my $cfgpath= prepareguest_part_xencfg($ho, $gho, $ram_mb, \%xopts, $cfg);
    target_cmd_root($ho, <<END);
        (echo $passwd; echo $passwd) | vncpasswd $gho->{Guest}.vncpw
END

    return $cfgpath;
}

sub guest_check_via_ssh ($) {
    my ($gho) = @_;
    return $r{"$gho->{Guest}_tcpcheckport"} == 22;
}

sub guest_check_up_quick ($) {
    my ($gho) = @_;
    if (guest_check_via_ssh($gho)) {
	target_cmd_root($gho, "date");
    } else {
	target_ping_check_up($gho);
    }
}

sub guest_check_up ($) {
    my ($gho) = @_;
    guest_await_dhcp_tcp($gho,20);
    target_ping_check_up($gho);
    target_cmd_root($gho, "echo guest $gho->{Name}: ok")
        if guest_check_via_ssh($gho);
}

sub guest_get_state ($$) {
    my ($ho,$gho) = @_;
    my $domains= target_cmd_output_root($ho, toolstack()->{Command}." list");
    $domains =~ s/^Name.*\n//;
    foreach my $l (split /\n/, $domains) {
        $l =~ m/^(\S+) (?: \s+ \d+ ){3} \s+ ([-a-z]+) \s/x or die "$l ?";
        next unless $1 eq $gho->{Name};
        my $st= $2;
        $st =~ s/\-//g;
        $st='-' if !length $st;
        logm("guest $gho->{Name} state is $st");
        return $st;
    }
    logm("guest $gho->{Name} not present on this host");
    return '';
}

our $guest_state_running_re= '[-rb]+';

sub guest_checkrunning ($$) {
    my ($ho,$gho) = @_;
    my $s= guest_get_state($ho,$gho);
    return $s =~ m/^$guest_state_running_re$/o;
}

sub guest_await_dhcp_tcp ($$) {
    my ($gho,$timeout) = @_;
    guest_find_tcpcheckport($gho);
    poll_loop($timeout,1,
              "guest $gho->{Name} $gho->{Ether} $gho->{TcpCheckPort}".
              " link/ip/tcp",
              sub {
        my $err= guest_check_ip($gho);
        return $err if defined $err;

        return
            ($gho->{PingBroken} ? undef : target_ping_check_up($gho))
            ||
            target_tcp_check($gho,5)
            ||
            undef;
    });
}

sub guest_check_remus_ok {
    my ($gho, @hos) = @_;
    my @sts;
    logm("remus check $gho->{Name}...");
    foreach my $ho (@hos) {
	my $st;
	if (!eval {
	    $st= guest_get_state($ho, $gho)
        }) {
	    $st= '_';
	    logm("could not get guest $gho->{Name} state on $ho->{Name}: $@");
	}
	push @sts, [ $ho, $st ];
    }
    my @ststrings= map { $_->[1] } @sts;
    my $compound= join ',', @ststrings;
    my $msg= "remus check $gho->{Name}: result \"$compound\":";
    $msg .= " $_->[0]{Name}=$_->[1]" foreach @sts;
    logm($msg);
    my $runnings= scalar grep { m/$guest_state_running_re/o } @ststrings;
    die "running on multiple hosts $compound" if $runnings > 1;
    die "not running anywhere $compound" unless $runnings;
    die "crashed somewhere $compound" if grep { m/c/ } @ststrings;
}

sub power_cycle_time ($) {
    my ($ho) = @_;
    return get_host_property($ho, 'power-cycle-time', 5);
}

sub power_cycle ($) {
    my ($ho) = @_;
    power_state($ho, 0);
    sleep(power_cycle_time($ho));
    power_state($ho, 1);
}

sub power_state_await ($$$) {
    my ($sth, $want, $msg) = @_;
    poll_loop(30,1, "power: $msg $want", sub {
        $sth->execute();
        my ($got) = $sth->fetchrow_array();
        $sth->finish();
        return undef if $got eq $want;
        return "state=\"$got\"";
    });
}

sub power_state ($$) {
    my ($ho, $on) = @_;

    foreach my $meth (split /\;\s*/, $ho->{Power}) {
        my (@meth) = split /\s+/, $meth;
        logm("power: setting $on for $ho->{Name} (@meth)");
        no strict qw(refs);
        &{"power_state__$meth[0]"}($ho,$on,@meth);
    }
}

sub power_state__statedb {
    my ($ho,$on, $methname,$asset) = @_;

    my $want= (qw(s6 s1))[!!$on];

    my $dbh_state= opendb_state();
    my $sth= $dbh_state->prepare
        ('SELECT current_power FROM control WHERE asset = ?');

    my $current= $dbh_state->selectrow_array
        ('SELECT desired_power FROM control WHERE asset = ?',
         undef, $asset);
    die "not found $asset" unless defined $current;

    $sth->bind_param(1, $asset);
    power_state_await($sth, $current, 'checking');

    my $rows= $dbh_state->do
        ('UPDATE control SET desired_power=? WHERE asset=?',
         undef, $want, $asset);
    die "$rows updating desired_power for $asset in statedb::control\n"
        unless $rows==1;
    
    $sth->bind_param(1, $asset);
    power_state_await($sth, $want, 'awaiting');
    $sth->finish();

    $dbh_state->disconnect();
}

sub power_state__msw {
    my ($ho,$on, $methname,$pdu,$port) = @_;
    my $onoff= $on ? "on" : "off";
    system_checked("./pdu-msw $pdu $port $onoff");
}

sub file_simple_write_contents ($$) {
    my ($real, $contents) = @_;
    # $contents may be a coderef in which case we call it with the
    #  filehandle to allow caller to fill in the file

    unlink $real or $!==&ENOENT or die "$real $!";
    my $flc= new IO::File "$real",'w' or die "$real $!";
    if (ref $contents eq 'CODE') {
        $contents->($flc);
    } else {
        print $flc $contents or die "$real $!";
    }
    close $flc or die "$real $!";
}

sub file_link_contents ($$) {
    my ($fn, $contents) = @_;
    # $contents as for file_write_contents
    my ($dir, $base, $ext) =
        $fn =~ m,^( (?: .*/ )? )( [^/]+? )( (?: \.[^./]+ )? )$,x
        or die "$fn ?";
    my $real= "$dir$base--osstest$ext";
    my $linktarg= "$base--osstest$ext";

    file_simple_write_contents($real, $contents);

    my $newlink= "$dir$base--newlink$ext";

    if (!lstat "$fn") {
        $!==&ENOENT or die "$fn $!";
    } elsif (!-l _) {
        die "$fn not a symlink";
        unlink $fn or die "$fn $!";
    }
    symlink $linktarg, $newlink or die "$newlink $!";
    rename $newlink, $fn or die "$newlink $fn $!";
    logm("wrote $fn");
}

sub host_pxedir ($) {
    my ($ho) = @_;
    my $dir= $ho->{Ether};
    $dir =~ y/A-Z/a-z/;
    $dir =~ y/0-9a-f//cd;
    length($dir)==12 or die "$dir";
    $dir =~ s/../$&-/g;
    $dir =~ s/\-$//;
    return $dir;
}

sub setup_pxeboot ($$) {
    my ($ho, $bootfile) = @_;
    my $dir= host_pxedir($ho);
    file_link_contents($c{Tftp}."/$dir/pxelinux.cfg", $bootfile);
}

sub setup_pxeboot_local ($) {
    my ($ho) = @_;
    setup_pxeboot($ho, <<END);
serial 0 $c{Baud}
timeout 5
label local
	LOCALBOOT 0
default local
END
}

sub target_umount_lv ($$$) {
    my ($ho,$vg,$lv) = @_;
    my $dev= "/dev/$vg/$lv";
    for (;;) {
	my $link= target_cmd_output_root($ho, "readlink $dev");
	return if $link =~ m,^/dev/nbd,; # can't tell if it's open
        $lv= target_cmd_output_root($ho, "lvdisplay --colon $dev");
        $lv =~ s/^\s+//;  $lv =~ s/\s+$//;
        my @lv = split /:/, $lv;
        die "@lv ?" unless $lv[0] eq $dev;
        return unless $lv[5]; # "open"
        logm("lvdisplay output says device is still open: $lv");
        target_cmd_root($ho, "umount $dev");
    }
}

sub guest_umount_lv ($$) {
    my ($ho,$gho) = @_;
    target_umount_lv($ho, $gho->{Vg}, $gho->{Lv});
}

sub await_webspace_fetch_byleaf ($$$$$) {
    my ($maxwait,$interval,$logtailer, $ho, $url) = @_;
    my $leaf= $url;
    $leaf =~ s,.*/,,;
    poll_loop($maxwait,$interval, "fetch $leaf", sub {
        my ($line, $last);
        $last= '(none)';
        while (defined($line= $logtailer->getline())) {
            my ($ip, $got) = $line =~
                m,^([0-9.]+) \S+ \S+ \[[^][]+\] \"GET \S*/(\S+) ,
                or next;
            next unless $ip eq $ho->{Ip};
            $last= $got;
            next unless $got eq $leaf;
            return undef;
        }
        return $last;
    });
}

sub target_tcp_check ($$) {
    my ($ho,$interval) = @_;
    my $ncout= `nc -n -v -z -w $interval $ho->{Ip} $ho->{TcpCheckPort} 2>&1`;
    return undef if !$?;
    $ncout =~ s/\n/ | /g;
    return "nc: $? $ncout";
}

sub await_tcp ($$$) {
    my ($maxwait,$interval,$ho) = @_;
    poll_loop($maxwait,$interval,
              "await tcp $ho->{Name} $ho->{TcpCheckPort}",
              sub {
        return target_tcp_check($ho,$interval);
    });
}

sub guest_await ($$) {
    my ($gho,$dhcpwait) = @_;
    guest_await_dhcp_tcp($gho,$dhcpwait);
    target_cmd_root($gho, "echo guest $gho->{Name}: ok")
        if guest_check_via_ssh($gho);
    return $gho;
}

sub create_webfile ($$$) {
    my ($ho, $tail, $contents) = @_; # $contents as for file_link_contents
    my $wf_common= $c{WebspaceCommon}.$ho->{Name}."_".$tail;
    my $wf_url= $c{WebspaceUrl}.$wf_common;
    my $wf_file= $c{WebspaceFile}.$wf_common;
    file_link_contents($wf_file, $contents);
    return $wf_url;
}

sub target_var_prefix ($) {
    my ($ho) = @_;
    if (exists $ho->{Guest}) { return $ho->{Guest}.'_'; }
    return '';
}

sub target_var ($$) {
    my ($ho,$vn) = @_;
    return $r{ target_var_prefix($ho). $vn };
}

sub target_kernkind_check ($) {
    my ($gho) = @_;
    my $pfx= target_var_prefix($gho);
    my $kernkind= $r{$pfx."kernkind"};
    my $isguest= exists $gho->{Guest};
    if ($kernkind eq 'pvops') {
        store_runvar($pfx."rootdev", 'xvda') if $isguest;
        store_runvar($pfx."console", 'hvc0');
    } elsif ($kernkind !~ m/2618/) {
        store_runvar($pfx."console", 'xvc0') if $isguest;
    }
}

sub target_kernkind_console_inittab ($$$) {
    my ($ho, $gho, $root) = @_;

    my $inittabpath= "$root/etc/inittab";
    my $console= target_var($gho,'console');

    if (defined $console && length $console) {
        target_cmd_root($ho, <<END);
            set -ex
            perl -i~ -ne "
                next if m/^xc:/;
                print \\\$_ or die \\\$!;
                next unless s/^1:/xc:/;
                s/tty1/$console/;
                print \\\$_ or die \\\$!;
            " $inittabpath
END
    }
    return $console;
}

sub target_extract_jobdistpath ($$$$$) {
    my ($ho, $part, $path, $job, $distpath) = @_;
    $distpath->{$part}= get_stashed($path, $job);
    my $local= $path;  $local =~ s/path_//;
    my $distcopy= "/root/extract_$local.tar.gz";
    target_putfile_root($ho, 300, $distpath->{$part}, $distcopy);
    target_cmd_root($ho, "cd / && tar zxf $distcopy", 300);
}

sub guest_find_domid ($$) {
    my ($ho,$gho) = @_;
    return if defined $gho->{Domid};
    my $list= target_cmd_output_root($ho,
                toolstack()->{Command}." list $gho->{Name}");
    $list =~ m/^(?!Name\s)(\S+)\s+(\d+)\s+(\d+)+(\d+)\s.*$/m
        or die "domain list: $list";
    $1 eq $gho->{Name} or die "domain list name $1 expected $gho->{Name}";
    $gho->{MemUsed}= $3;
    $gho->{Vcpus}= $4;
    return $gho->{Domid}= $2;
}

sub guest_vncsnapshot_begin ($$) {
    my ($ho,$gho) = @_;
    my $domid= $gho->{Domid};

    my $backend= target_cmd_output_root($ho,
        "xenstore-read /local/domain/$domid/device/vfb/0/backend ||:");

    if ($backend eq '') {
        my $port= target_cmd_output_root($ho,
            "xenstore-read /local/domain/$domid/console/vnc-port");
        $port =~ m/^\d+/ && $port >= 5900 or die "$port ?";
        return {
            vnclisten => $ho->{Ip},
            vncdisplay => $port-5900,
        };
    }

    $backend =~ m,^/local/domain/\d+/backend/vfb/\d+/\d+$,
        or die "$backend ?";

    my $v = {};
    foreach my $k (qw(vnclisten vncdisplay)) {
        $v->{$k}= target_cmd_output_root($ho,
                "xenstore-read $backend/$k");
    }
    return $v;
}
sub guest_vncsnapshot_stash ($$$$) {
    my ($ho,$gho,$v,$leaf) = @_;
    my $rfile= "/root/$leaf";
    target_cmd_root($ho,
        "vncsnapshot -passwd $gho->{Guest}.vncpw".
                   " -nojpeg -allowblank".
                   " $v->{vnclisten}:$v->{vncdisplay}".
                   " $rfile", 100);
    target_getfile_root($ho,100, "$rfile", "$stash/$leaf");
}

our %toolstacks=
    ('xend' => {
        NewDaemons => [qw(xend)],
        OldDaemonInitd => 'xend',
        Command => 'xm',
        CfgPathVar => 'cfgpath',
        Dom0MemFixed => 1,
        },
     'xl' => {
        NewDaemons => [],
        Dom0MemFixed => 1,
        Command => 'xl',
        CfgPathVar => 'cfgpath',
	RestoreNeedsConfig => 1,
        }
     );

sub toolstack () {
    my $tsname= $r{toolstack};
    $tsname= 'xend' if !defined $tsname;
    my $ts= $toolstacks{$tsname};
    die "$tsname ?" unless defined $ts;
    if (!exists $ts->{Name}) {
        logm("toolstack $tsname");
        $ts->{Name}= $tsname;
    }
    return $ts;
}

sub authorized_keys () {
    my $authkeys= '';
    my @akf= map {
        "$ENV{'HOME'}/.ssh/$_"
        } qw(authorized_keys id_dsa.pub id_rsa.pub);
    push @akf, split ':', $c{AuthorizedKeysFiles};
    push @akf, $c{TestHostKeypairPath}.'.pub';
    foreach my $akf (@akf) {
        next unless $akf =~ m/\S/;
        $authkeys .= get_filecontents($akf, "# $akf ENOENT\n"). "\n";
    }
    $authkeys .= $c{AuthorizedKeysAppend};
    return $authkeys;
}

#---------- logtailer ----------

package Osstest::Logtailer;
use Fcntl qw(:seek);
use POSIX;

sub new ($$) {
    my ($class, $fn) = @_;
    my $fh= new IO::File $fn,'r';
    my $ino= -1;
    if (!$fh) {
        $!==&ENOENT or die "$fn $!";
    } else {
        seek $fh, 0, SEEK_END or die "$fn $!";
        stat $fh or die "$fn $!";
        $ino= (stat _)[1];
    }
    my $lt= { Path => $fn, Handle => $fh, Ino => $ino, Buf => '' };
    bless $lt, $class;
    return $lt;
}

sub getline ($) {
    my ($lt) = @_;

    for (;;) {
        if ($lt->{Buf} =~ s/^(.*)\n//) {
            return $1;
        }

        if ($lt->{Handle}) {
            seek $lt->{Handle}, 0, SEEK_CUR or die "$lt->{Path} $!";

            my $more;
            my $got= read $lt->{Handle}, $more, 4096;
            die "$lt->{Path} $!" unless defined $got;
            if ($got) {
                $lt->{Buf} .= $more;
                next;
            }
        }

        if (!stat $lt->{Path}) {
            $!==&ENOENT or die "$lt->{Path} $!";
            return undef;
        }
        my $nino= (stat _)[1];
        return undef
            unless $nino != $lt->{Ino};

        my $nfh= new IO::File $lt->{Path},'r';
        if (!$nfh) {
            $!==&ENOENT or die "$lt->{Path} $!";
            warn "newly-created $lt->{Path} vanished again";
            return undef;
        }
        stat $nfh or die $!;
        $nino= (stat _)[1];

        $lt->_close();
        $lt->{Handle}= $nfh;
        $lt->{Ino}= $nino;
    }
}

sub _close ($) {
    my ($lt) = @_;
    if ($lt->{Handle}) {
        close $lt->{Handle} or die "$lt->{Path} $!";
        $lt->{Handle}= undef;
        $lt->{Ino}= -1;
    }
}

sub close ($) {
    my ($lt) = @_;
    $lt->_close();
    $lt->{Buf}= '';
}

sub DESTROY ($) {
    my ($lt) = @_;
    local $!;
    $lt->_close();
}

1;
