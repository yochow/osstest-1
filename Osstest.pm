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

package Osstest;

use strict;
use warnings;

use POSIX;
use File::Basename;
use IO::File;

BEGIN {
    use Exporter ();
    our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
    $VERSION     = 1.00;
    @ISA         = qw(Exporter);
    @EXPORT      = qw(
                      readglobalconfig %c $mjobdb $mhostdb
                      augmentconfigdefaults
                      csreadconfig
                      getmethod
                      postfork
                      $dbh_tests db_retry db_retry_retry db_retry_abort
                      db_begin_work
                      ensuredir get_filecontents_core_quiet system_checked
                      nonempty visible_undef show_abs_time
                      );
    %EXPORT_TAGS = ( );

    @EXPORT_OK   = qw();
}

our $mhostdb;
our $mjobdb;

our $dbh_tests;

#---------- static default config settings ----------

our %c = qw(

    JobDB Standalone
    HostDB Static

    Stash logs
    Images images
    Logs logs
    Results results

    DebianSuite wheezy
    DebianMirrorSubpath debian

    TestHostKeypairPath id_rsa_osstest
    HostProp_GenEtherPrefixBase 5e:36:0e:f5

    HostDiskBoot   300
    HostDiskRoot 10000
    HostDiskSwap  2000

    Baud  115200

    DebianNonfreeFirmware firmware-bnx2

    HostnameSortSwapWords 0
);

$c{$_}='' foreach qw(
    DebianPreseed
    DebianMirrorProxy
    TftpPxeTemplatesReal
);

#---------- general setup and config reading ----------

sub getmethod {
    my $class = shift @_;
    my $r;
    eval "
        require $class;
        $class->import();
        \$r = $class->new(\@_);
    " or die $@;
    return $r;
}

sub readglobalconfig () {
    our $readglobalconfig_done;
    return if $readglobalconfig_done;
    $readglobalconfig_done=1;

    $c{OsstestUpstream} = 'git://xenbits.xen.org/osstest.git master';

    $c{HostProp_DhcpWatchMethod} = 'leases dhcp3 infra:5556';
    $c{AuthorizedKeysFiles} = '';
    $c{AuthorizedKeysAppend} = '';

    my $cfgvar_re = '[A-Z][0-9a-zA-Z-_]*';

    my $cfgfiles = $ENV{'OSSTEST_CONFIG'} || "$ENV{'HOME'}/.xen-osstest/config";

    my $readcfg;
    $readcfg = sub ($$) {
	my ($cfgfile,$enoent_ok) = @_;
	my $fh = new IO::File $cfgfile, '<';
	if (!$fh) {
	    die "$cfgfile $!" unless $enoent_ok && $!==&ENOENT;
	    return;
	}
	while (<$fh>) {
	    die "missing newline" unless chomp;
	    s/^\s*//;
	    s/\s+$//;
	    next if m/^\#/;
	    next unless m/\S/;
	    if (m/^include\s+(\S.*)$/i) {
		my $newfn = $1;
		if ($newfn !~ m#^/|^\./#) {
		    $newfn = dirname($cfgfile)."/".$newfn;
		}
		$readcfg->($newfn, 0);
	    } elsif (m/^($cfgvar_re)\s+(\S.*)$/) {
		$c{$1} = $2;
	    } elsif (m/^($cfgvar_re)=\s*\<\<(\'?)(.*)\2\s*$/) {
		my ($vn,$qu,$delim) = ($1,$2,$3);
		my $val = '';
		$!=0; while (<$fh>) {
		    last if $_ eq "$delim\n";
		    $val .= $_;
		}
		die $! unless length $_;
		die unless !length $val || $val =~ m/\n$/;
		if ($qu eq '') {
		    my $reconstruct =
			"\$val = <<${qu}${delim}${qu}; 1;\n".
			"${val}${delim}\n";
		    eval $reconstruct or
			die "$1 here doc ($reconstruct) $@";
		}
		$c{$vn} = $val;
	    } elsif (m/^($cfgvar_re)=(.*)$/) {
		eval "\$c{$1} = ( $2 ); 1;" or die "$1 parsed val ($2) $@";
	    } else {
		die "bad syntax";
	    }
	}
	close $fh or die "$cfgfile $!";
    };

    foreach my $cfgfile (split /\:/, $cfgfiles) {
	$readcfg->($cfgfile, 1);
    }

    # dynamic default config settings
    $c{ExecutiveDbnamePat} ||= "dbname=<dbname>;user=<whoami>;".
	"host=<dbname>.db.$c{DnsDomain};".
	"password=<~/.xen-osstest/db-password>"
	if defined $c{DnsDomain};
    # 1. <\w+> is replaced with variables:
    #         <dbname>    database name
    # 2. <~/path> </path> <./path> are replaced with contents of specified file
    # 3. <[> and <]> are replaced with < and >

    $mjobdb = getmethod("Osstest::JobDB::$c{JobDB}");
    $mhostdb = getmethod("Osstest::HostDB::$c{HostDB}");

    $c{TestHostDomain} ||= $c{DnsDomain};

    my $whoami = `whoami` or die $!;
    chomp($whoami) or die;

    my $nodename = `uname -n` or die $!;
    chomp($nodename) or die;
    my $myfqdn = "$nodename.$c{DnsDomain}";

    $c{TftpDefaultScope} ||= "default";

    $c{TftpPath} ||= "/tftpboot/";
    $c{TftpPxeDir} ||= "pxelinux.cfg/";
    $c{TftpPxeTemplates} ||= '%ipaddrhex% 01-%etherhyph%';
    $c{TftpPlayDir} ||= "$whoami/osstest/";
    $c{TftpTmpDir} ||= "$c{TftpPlayDir}tmp/";

    $c{TftpDiBase} ||= "$c{TftpPlayDir}debian-installer";
    $c{TftpDiVersion} ||= 'current';

    $c{WebspaceFile} ||= "$ENV{'HOME'}/public_html/";
    $c{WebspaceUrl} ||= "http://$myfqdn/~$whoami/";
    $c{WebspaceCommon} ||= 'osstest/';
    $c{WebspaceLog} ||= '/var/log/apache2/access.log';

    $c{OverlayLocal} ||= "overlay-local";
    $c{GuestDebianSuite} ||= $c{DebianSuite};

    $c{DefaultBranch} ||= 'xen-unstable';

    $c{DebianMirrorHost} ||= 'ftp.debian.org' if $c{DebianMirrorProxy};
}

sub augmentconfigdefaults {
    while (my $k = shift @_) {
	my $v = shift @_;
	next if defined $c{$k};
	$c{$k} = $v;
    }
}

#---------- database access ----------

our $db_retry_stop;

sub db_retry_abort () { $db_retry_stop= 'abort'; undef; }
sub db_retry_retry () { $db_retry_stop= 'retry'; undef; }

sub db_begin_work ($;$) {
    my ($dbh,$tables) = @_;
    $dbh->begin_work();
    $mjobdb->begin_work($dbh, $tables);
}

sub db_retry ($$$;$$) {
    # $code should return whatever it likes, and that will
    #     be returned by db_retry
    # $code may be [ \&around_loop_init, \&actual_code ]
    my ($fl,$flok, $dbh,$tables,$code) = (@_==5 ? @_ :
                                          @_==3 ? (undef,undef,@_) :
                                          die);
    my ($pre,$body) =
        (ref $code eq 'ARRAY') ? @$code : (sub { }, $code);

    my $retries= 20;
    my $r;
    local $db_retry_stop;
    for (;;) {
        $pre->();

        db_begin_work($dbh, $tables);
        if (defined $fl) {
            die unless $dbh eq $dbh_tests;
            $mjobdb->dbfl_check($fl,$flok);
        }
        $db_retry_stop= 0;
        $r= &$body;
        if ($db_retry_stop) {
            $dbh->rollback();
            last if $db_retry_stop eq 'abort';
        } else {
            last if eval { $dbh->commit(); 1; };
        }
        die "$dbh $body $@ ?" unless $retries-- > 0;
        sleep(1);
    }
    return $r;
}

sub postfork () {
    $mjobdb->jobdb_postfork();
}

#---------- script entrypoints ----------

sub csreadconfig () {
    readglobalconfig();
    $dbh_tests = $mjobdb->open();
}

#---------- generally useful subroutines ----------

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

sub ensuredir ($) {
    my ($dir)= @_;
    mkdir($dir) or $!==&EEXIST or die "$dir $!";
}

sub system_checked {
    $!=0; $?=0; system @_;
    die "@_: $? $!" if $? or $!;
}

sub nonempty ($) {
    my ($v) = @_;
    return defined($v) && length($v);
}

sub visible_undef ($) {
    my ($v) = @_;
    return defined $v ? $v : '<undef>';
}

sub show_abs_time ($) {
    my ($timet) = @_;
    return strftime "%Y-%m-%d %H:%M:%S Z", gmtime $timet;
}

1;
