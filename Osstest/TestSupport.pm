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


package Osstest::TestSupport;

use strict;
use warnings;

use POSIX;
use DBI;
use IO::File;
use IO::Socket::INET;
use IPC::Open2;

use Osstest;
use Osstest::Logtailer;
use File::Copy;
use File::Basename;
use IO::Handle;

BEGIN {
    use Exporter ();
    our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
    $VERSION     = 1.00;
    @ISA         = qw(Exporter);
    @EXPORT      = qw(
                      tsreadconfig %r $flight $job $stash
                      ts_get_host_guest

                      fail broken logm $logm_handle get_filecontents
                      report_once

                      store_runvar get_runvar get_runvar_maybe
                      get_runvar_default need_runvars
                      unique_incrementing_runvar next_unique_name

                      target_cmd_root target_cmd target_cmd_build
                      target_cmd_output_root target_cmd_output
                      target_cmd_inputfh_root
                      target_getfile target_getfile_root
                      target_putfile target_putfile_root
                      target_putfilecontents_stash
		      target_putfilecontents_root_stash
                      target_put_guest_image target_editfile
                      target_editfile_cancel target_fetchurl
                      target_editfile_root target_file_exists
                      target_editfile_kvp_replace
                      target_run_apt
                      target_install_packages target_install_packages_norec
                      target_jobdir target_extract_jobdistpath_subdir
                      target_extract_jobdistpath
                      lv_create lv_dev_mapper

                      poll_loop tcpconnect await_tcp
                      contents_make_cpio file_simple_write_contents

                      selecthost get_hostflags get_host_property
                      get_target_property get_host_native_linux_console
                      power_state power_cycle power_cycle_sleep
                      serial_fetch_logs
                      propname_massage propname_check
         
                      get_stashed open_unique_stashfile compress_stashed
                      dir_identify_vcs build_clone built_stash built_stash_file
                      built_compress_stashed
                      hg_dir_revision git_dir_revision vcs_dir_revision
                      store_revision store_vcs_revision
                      git_massage_url

                      sshopts authorized_keys
                      remote_perl_script_open remote_perl_script_done
                      host_reboot target_reboot target_reboot_hard            
                      target_choose_vg target_umount_lv target_await_down
                      host_get_free_memory

                      target_ping_check_down target_ping_check_up
                      target_kernkind_check target_kernkind_console_inittab
                      target_var target_var_prefix
                      selectguest prepareguest more_prepareguest_hvm
                      guest_var guest_var_commalist guest_var_boolean
                      prepareguest_part_lvmdisk prepareguest_part_diskimg
                      prepareguest_part_xencfg
                      guest_umount_lv guest_await guest_await_dhcp_tcp
                      guest_checkrunning target_check_ip guest_find_ether
                      guest_find_domid guest_check_up guest_check_up_quick
                      guest_get_state guest_await_reboot
                      guest_await_shutdown guest_await_destroy guest_destroy
                      guest_vncsnapshot_begin guest_vncsnapshot_stash
		      guest_check_remus_ok guest_editconfig
                      guest_prepare_disk guest_unprepare_disk
                      host_involves_pcipassthrough host_get_pcipassthrough_devs
                      toolstack guest_create

                      await_webspace_fetch_byleaf create_webfile
                      file_link_contents get_timeout
                      setup_pxeboot_di setup_pxeboot_local host_pxefile

                      ether_prefix

                      iso_create_genisoimage
                      iso_create_empty
                      iso_gen_flags_basic
                      iso_copy_content_from_image
                      guest_editconfig_nocd
                      host_install_postboot_complete
                      target_core_dump_setup
                      );
    %EXPORT_TAGS = ( );

    @EXPORT_OK   = qw();
}

our (%r,$flight,$job,$stash);

our %timeout= qw(RebootDown   100
                 RebootUp     400
                 HardRebootUp 600);

our $logm_handle= new IO::File ">& STDERR" or die $!;

#---------- test script startup ----------

sub tsreadconfig () {
    # must be run outside transaction
    csreadconfig();

    $flight= $mjobdb->current_flight();
    $job=    $ENV{'OSSTEST_JOB'};
    die "OSSTEST_FLIGHT and/or _JOB missing"
	unless defined $flight and defined $job;

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

#---------- test script startup ----------

sub ts_get_host_guest { # pass this @ARGV
    my ($gn,$whhost) = reverse @_;
    $whhost ||= 'host';
    $gn ||= 'guest';

    my $ho= selecthost($whhost);
    my $gho= selectguest($gn,$ho);
    return ($ho,$gho);
}

#---------- general ----------

sub logm ($) {
    my ($m) = @_;
    my @t = gmtime;
    my $fm = (show_abs_time time)." $m\n";
    foreach my $h ((ref($logm_handle) eq 'ARRAY')
		   ? @$logm_handle : $logm_handle) {
	print $h $fm or die $!;
	$h->flush or die $!;
    }
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
               AND (status='queued' OR status='running' OR status='preparing')
END
    });
    die "BROKEN: $m; ". ($affected>0 ? "marked $flight.$job $newst"
                         : "($flight.$job not marked $newst)");
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

    $mjobdb->jobdb_check_other_job($flight,$job, $oflight,$ojob, "for $param");

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

sub otherflightjob ($) {
    return flight_otherjob($flight,$_[0]);
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
            DELETE FROM runvars
		  WHERE flight=? AND job=? AND name=? AND synth='t'
END
	$dbh_tests->do(<<END, undef, $flight, $job, $param, $value+1);
            INSERT INTO runvars VALUES (?,?,?,?,'t')
END
    });
    logm("runvar increment: $param=$value");
    return $value;
}

sub target_adjust_timeout ($$) {
    my ($ho,$timeoutref) = @_; # $ho might be a $gho
    if ($ho->{Guest}) {
	my $context = $ho->{TimeoutContext} // 'general';
	$$timeoutref *= guest_var($ho,"${context}_timeoutfactor",1);
    }
}

#---------- running commands eg on targets ----------

sub cmd {
    my ($timeout,$stdin,$stdout,@cmd) = @_;
    my $child= fork;  die $! unless defined $child;
    if (!$child) {
        if (defined $stdin) {
            open STDIN, '<&', $stdin
                or die "STDIN $stdin $cmd[0] $!";
        }
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
    my ($timeout,$stdin,$stdout,$cmd,$optsref,@args) = @_;
    logm("executing $cmd ... @args");
    # We use timeout(1) as a backstop, in case $cmd doesn't die.  We
    # need $cmd to die because we won't release the resources we own
    # until all of our children are dead.
    my $r= cmd($timeout,$stdin,$stdout,
	       'timeout',$timeout+30, $cmd,@$optsref,@args);
    $r and die "status $r";
}

sub tgetfileex {
    my ($ruser, $ho,$timeout, $rsrc,$ldst) = @_;
    unlink $ldst or $!==&ENOENT or die "$ldst $!";
    tcmdex($timeout,undef,undef,
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
        tcmdex($timeout,undef,undef,
               'scp', sshopts(),
               @args);
    } else {
        unshift @args, $rsync if length $rsync;
        tcmdex($timeout,undef,undef,
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
sub target_run_apt {
    my ($ho, @aptopts) = @_;
    target_cmd_root($ho,
        "DEBIAN_PRIORITY=critical UCF_FORCE_CONFFOLD=y \\
            with-lock-ex -w /var/lock/osstest-apt apt-get @aptopts", 3000);
}
sub target_install_packages {
    my ($ho, @packages) = @_;
    target_run_apt($ho, qw(-y install), @packages);
}
sub target_install_packages_norec {
    my ($ho, @packages) = @_;
    target_run_apt($ho, qw(--no-install-recommends -y install), @packages);
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
    my $out= target_cmd_output($ho, "if test -e $rfile; then echo y; fi");
    return 1 if $out =~ m/^y$/;
    return 0 if $out !~ m/\S/;
    die "$rfile $out ?";
}

sub next_unique_name ($) {
    my ($fnref) = @_;
    my $num = $$fnref =~ s/\+([1-9]\d*)$// ? $1 : 0;
    $$fnref .= '+'.($num+1);
}

our $target_editfile_cancel_exception =
    bless { }, 'Osstest::TestSupport::TargetEditfileCancelException';

sub target_editfile_cancel ($) {
    logm("cancelling edit: @_");
    die $target_editfile_cancel_exception;
}

sub teditfileex {
    my $user= shift @_;
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
        next_unique_name \$lleaf;
    }
    if ($rdest eq $rfile) {
        logm("editing $rfile as $lfile".'{,.new}');
    } else {
        logm("editing $rfile to $rdest as $lfile".'{,.new}');
    }

    target_getfile($ho, 60, $rfile, $lfile);
    open '::EI', "$lfile" or die "$lfile: $!";
    open '::EO', "> $lfile.new" or die "$lfile.new: $!";

    my $install = 1;

    eval { &$code };
    if ($@) {
	ref $@ && $@ == $target_editfile_cancel_exception or die $@;
	$install = 0;
    }

    '::EI'->error and die $!;
    close '::EI' or die $!;
    close '::EO' or die $!;
    tputfileex($user, $ho, 60, "$lfile.new", $rdest)
	if $install;
}

# Replace a Key=Value style line in a config file.
#
# To be used as 3rd argument to target_editfile(_root) as:
#    target_editfile_root($ho, "/path/to/a/file",
#			 sub { target_editfile_kvp_replace($key, $value) });
sub target_editfile_kvp_replace ($$)
{
    my ($key,$value) = @_;
    my $prnow;
    $prnow= sub {
	print ::EO "$key=$value\n" or die $!;
	$prnow= sub { };
    };
    while (<::EI>) {
	print ::EO or die $! unless m/^$key\b/;
	$prnow->() if m/^#$key/;
    }
    print ::EO "\n" or die $!;
    $prnow->();
};

sub target_editfile_root ($$$;$$) { teditfileex('root',@_); }
sub target_editfile      ($$$;$$) { teditfileex('osstest',@_); }
    # my $code= pop @_;
    # my ($ho,$rfile, $lleaf,$rdest) = @_;
    #                 ^^^^^^^^^^^^^ optional

sub target_cmd_build ($$$$) {
    my ($ho,$timeout,$builddir,$script) = @_;

    my $distcc_hosts = get_host_property($ho,'DistccHosts',undef);
    my $distcc = defined($distcc_hosts) ? <<END : "";
        CCACHE_PREFIX=distcc
        DISTCC_FALLBACK=0
        DISTCC_HOSTS="$distcc_hosts"
        export CCACHE_PREFIX DISTCC_FALLBACK DISTCC_HOSTS
END

    my $httpproxy = defined($c{HttpProxy}) ? <<END : "";
        http_proxy=$c{HttpProxy}
        export http_proxy
END

    target_cmd($ho, <<END.$distcc.$httpproxy.<<END.$script, $timeout);
	set -xe
        LC_ALL=C; export LC_ALL
        PATH=/usr/lib/ccache:\$PATH:/usr/lib/git-core
END
        exec </dev/null
        cd $builddir
        rm -f build-ok-stamp
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
    target_adjust_timeout($ho,\$timeout);
    poll_loop($timeout,5,'reboot-down', sub {
        return target_ping_check_down($ho);
    });
}    

sub tcmd { # $tcmd will be put between '' but not escaped
    my ($stdin,$stdout,$user,$ho,$tcmd,$timeout,$extrasshopts) = @_;
    $timeout=30 if !defined $timeout;
    target_adjust_timeout($ho,\$timeout);
    tcmdex($timeout,$stdin,$stdout,
           'ssh', sshopts(), @{ $extrasshopts || [] },
           sshuho($user,$ho), $tcmd);
}
sub target_cmd ($$;$$) { tcmd(undef,undef,'osstest',@_); }
sub target_cmd_root ($$;$$) { tcmd(undef,undef,'root',@_); }

sub tcmdout {
    my $stdout= IO::File::new_tmpfile();
    tcmd(undef,$stdout,@_);
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

sub target_cmd_inputfh_root ($$$;$$) {
    my ($tho,$stdinfh,$tcmd,@rest) = @_;
    tcmd($stdinfh,undef,'root',$tho,$tcmd,@rest);
}

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
            local ($Osstest::TestSupport::logm_handle) = ($logmtmpfile);
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

sub lv_create ($$$$) {
    my ($ho, $vg, $lv, $mb) = @_;
    my $lvdev = "/dev/$vg/$lv";
    target_cmd_root($ho, "lvremove -f $lvdev ||:");
    target_cmd_root($ho, "lvcreate -L ${mb}M -n $lv $vg");
    target_cmd_root($ho, "dd if=/dev/zero of=$lvdev count=10");
    return $lvdev;
}

sub lv_dev_mapper ($$) {
    my ($vg,$lv) = @_;
    $vg =~ s/-/--/g;
    $lv =~ s/-/--/g;
    # Dashes are doubled in the VG and LV names
    return "/dev/mapper/$vg-$lv";
}    

#---------- dhcp watching ----------

sub dhcp_watch_setup ($$) {
    my ($ho,$gho) = @_;

    my $meth = get_host_property($ho,'dhcp-watch-method',undef);
    $gho->{DhcpWatch} = get_host_method_object($ho, 'DhcpWatch', $meth);
}

sub target_check_ip ($) {
    my ($gho) = @_; # returns error message or undef
    return undef if $gho->{IpStatic};
    guest_find_ether($gho);
    $gho->{DhcpWatch}->check_ip($gho);
}

#-------------- serial -------------

sub serial_host_setup ($) {
    my ($ho) = @_;
    my $methobjs = [ ];
    my $serialmeth = get_host_property($ho,'serial','noop');
    foreach my $meth (split /\;\s*/, $serialmeth) {
	push @$methobjs, get_host_method_object($ho,'Serial',$meth);
    }
    $ho->{SerialMethobjs} = $methobjs;
}

sub serial_fetch_logs ($) {
    my ($ho) = @_;

    logm("serial: requesting debug information from $ho->{Name}");

    foreach my $mo (@{ $ho->{SerialMethobjs} }) {
	$mo->request_debug("\x18\x18\x18",
			   "0HMQacdegimnrstuvz",
			   "q") or next;
	# use the first method which supports ->request_debug.
	last;
    }

    logm("serial: collecting logs for $ho->{Name}");

    foreach my $mo (@{ $ho->{SerialMethobjs} }) {
	$mo->fetch_logs();
    }
}

#---------- power cycling ----------

sub power_cycle_host_setup ($) {
    my ($ho) = @_;
    my $methobjs = [ ];
    foreach my $meth (split /\;\s*/, $ho->{Power}) {
	push @$methobjs, get_host_method_object($ho,'PDU',$meth);
    }
    $ho->{PowerMethobjs} = $methobjs;
}

sub power_cycle_sleep ($) {
    my ($ho) = @_;
    my $to = get_host_property($ho, 'power-cycle-time', 5);
    logm("power-cycle: waiting ${to}s");
    sleep($to);
}

sub power_cycle ($) {
    my ($ho) = @_;
    $mjobdb->host_check_allocated($ho);
    die "refusing to set power state for host $ho->{Name}".
	" possibly shared with other jobs\n"
	if $ho->{SharedMaybeOthers};
    power_state($ho, 0);
    power_cycle_sleep($ho);
    power_state($ho, 1);
}

sub power_state ($$) {
    my ($ho, $on) = @_;
    logm("power: setting $on for $ho->{Name}");
    foreach my $mo (@{ $ho->{PowerMethobjs} }) {
	$mo->pdu_power_state($on);
    }
}

#---------- host selection and properties ----------

sub selecthost ($);
sub selecthost ($) {
    my ($ident) = @_;
    # must be run outside transaction

    # $ident is <identspec>
    #
    # <identspec> can be <ident>, typically "host" or "xxx_host"
    # which means look up the runvar $r{$ident} which
    # contains <hostspec>
    # OR
    # <identspec> can be <ident>=<hostspec>
    # which means ignore <ident> except for logging purposes etc.
    # and use <hostspec>
    #
    # <hostspec> can be <hostname> which means use that host (and all
    # its flags and properties from the configuration and database)
    # OR
    # <hostspec> can be <parent_identspec>:<domname> meaning use the
    # Xen domain name <domname> on the host specified by
    # <parent_identspec>, which is an <identspec> as above.

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
        NestingLevel => 0,
        Info => [],
    };
    if (defined $job) {
	$ho->{Suite} = get_runvar_default("${ident}_suite",$job,
					  $c{DebianSuite});
    }

    #----- handle hosts which are themselves guests (nested) -----

    if ($name =~ s/^(.*)://) {
	my $parentname = $1;
	my $parent = selecthost($parentname);
	my $child = selectguest($name,$parent);
	$child->{Ident} = $ho->{Ident};
	$child->{Info} = [ "in", $parent->{Name}, @{ $parent->{Info} } ];
	$child->{NestingLevel} = $parent->{NestingLevel}+1;

	$child->{Power} = 'guest';
	power_cycle_host_setup($child);

	$child->{Properties}{Serial} = 'noop'; # todo
	serial_host_setup($child);

	my $msg = "L$child->{NestingLevel} host $child->{Ident}:";
	$msg .= " guest $child->{Guest} (@{ $child->{Info} })";
	$msg .= " $child->{Ether}";

	my $err = target_check_ip($child);
	$msg .= " ".(defined $err ? "<no-ip> $err" : $child->{Ip});

	logm($msg);

	# all the rest of selecthost is wrong for this case
	return $child;
    }

    #----- calculation of the host's properties -----

    $ho->{Properties} = { };
    my $setprop = sub {
	my ($pn,$val) = @_;
	$ho->{Properties}{$pn} = $val;
    };

    # First, set the prop group if any.
    if ( $c{"HostGroup_${name}"} ) {
	$setprop->("HostGroup", $c{"HostGroup_${name}"});
	logm("Host $name is in HostGroup $ho->{Properties}{HostGroup}");
    }

    # Next, we use the config file's general properites as defaults
    foreach my $k (keys %c) {
	next unless $k =~ m/^HostProp_([A-Z].*)$/;
	$setprop->($1, $c{$k});
    }

    # Then we read in the HostDB's properties
    $mhostdb->get_properties($name, $ho->{Properties});

    # Next, we set any HostGroup based properties
    if ( $ho->{Properties}{HostGroup} ) {
	foreach my $k (keys %c) {
	    next unless $k =~ m/^HostGroupProp_([-a-z0-9]+)_(.*)$/;
	    next unless $1 eq $ho->{Properties}{HostGroup};
	    $setprop->($2, $c{$k});
	}
    }

    # Finally, we override any host-specific properties from the config
    foreach my $k (keys %c) {
	next unless $k =~ m/^HostProp_([-a-z0-9]+)_(.*)$/;
	next unless $1 eq $name;
	$setprop->($2, $c{$k});
    }

    #----- calculation of the host's flags -----

    $ho->{Flags} = $mhostdb->get_flags($ho);

    #----- fqdn -----

    my $defaultfqdn = $name;
    $defaultfqdn .= ".$c{TestHostDomain}" unless $defaultfqdn =~ m/\./;
    $ho->{Fqdn} = get_host_property($ho,'fqdn',$defaultfqdn);


    $ho->{Ether}= get_host_property($ho,'ether');
    $ho->{DiskDevice}= get_host_property($ho,'disk-device');
    $ho->{Power}= get_host_property($ho,'power-method');

    $mhostdb->default_methods($ho);

    dhcp_watch_setup($ho,$ho);
    power_cycle_host_setup($ho);
    serial_host_setup($ho);

    $ho->{IpStatic} = get_host_property($ho,'ip-addr');
    if (defined $r{"${ident}_ip"}) {
        $ho->{Ip} = $r{"${ident}_ip"};
    } else {
        if (!defined $ho->{IpStatic}) {
	    my $ip_packed= gethostbyname($ho->{Fqdn});
	    die "$ho->{Fqdn} ?" unless $ip_packed;
	    $ho->{IpStatic}= inet_ntoa($ip_packed);
	    die "$ho->{Fqdn} ?" unless defined $ho->{IpStatic};
        }
        $ho->{Ip}= $ho->{IpStatic};
    }

    #----- tftp -----

    my $tftpscope = get_host_property($ho, 'TftpScope', $c{TftpDefaultScope});
    logm("TftpScope is $tftpscope");
    $ho->{Tftp} = { };
    $ho->{Tftp}{$_} = $c{"Tftp${_}_${tftpscope}"} || $c{"Tftp${_}"}
        foreach qw(Path TmpDir PxeDir PxeGroup PxeTemplates PxeTemplatesReal
                   DiBase GrubBase);

    #----- finalise -----

    $mjobdb->host_check_allocated($ho);

    logm("host $ho->{Ident}: selected $ho->{Name} ".
	 (defined $ho->{Ether} ? $ho->{Ether} : '<unknown-ether>').
	 " $ho->{Ip}".
         (!$ho->{Shared} ? '' :
          sprintf(" - shared %s %s %d", $ho->{Shared}{Type},
                  $ho->{Shared}{State}, $ho->{Shared}{Others}+1)));

    return $ho;
}

sub propname_massage ($) {
    # property names used to be in the form word-word-word
    # and are moving to WordWordWord.
    #
    # Some property names are "some-words other-words". Massage them
    # into "some-words_other-words" and then into
    # "SomeWords_OtherWords".

    my ($prop) = @_;
    my $before = $prop;

    $prop = ucfirst $prop;

    while ($prop =~ m/ /) {
	$prop = $`."_".ucfirst $'; #';
    }

    while ($prop =~ m/-/) {
	$prop = $`.ucfirst $'; #';
    }

    return $prop;
}

sub propname_check ($) {
    # ensure propname is valid and in the canonical WordWordWord form
    # (rather than, say, one of the legacy forms described in
    # propname_massage).
    my ($prop) = @_;

    # Check only valid characters
    return 0 if $prop !~ m|^${cfgvar_re}$|;
    # Check canonical form
    return 0 if propname_massage($prop) ne $prop;
    # Is ok
    return 1;
}

# It is fine to call this on a guest object too, in which case it will
# always return $defval.
sub get_host_property ($$;$) {
    my ($ho, $prop, $defval) = @_;
    return $defval unless $ho->{Properties};
    my $val = $ho->{Properties}{propname_massage($prop)};
    return defined($val) ? $val : $defval;
}

sub get_target_property ($$;$);
sub get_target_property ($$;$) {
    my ($ho, $prop, $defval) = @_;
    # $ho may be a guest; if so we look for the property in the
    # guest and failing that the same property in the host.
    return
	get_host_property($ho, $prop) //
	($ho->{Host} && get_target_property($ho->{Host}, $prop)) //
	$defval;
}

sub get_host_native_linux_console ($) {
    my ($ho) = @_;

    my $console = get_host_property($ho, "LinuxSerialConsole", "ttyS0");
    return $console if $console eq 'NONE';

    return "$console,$c{Baud}n8";
}

sub get_host_method_object ($$$) {
    my ($ho, $kind, $meth) = @_;
    my (@meth) = split /\s+/, $meth;
    my $mo;
    eval ("use Osstest::${kind}::$meth[0];".
	  "\$mo = Osstest::${kind}::$meth[0]->new(\$ho, \@meth);")
	or die "get_host_method_object $kind $meth $@";
    return $mo;
}

#---------- stashed files ----------

sub open_unique_stashfile ($) {
    my ($leafref) = @_;
    my $dh;
    for (;;) {
        my $df= $$leafref;
        $dh= new IO::File "$stash/$df", O_RDWR|O_EXCL|O_CREAT;
        last if $dh;
        die "$df $!" unless $!==&EEXIST;
        next_unique_name $leafref;
    }
    return $dh;
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

sub compress_stashed($) {
    my ($path) = @_;
    return unless -e "$stash/$path";
    my $r= system 'gzip','-9vf','--',"$stash/$path";
    die "$r $!" if $r;
}

#---------- other stuff ----------

sub common_toolstack ($) {
    my ($ho) =  @_;
    my $tsname = toolstack($ho);
    my $ts = 'xl';
    $ts = 'xm' if $tsname eq 'xend';
    return $ts;
}

sub host_reboot ($) {
    my ($ho) = @_;
    target_reboot($ho);
    my $timeout = 40;
    target_adjust_timeout($ho,\$timeout);
    poll_loop($timeout,2, 'reboot-confirm-booted', sub {
        my $output;
        if (!eval {
            $output= target_cmd_output($ho, <<END, 40);
stat /dev/shm/osstest-confirm-booted 2>&1 >/dev/null \\
 || ps -efH >osstest-confirm-booted.log
END
            1;
        }) {
            return $@;
        }
        return length($output) ? $output : undef;
    });
}

sub host_get_free_memory($) {
    my ($ho) = @_;
    my $toolstack = common_toolstack($ho);
    # The line is as followed:
    # free_memory       :   XXXX
    my $info = target_cmd_output_root($ho, "$toolstack info", 10);
    my @matched = $info =~ /^free_memory\s*:\s*(\d+)\s*$/m;
    @matched or die "fail to get host free memory: $info ?";
    return $matched[0];
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

#---------- file handling ----------

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

#---------- building, vcs's, etc. ----------

sub git_massage_url ($;@) {
    my ($url, %xopts) = @_;
    # Supports $xopts{GitFetchBestEffort}

    if ($url =~ m,^(git|https?)://, && $c{GitCacheProxy} &&
	substr($url,0,length($c{GitCacheProxy})) ne $c{GitCacheProxy}) {
	$url = $c{GitCacheProxy}.$url;
	if ($xopts{GitFetchBestEffort}) {
	    $url .= '%20[fetch=try]';
	}
    }
    return $url;
}

sub build_clone ($$$$) {
    my ($ho, $which, $builddir, $subdir) = @_;

    need_runvars("tree_$which", "revision_$which");

    my $tree= $r{"tree_$which"};
    my $timeout= 4000;

    my $vcs = $r{"treevcs_$which"};
    if (!defined $vcs) {
	my $effurl = $tree;
	$effurl =~ s#\%20[^/]*$##;
	if ($effurl =~ m/\.hg$/) {
	    $vcs= 'hg';
	} elsif ($effurl =~ m/\.git$/) {
	    $vcs= 'git';
	} else {
	    die "unknown vcs for $which $tree ";
	}
    }

    my $rm = "rm -rf $subdir";

    if ($vcs eq 'hg') {
        
        target_cmd_build($ho, $timeout, $builddir, <<END.
	    $rm
	    hg clone '$tree' $subdir
	    cd $subdir
END
                         (length($r{"revision_$which"}) ? <<END : ''));
	    hg update '$r{"revision_$which"}'
END
    } elsif ($vcs eq 'git') {

	my $eff_tree = git_massage_url($tree);

        target_cmd_build($ho, $timeout, $builddir, <<END.
            $rm
            git clone '$eff_tree' $subdir
            cd $subdir
END
                         (length($r{"revision_$which"}) ? <<END : ''));
	    git checkout '$r{"revision_$which"}'
	    git clean -xdf
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
        (test -e .git && echo git) ||
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
    target_cmd($ho, <<END, 600);
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

sub built_stash_file ($$$$;$) {
    my ($ho, $builddir, $item, $fname, $optional) = @_;
    my $build= "build";
    my $stashleaf= "$build/$item";

    return if $optional && !target_file_exists($ho, "$builddir/$fname");

    ensuredir("$stash/$build");
    target_getfile($ho, 300,
                   "$builddir/$fname",
                   "$stash/$stashleaf");
}

sub built_compress_stashed($) {
    my ($path) = @_;
    compress_stashed("build/$path");
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

#---------- hosts and guests ----------

sub get_hostflags ($) {
    my ($ident) = @_;
    # may be run outside transaction, or with flights locked
    my $flags= get_runvar_default('all_hostflags',     $job, '').','.
               get_runvar_default("${ident}_hostflags", $job, '');
    return grep /./, split /\,/, $flags;
}

sub host_involves_pcipassthrough ($) {
    my ($ho) = @_;
    return !!grep m/^pcipassthrough\-/, get_hostflags($ho->{Ident});
}

sub host_get_pcipassthrough_devs ($) {
    my ($ho) = @_;
    my @devs;
    foreach my $name (keys %{ $ho->{Properties} }) {
        next unless $name =~ m/^pcipassthrough (\w+)$/;
        my $devtype= $1;
        next unless grep { m/^pcipassthrough-$devtype$/ } get_hostflags($ho);
	my $val = $ho->{Properties}{$name};
        $val =~ m,^([0-9a-f]+\:[0-9a-f]+\.\d+)/, or
            die "$ho->{Ident} $val ?";
        push @devs, {
            DevType => $devtype,
            Bdf => $1,
            Info => $' #'
            };
    }
    return @devs;
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
        Tftp => $ho->{Tftp},
	Host => $ho,
    };
    foreach my $opt (guest_var_commalist($gho,'options')) {
        $gho->{Options}{$opt}++;
    }
    logm("guest: using $gn on $gho->{Host}{Name}");
    guest_find_lv($gho);
    guest_find_diskimg($gho);
    guest_find_ether($gho);
    guest_find_tcpcheckport($gho);
    dhcp_watch_setup($ho,$gho);
    return $gho;
}

sub guest_find_lv ($) {
    my ($gho) = @_;
    my $gn= $gho->{Guest};
    $gho->{Vg}= $r{"${gn}_vg"};
    $gho->{Lv}= $r{"${gn}_disk_lv"};
    $gho->{Lvdev}= (defined $gho->{Vg} && defined $gho->{Lv})
        ? lv_dev_mapper($gho->{Vg},$gho->{Lv}) : undef;
}

sub guest_find_diskimg($)
{
    my ($gho) = @_;

    return unless $gho->{Lvdev};

    $gho->{Diskfmt} = $r{"$gho->{Guest}_diskfmt"} // "none";
    $gho->{Diskspec} = "phy:$gho->{Lvdev},xvda,w";

    return if $gho->{Diskfmt} eq "none";

    my $mntroot = get_host_property($gho->{Host}, "DiskImageMount",
			    $c{DiskImageMount} // "/var/lib/xen/images");

    $gho->{Diskmnt} = "$mntroot/$gho->{Guest}";
    $gho->{Diskimg} = "$gho->{Diskmnt}/disk.$gho->{Diskfmt}";
    $gho->{Diskspec} = "format=$gho->{Diskfmt},vdev=xvda,target=$gho->{Diskimg}";
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

sub guest_await_state ($$$$$) {
    my ($ho,$gho, $what,$wait_st,$timeout) = @_;

    target_adjust_timeout($gho,\$timeout);
    poll_loop($timeout, 30, "await $what request from $gho->{Guest}", sub {
        my $st= guest_get_state($ho,$gho);
        return undef if $st eq $wait_st;
        fail("guest unexpectedly shutdown; state is '$st'")
            if $st =~ m/^s/ || $st eq '';
        return "guest state is \"$st\"";
    });
}

sub guest_await_reboot ($$$) {
    my ($ho,$gho, $timeout) = @_;
    return guest_await_state($ho,$gho, "reboot", "sr", $timeout);
}

sub guest_await_shutdown ($$$) {
    my ($ho,$gho, $timeout) = @_;
    return guest_await_state($ho,$gho, "shutdown", "s", $timeout);
}

sub guest_destroy ($) {
    my ($gho) = @_;
    my $ho = $gho->{Host};
    toolstack($ho)->destroy($gho);
    guest_unprepare_disk($gho);
}

sub guest_await_destroy ($$) {
    my ($gho, $timeout) = @_;
    my $ho = $gho->{Host};
    return guest_await_state($ho,$gho, "destroy", "", $timeout);
}

sub guest_create ($) {
    my ($gho) = @_;
    my $ho = $gho->{Host};
    guest_prepare_disk($gho);
    toolstack($ho)->create($gho);
}

sub guest_prepare_disk ($) {
    my ($gho) = @_;

    guest_umount_lv($gho->{Host}, $gho);

    return if $gho->{Diskfmt} eq "none";

    target_cmd_root($gho->{Host}, <<END);
mkdir -p $gho->{Diskmnt}
mount $gho->{Lvdev} $gho->{Diskmnt};
END
}

sub guest_unprepare_disk ($) {
    my ($gho) = @_;
    return if $gho->{Diskfmt} eq "none";
    target_cmd_root($gho->{Host}, <<END);
umount $gho->{Lvdev} || :
END
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

sub ether_prefix($) {
    my ($ho) = @_;
    my $prefix = get_host_property($ho, 'gen-ether-prefix-base');
    $prefix =~ m/^(\w+:\w+):(\w+):(\w+)$/ or die "$prefix ?";
    my $lhs = $1;
    my $pv = (hex($2)<<8) | (hex($3));
    $pv ^= $mjobdb->gen_ether_offset($ho,$flight);
    $prefix = sprintf "%s:%02x:%02x", $lhs, ($pv>>8)&0xff, $pv&0xff;
    return $prefix;
}

sub select_ether ($$) {
    my ($ho,$vn) = @_;
    # must be run outside transaction
    my $ether= $r{$vn};
    return $ether if defined $ether;

    db_retry($flight,'running', $dbh_tests,[qw(flights)], sub {
	my $prefix = ether_prefix($ho);
	my $glob_ether = $mjobdb->jobdb_db_glob('*_ether');

        my $previous= $dbh_tests->selectrow_array(<<END, {}, $flight);
            SELECT max(val) FROM runvars WHERE flight=?
                AND name $glob_ether
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
                AND name $glob_ether
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

sub guest_var_boolean ($$) {
    my ($gho, $runvartail) = @_;
    return guest_var($gho, $runvartail, 'false') =~ m/true/;
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
        select_ether($ho,"${gn}_ether");
    } else {
        my $ptnicho= selecthost($ptnichostident);
        my $ptnicinfo= get_host_property($ptnicho,'pcipassthrough nic');
        $ptnicinfo =~ m,/, or die "$ptnichostident $ptnicinfo ?";
        my $ptether= $'; #'
        $r{"${gn}_ether"}= $ptether;
        logm("passthrough nic from $ptnichostident ether $ptether");
    }

    store_runvar("${gn}_hostname", $hostname);
    store_runvar("${gn}_tcpcheckport", $tcpcheckport);
    store_runvar("${gn}_boot_timeout", $boot_timeout);

    my $gho= selectguest($gn, $ho);
    store_runvar("${gn}_domname", $gho->{Name});

    # If we have defined guest specific disksize, use it
    $mb = guest_var($gho,'disksize',$mb);
    if (defined $mb) {
	store_runvar("${gn}_disk_lv", $r{"${gn}_hostname"}.'-disk');
    }

    if (defined $mb) {
	store_runvar("${gn}_vg", '');
	if (!length $r{"${gn}_vg"}) {
	    store_runvar("${gn}_vg", target_choose_vg($ho, $mb));
	}
    }

    $gho->{TimeoutContext} = 'install';

    guest_find_lv($gho);
    guest_find_diskimg($gho);
    guest_find_ether($gho);
    guest_find_tcpcheckport($gho);
    return $gho;
}

sub prepareguest_part_lvmdisk ($$$) {
    my ($ho, $gho, $disk_mb) = @_;
    lv_create($ho, $gho->{Vg}, $gho->{Lv}, $disk_mb);
}

sub make_vhd ($$$) {
    my ($ho, $gho, $disk_mb) = @_;
    target_cmd_root($ho, "vhd-util create -n $gho->{Rootimg} -s $disk_mb");
}
sub make_qcow2 ($$$) {
    my ($ho, $gho, $disk_mb) = @_;
    # upstream qemu's version. Seems preferable to qemu-xen-img from qemu-trad.
    my $qemu_img;
    foreach (qw(/usr/local /usr)) {
	my $try = "$_/lib/xen/bin/qemu-img";
        if (target_file_exists($ho, $try)) {
            $qemu_img=$try;
            last;
        }
    }
    die "no qemu-img" unless $qemu_img;

    target_cmd_root($ho, "$qemu_img create -f qcow2 $gho->{Rootimg} ${disk_mb}M");
}
sub make_raw ($$$) {
    my ($ho, $gho, $disk_mb) = @_;
    # In local tests this reported 130MB/s, so calculate a timeout assuming 65MB/s.
    target_cmd_root($ho, "dd if=/dev/zero of=$gho->{Rootimg} bs=1MB count=${disk_mb}",
	${disk_mb} / 65);
}

sub prepareguest_part_diskimg ($$$) {
    my ($ho, $gho, $disk_mb) = @_;

    my $diskfmt = $gho->{Diskfmt};
    # Allow an extra 10 megabytes for image format headers
    my $disk_overhead = $diskfmt eq "none" ? 0 : 10;

    logm("preparing guest disks in $diskfmt format");

    target_cmd_root($ho, "umount $gho->{Lvdev} ||:");

    prepareguest_part_lvmdisk($ho, $gho, $disk_mb + $disk_overhead);

    if ($diskfmt ne "none") {

	$gho->{Rootimg} = "$gho->{Diskmnt}/disk.$diskfmt";
	$gho->{Rootcfg} = "format=$diskfmt,vdev=xvda,target=$gho->{Rootimg}";

	target_cmd_root($ho, <<END);
mkfs.ext3 $gho->{Lvdev}
mkdir -p $gho->{Diskmnt}
mount $gho->{Lvdev} $gho->{Diskmnt}
END
        no strict qw(refs);
        &{"make_$diskfmt"}($ho, $gho, $disk_mb);

	target_cmd_root($ho, <<END);
umount $gho->{Lvdev}
END
    }
}

sub prepareguest_part_xencfg ($$$$$) {
    my ($ho, $gho, $ram_mb, $xopts, $cfgrest) = @_;
    my $onreboot= $xopts->{OnReboot} || 'restart';
    my $onpoweroff= $xopts->{OnPowerOff} || 'destroy';
    my $oncrash= $xopts->{OnCrash} || 'preserve';
    my $vcpus= guest_var($gho, 'vcpus', $xopts->{DefVcpus} || 2);
    my $viftype= $xopts->{VifType} ? "type=$xopts->{VifType}," : "";
    my $vif= guest_var($gho, 'vifmodel','');
    my $vifmodel= $vif ? "model=$vif," : '';
    my $xoptcfg= $xopts->{ExtraConfig};
    $xoptcfg='' unless defined $xoptcfg;
    my $xencfg= <<END;
name        = '$gho->{Name}'
memory = ${ram_mb}
vif         = [ '${viftype}${vifmodel}mac=$gho->{Ether}' ]
#
on_poweroff = '$onpoweroff'
on_reboot   = '$onreboot'
on_crash    = '$oncrash'
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

sub target_fetchurl($$$;$) {
    my ($ho, $url, $path, $timeo) = @_;
    $timeo ||= 2000;
    my $useproxy = "export http_proxy=$c{HttpProxy};" if $c{HttpProxy};
    target_cmd_root($ho, <<END, $timeo);
    $useproxy wget --progress=dot:mega -O \Q$path\E \Q$url\E
END
}


sub target_put_guest_image ($$;$) {
    my ($ho, $gho, $default) = @_;
    my $specimage = $r{"$gho->{Guest}_image"};
    $specimage = $default if !defined $specimage;
    die "$gho->{Guest} ?" unless $specimage;
    my $limage= $specimage =~ m,^/, ? $specimage : "$c{Images}/$specimage";
    $gho->{Rimage}= "/root/$flight.$job.".basename($specimage);
    target_putfile_root($ho, 1000, $limage,$gho->{Rimage}, '-p');
}

sub more_prepareguest_hvm ($$$$;@) {
    my ($ho, $gho, $ram_mb, $disk_mb, %xopts) = @_;
    # $ram_mb and $disk_mb are defaults, used if runvars don't say 

    my $passwd= 'xenvnc';

    prepareguest_part_lvmdisk($ho, $gho, $disk_mb);

    my @disks = "phy:$gho->{Lvdev},hda,w";

    if (!$xopts{NoCdromImage}) {
	target_put_guest_image($ho, $gho);

	my $postimage_hook= $xopts{PostImageHook};
	$postimage_hook->() if $postimage_hook;

	push @disks, "file:$gho->{Rimage},hdc:cdrom,r";
    }
    my $disks = join ",\t\t\n", map { "'$_'" } @disks;

    my $kernel = toolstack($ho)->{Name} =~ m/xend/ ?
	"kernel      = 'hvmloader'" : '';

    my $cfg = <<END;
$kernel
builder     = 'hvm'
#
disk        = [
		$disks
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

#
boot = 'dc'
END

    my $devmodel = $r{'device_model_version'};
    if (defined $devmodel) {
        $cfg .= "device_model_version='$devmodel'\n";
    }

    my $bios = $xopts{'Bios'};
    if (defined $bios) {
        $cfg .= "bios='$bios'\n";
    }

    my $stubdom = guest_var_boolean($gho, 'stubdom');
    if ($stubdom) {
	$cfg .= "device_model_stubdomain_override=1\n";
	# MINI-OS turns any open of a path starting /var/log/ into a
	# fd pointing to mini-os's console. IOW any such path used
	# here ends up in the host logs in /var/log/xen/qemu-dm-$guest.log
	$cfg .= "serial='file:/var/log/dm-serial.log'\n";
    } else {
	$cfg .= "serial='file:/dev/stderr'\n";
    }

    $xopts{VifType} ||= "ioemu";
    my $cfgpath= prepareguest_part_xencfg($ho, $gho, $ram_mb, \%xopts, $cfg);
    target_cmd_root($ho, <<END);
        (echo $passwd; echo $passwd) | vncpasswd $gho->{Guest}.vncpw
END

    return $cfgpath;
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

sub guest_check_via_ssh ($) {
    my ($gho) = @_;
    return $r{"$gho->{Guest}_tcpcheckport"} == 22;
}

sub guest_check_up_quick ($) {
    my ($gho) = @_;
    if (guest_check_via_ssh($gho)) {
	target_cmd_root($gho, "date", 10, [qw(-v)]);
    } else {
	target_ping_check_up($gho);
    }
}

sub guest_check_up ($) {
    my ($gho) = @_;
    guest_await_dhcp_tcp($gho,20);
    target_ping_check_up($gho);
    target_cmd_root($gho, "echo guest $gho->{Name}: ok", 10, [qw(-v)])
        if guest_check_via_ssh($gho);
}

sub guest_get_state ($$) {
    my ($ho,$gho) = @_;
    my $domains= target_cmd_output_root($ho, common_toolstack($ho)." list");
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
    target_adjust_timeout($gho,\$timeout);
    poll_loop($timeout,1,
              "guest $gho->{Name} ".visible_undef($gho->{Ether}).
	      " $gho->{TcpCheckPort}".
              " link/ip/tcp",
              sub {
        my $err= target_check_ip($gho);
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
    if (defined $gho->{Vg}) {
	target_umount_lv($ho, $gho->{Vg}, $gho->{Lv});
    }
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
    target_adjust_timeout($ho,\$maxwait);
    poll_loop($maxwait,$interval,
              "await tcp $ho->{Name} $ho->{Ip} $ho->{TcpCheckPort}",
              sub {
	return target_check_ip($ho) //
               target_tcp_check($ho,$interval);
    });
}

sub guest_await ($$) {
    my ($gho,$dhcpwait) = @_;
    guest_await_dhcp_tcp($gho,$dhcpwait);
    target_cmd_root($gho, "echo guest $gho->{Name}: ok")
        if guest_check_via_ssh($gho);
    return $gho;
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
    my $kernkind= $r{$pfx."kernkind"} // 'pvops';
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
            egrep '^[0-9a-zA-Z].*getty.* $console\$' $inittabpath \\
	    || perl -i~ -ne "
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

sub target_jobdir ($) {
    my ($ho) = @_;
    my $jobdir = $ho->{JobDir};
    if (!$jobdir) {
	my $leaf= "build.$flight.$job";
	my $homedir = get_host_property($ho, 'homedir', '/home/osstest');
	$jobdir = "$homedir/$leaf";
	target_cmd($ho, "mkdir -p $jobdir", 60);
	$ho->{JobDir} = $jobdir;
    }
    return $jobdir;
}

sub target_extract_jobdistpath_subdir ($$$$) {
    my ($ho, $subdir, $distpart, $buildjob) = @_;
    # Extracts dist part $distpart from job $buildjob into an
    # job-specific directory with leafname $subdir on $ho, and returns
    # the directory's pathname.  Does not need root.

    my $jobdir = target_jobdir($ho);
    my $distdir = "$jobdir/$subdir";
    target_cmd($ho,"rm -rf $distdir && mkdir $distdir",60);

    my $path = get_stashed("path_${distpart}dist", $buildjob);
    my $distcopy= "$jobdir/${subdir}.tar.gz";
    target_putfile($ho, 300, $path, $distcopy);
    target_cmd($ho, "tar -C $distdir -hzxf $distcopy", 300);

    return $distdir;
}

sub target_extract_jobdistpath ($$$$$) {
    my ($ho, $part, $path, $job, $distpath) = @_;
    $distpath->{$part}= get_stashed($path, $job);
    my $local= $path;  $local =~ s/path_//;
    my $distcopy= "/root/extract_$local.tar.gz";
    target_putfile_root($ho, 300, $distpath->{$part}, $distcopy);
    target_cmd_root($ho, "cd / && tar -hzxf $distcopy", 300);
}

sub guest_find_domid ($$) {
    my ($ho,$gho) = @_;
    return if defined $gho->{Domid};
    my $list= target_cmd_output_root($ho,
                common_toolstack($ho)." list $gho->{Name}");
    $list =~ m/^(?!Name\s)(\S+)\s+(\d+)\s+(\d+)\s+(\d+)\s.*$/m
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

sub toolstack ($) {
    my ($ho) = @_;
    return $ho->{_Toolstack} if $ho->{_Toolstack};

    my $tsname= $r{toolstack} || 'xend';
    $ho->{_Toolstack}= get_host_method_object($ho, 'Toolstack', $tsname);
    return $ho->{_Toolstack};
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

#---------- webspace for installer ----------

sub await_webspace_fetch_byleaf ($$$$$) {
    my ($maxwait,$interval,$logtailer, $ho, $url) = @_;
    my $leaf= $url;
    $leaf =~ s,.*/,,;
    target_adjust_timeout($ho,\$maxwait);
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

sub create_webfile ($$$) {
    my ($ho, $tail, $contents) = @_; # $contents as for file_link_contents
    my $wf_rhs= $ho->{Name}."_".$tail;
    # $ho->{Host} is set if $ho is a guest.
    $wf_rhs= $ho->{Host}{Name}."_${wf_rhs}" if $ho->{Host};
    my $wf_common= $c{WebspaceCommon}.$wf_rhs;
    my $wf_url= $c{WebspaceUrl}.$wf_common;
    my $wf_file= $c{WebspaceFile}.$wf_common;
    file_link_contents($wf_file, $contents, "webspace-$wf_rhs");
    return $wf_url;
}

#---------- pxe handling ----------

sub file_link_contents ($$$) {
    my ($fn, $contents, $stash) = @_;
    # $contents as for file_write_contents
    my ($dir, $base, $ext) =
        $fn =~ m,^( (?: .*/ )? )( [^/]+? )( (?: \.[^./]+ )? )$,x
        or die "$fn ?";
    my $real= "$dir$base--osstest$ext";
    my $linktarg= "$base--osstest$ext";

    if (ref $contents) { $stash = undef; }

    if (defined $stash) {
	my $stashh= open_unique_stashfile(\$stash);
	print $stashh $contents or die "$stash: $!";
	close $stashh or die "$stash: $!";
    }

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
    logm("wrote $fn". (defined $stash ? " (stashed as $stash)" : ""));
}

sub host_pxefile ($;$) {
    my ($ho, $templatekey) = @_;
    my %v = %r;
    $templatekey //= 'PxeTemplates';
    my $templates = $ho->{Tftp}{$templatekey} || $ho->{Tftp}{PxeTemplates};
    if (defined $ho->{Ether}) {
	my $eth = $v{'ether'} = $ho->{Ether};
	$eth =~ y/A-Z/a-z/;
	$eth =~ y/0-9a-f//cd;
	length($eth)==12 or die "$eth ?";
	$eth =~ s/../$&-/g;
	$eth =~ s/\-$//;
	$v{'etherhyph'} = $eth;
    }
    $v{'name'} = $ho->{Name};
    if (defined $ho->{IpStatic}) {
	my $ip = $ho->{IpStatic};
	$ip =~ s/\b0+//g;
	$v{'ipaddr'} = $ip;
	$v{'ipaddrhex'} = sprintf "%02X%02X%02X%02X", split /\./, $ip;
    }
    foreach my $pat (split /\s+/, $templates) {
	# we skip patterns that contain any references to undefined %var%s
	$pat =~ s{\%(\w*)\%}{
		    $1 eq '' ? '%' :
		    defined($v{$1}) ? $v{$1} :
		    next;
		 }ge;
	# and return the first pattern we managed to completely substitute
        return $pat;
    }
    die "no pxe template ($templatekey) matched $templates ".
        (join ",", sort keys %v)." ?";
}

sub setup_pxelinux_bootcfg ($$) {
    my ($ho, $bootfile) = @_;
    my $f= host_pxefile($ho);
    file_link_contents("$ho->{Tftp}{Path}$ho->{Tftp}{PxeDir}$f", $bootfile,
	"$ho->{Name}-pxelinux.cfg");
}

# Systems using BIOS are configured to use pxelinux
sub setup_pxeboot_di_bios ($$$$$;%) {
    my ($ho,$kern,$initrd,$dicmd,$hocmd,%xopts) = @_;
    my $dtbs = $xopts{dtbs} ? "fdtdir $xopts{dtbs}" : "";
    setup_pxelinux_bootcfg($ho, <<END);
    serial 0 $c{Baud}
timeout 5
label overwrite
	menu label ^Overwrite
	menu default
	kernel $kern
	append $dicmd initrd=$initrd -- $hocmd
	ipappend $xopts{ipappend}
	$dtbs
default overwrite
END
}

sub setup_pxeboot_local_bios ($) {
    my ($ho) = @_;
    setup_pxelinux_bootcfg($ho, <<END);
serial 0 $c{Baud}
timeout 5
label local
	LOCALBOOT 0
default local
END
}

# uboot emulates pxelinux, so reuse BIOS stuff
sub setup_pxeboot_di_uboot ($$$$$;%) { return &setup_pxeboot_di_bios; }
sub setup_pxeboot_local_uboot ($) { return &setup_pxeboot_local_bios; }

sub setup_grub_efi_bootcfg ($$) {
    my ($ho, $bootfile) = @_;
    my $f = "grub.cfg-$ho->{Ether}";
    my $grub= $ho->{Tftp}{Path}.'/'.$ho->{Tftp}{GrubBase}.'/'.
	$c{TftpGrubVersion}."/pxegrub-$r{arch}.efi";
    my $pxe=$ho->{Tftp}{Path}.'/'.$ho->{Name}.'/pxe.img';

    logm("Copy $grub => $pxe");
    copy($grub, $pxe) or die "Copy $grub to $pxe failed: $!";

    logm("grub_efi bootcfg into $f");
    file_link_contents("$ho->{Tftp}{Path}$ho->{Tftp}{TmpDir}$f",
		       $bootfile,  "$ho->{Name}-pxegrub.cfg");
}

# UEFI systems PXE boot using grub.efi
sub setup_pxeboot_di_uefi ($$$$$;%) {
    my ($ho,$kern,$initrd,$dicmd,$hocmd,%xopts) = @_;
    setup_grub_efi_bootcfg($ho, <<END);
set default=0
set timeout=5
menuentry 'overwrite' {
  linux $kern $dicmd -- $hocmd
  initrd $initrd
}
END
}

sub setup_pxeboot_local_uefi ($) {
    my ($ho) = @_;
    my %efi_archs = qw(amd64 X64
                       arm32 ARM
                       arm64 AARCH64
                       i386  IA32);
    die "EFI arch" unless $efi_archs{ $r{arch} };
    my $efi = $efi_archs{ $r{arch} };
    setup_grub_efi_bootcfg($ho, <<END);
set default=0
set timeout=5
menuentry 'local' {
  insmod chain
  insmod part_gpt
  insmod part_msdos
  set root=(hd0,gpt1)
  echo "Chainloading (\${root})/EFI/BOOT/BOOTAA64.EFI"
  chainloader (\${root})/EFI/BOOT/BOOTAA64.EFI
  boot
}
END
}

sub setup_pxeboot_local ($) {
    my ($ho) = @_;
    my $firmware = get_host_property($ho, "firmware", "bios");
    $firmware =~ s/-/_/g;
    no strict qw(refs);
    return &{"setup_pxeboot_local_${firmware}"}($ho);
}

sub setup_pxeboot_di ($$$$$;%) {
    my ($ho,$kern,$initrd,$dicmd,$hocmd,%xopts) = @_;
    my $firmware = get_host_property($ho, "firmware", "bios");
    $firmware =~ s/-/_/g;
    no strict qw(refs);
    return &{"setup_pxeboot_di_${firmware}"}($ho,$kern,$initrd,
					     join(' ',@{$dicmd}),
					     join(' ',@{$hocmd}),
					     %xopts);
}

#---------- ISO images ----------
sub iso_create_genisoimage ($$$$;@) {
    my ($ho,$iso,$dir,$isotimeout,@xopts) = @_;

    target_cmd_root($ho, <<END, $isotimeout);
        mkdir -p $dir
        genisoimage @xopts -o $iso $dir/.
END
}

sub iso_create_empty($$$) {
    my ($ho,$emptyiso,$emptydir) = @_;
    my @isogen_opts= qw(-R -J -T);

    iso_create_genisoimage($ho, $emptyiso, $emptydir, 60, @isogen_opts);
}

sub iso_gen_flags_basic() {
    return qw(-R -J -T
              -b isolinux/isolinux.bin
              -c isolinux/boot.cat
              -no-emul-boot
              -boot-load-size 4
              -boot-info-table);
}

sub iso_copy_content_from_image($$) {
    my ($gho,$newiso) = @_;
    return <<"END";
            set -ex
            umount /mnt ||:
            rm -rf $newiso
            mount -o loop -r $gho->{Rimage} /mnt
            mkdir $newiso
            cp -a /mnt/. $newiso/.
            umount /mnt
END
}

sub guest_editconfig_nocd ($$) {
    my ($gho,$emptyiso) = @_;
    guest_editconfig($gho->{Host}, $gho, sub {
        if (m/^\s*disk\s*\=/ .. /\]/) {
            s/\Q$gho->{Rimage}\E/$emptyiso/;
        }
        s/^on_reboot.*/on_reboot='restart'/;
    });
}

sub host_install_postboot_complete ($) {
    my ($ho) = @_;
    target_core_dump_setup($ho);
    target_cmd_root($ho, "update-rc.d osstest-confirm-booted start 99 2 .");
}

sub target_core_dump_setup ($) {
    my ($ho) = @_;
    target_cmd_root($ho, 'mkdir -p /var/core');
    target_editfile_root($ho, '/etc/sysctl.conf',
	sub { target_editfile_kvp_replace(
		  "kernel.core_pattern",
		  # %p==pid,%e==executable name,%t==timestamp
		  "/var/core/%t.%p.%e.core") });
    target_cmd_root($ho, "sysctl --load /etc/sysctl.conf");
    my $coredumps_conf = <<'END';
#<domain>      <type>  <item>       <value>
*               soft    core         -1
root            soft    core         -1
END
    target_putfilecontents_root_stash($ho,10,$coredumps_conf,
				'/etc/security/limits.d/coredumps.conf');
}

1;
