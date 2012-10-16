
package Osstest;

use strict;
use warnings;

use POSIX;

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
                      $dbh_tests db_retry db_begin_work                      
                      ensuredir get_filecontents_core_quiet system_checked
                      nonempty
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

   TestHostKeypairPath id_rsa_osstest
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

    $c{HostProp_DhcpWatchMethod} = 'leases dhcp3 /var/lib/dhcp3/dhcpd.leases';
    $c{AuthorizedKeysFiles} = '';
    $c{AuthorizedKeysAppend} = '';

    my $cfgvar_re = '[A-Z][0-9a-zA-Z-_]*';

    my $cfgfile = $ENV{'OSSTEST_CONFIG'} || "$ENV{'HOME'}/.osstest/config";
    if (!open C, '<', "$cfgfile") {
	die "$cfgfile $!" unless $!==&ENOENT;
    } else {
	while (<C>) {
	    die "missing newline" unless chomp;
	    s/^\s*//;
	    s/\s+$//;
	    next if m/^\#/;
	    next unless m/\S/;
	    if (m/^($cfgvar_re)\s+(\S.*)$/) {
		$c{$1} = $2;
	    } elsif (m/^($cfgvar_re)=\s*\<\<\'(.*)\'\s*$/) {
		my ($vn,$delim) = ($1,$2);
		my $val = '';
		$!=0; while (<C>) {
		    last if $_ eq "$delim\n";
		    $val .= $_;
		}
		die $! unless length $_;
		$c{$vn} = $val;
	    } elsif (m/^($cfgvar_re)=(.*)$/) {
		eval "\$c{$1} = ( $2 ); 1;" or die $@;
	    } else {
		die "bad syntax";
	    }
	}
	close C or die "$cfgfile $!";
    }

    # dynamic default config settings
    $c{ExecutiveDbnamePat} ||= "dbname=<dbname>;user=<whoami>;".
	"host=<dbname>.db.$c{DnsDomain};".
	"password=<~/.osstest/db-password>"
	if defined $c{DnsDomain};
    # 1. <\w+> is replaced with variables:
    #         <dbname>    database name
    # 2. <~/path> </path> <./path> are replaced with contents of specified file
    # 3. <[> and <]> are replaced with < and >

    $mjobdb = getmethod("Osstest::JobDB::$c{JobDB}");
    $mhostdb = getmethod("Osstest::HostDB::$c{HostDB}");

    $c{TestHostDomain} ||= $c{DnsDomain};
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
    $mjobdb->begin_work($dbh, @$tables);
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

sub jobdb_postfork () {
    $mjobdb->postfork();
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

1;
