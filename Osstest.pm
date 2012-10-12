
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
                      csreadconfig
                      getmethod
                      $dbh_tests db_retry db_begin_work                      
                      testscript_start
                      );
    %EXPORT_TAGS = ( );

    @EXPORT_OK   = qw();
}

our $mhostdb;
our $mjobdb;

our $dbh_tests;

#---------- static default config settings ----------

our %c = qw(job-db Standalone
            host-db Static);

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

    my $cfgfile = $ENV{'OSSTEST_CONFIG'} || "$ENV{'HOME'}/.osstest/config";
    if (!open C, '<', "$cfgfile") {
	die "$cfgfile $!" unless $!==&ENOENT;
    } else {
	while (<C>) {
	    die "missing newline" unless chomp;
	    s/^\s*//;
	    s/\s+$//;
	    next if m/^\#/;
	    m/^([a-z][0-9a-zA-Z-]*)\s+(\S.*)$/ or die "bad syntax";
	    $c{$1} = $2;
	}
	close C or die "$cfgfile $!";
    }

    # dynamic default config settings
    $c{'executive-dbi-pat'} ||= "dbi:Pg:dbname=<dbname>;user=<whoami>;".
	"host=<dbname>.db.$c{'dns-domain'};".
	"password=<~/.osstest/db-password>"
	if defined $c{'dns-domain'};
    # 1. <\w+> is replaced with variables:
    #         <dbname>    database name
    # 2. <~/path> </path> <./path> are replaced with contents of specified file
    # 3. <[> and <]> are replaced with < and >

    $mjobdb = getmethod("Osstest::JobDB::$c{'job-db'}");
    $mhostdb = getmethod("Osstest::HostDB::$c{'host-db'}");
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

#---------- script entrypoints ----------

sub csreadconfig () {
    readglobalconfig();
    $dbh_tests = $mjobdb->open();
}

1;
