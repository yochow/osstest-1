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


package Osstest::Serial::sympathy;

use strict;
use warnings;

use Osstest;
use Osstest::TestSupport;

BEGIN {
    use Exporter ();
    our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
    $VERSION     = 1.00;
    @ISA         = qw(Exporter);
    @EXPORT      = qw();
    %EXPORT_TAGS = ( );

    @EXPORT_OK   = qw();
}

sub new {
    my ($class, $ho, $methname, @args) = @_;
    my $mo = { Host => $ho, Name => $ho->{Name} };
    die if @args<1;
    die if @args>3;
    push @args, '/root/sympathy/%host%' if @args<2;
    push @args, '/root/sympathy/%host%.log*' if @args<3;

    foreach (@args) {
	my $vn;
	my $org = $_;
	s/\%(\w*)\%/
	    !length $1 ? '' :
	    ($vn=$1) eq 'host' ? $ho->{Name} :
	    !defined $r{$vn} ? die "$ho->{Name} $org $_ $1 ?" :
	    $r{$vn}
        /ge; #/;
    };
    logm("serial method $methname $mo->{Host}{Name}: @args");
    ($mo->{Server}, $mo->{Socket}, $mo->{Pattern}) = @args;
    return bless $mo, $class;
}

sub request_debug {
    my ($mo,$conswitch,$xenkeys,$guestkeys) = @_;

    my $targhost= $mo->{Server};

    my ($sshopts) = sshopts();
    my $sympwrite= sub {
        my ($what,$str,$pause) = @_;
        logm("sympathy sending $what");
        if (!eval {
            local ($SIG{'PIPE'}) = 'IGNORE';
            my $sock= $mo->{Socket};
            my $rcmd= "sympathy -c -k $sock -N >/dev/null";
            $rcmd= "alarm 5 $rcmd";
            open SYMPWRITE, "|ssh @$sshopts root\@$targhost '$rcmd'" or die $!;
            autoflush SYMPWRITE 1;
            print SYMPWRITE $str or die $!;
            sleep($pause);
            close SYMPWRITE or die "$? $!";
            1;
        }) {
            warn "failed to send $what: $@\n";
            return 0;
        }
        return 1;
    };

    my $debugkeys= sub {
	my ($what, $keys) = @_;
	foreach my $k (split //, $keys) {
	    $sympwrite->("$what debug info request, debug key $k", $k, 2);
	}
    };

    $sympwrite->('request for input to Xen', $conswitch, 1);
    $debugkeys->('Xen', $xenkeys);
    sleep(10);
    $debugkeys->('guest', $guestkeys);
    sleep(10);
    $sympwrite->("RET to dom0","$conswitch\r", 5);

    return 1;
}

sub fetch_logs {
    my ($mo) = @_;

    my $started= $mjobdb->jobdb_flight_started_for_log_capture($flight);

    my $ho = $mo->{Host};
    my $logpat = $mo->{Pattern};
    my $targhost= $mo->{Server};

    logm("collecting serial logs since $started from $targhost");

    my $remote= remote_perl_script_open
        ($targhost, "serial $targhost $ho->{Name}", <<'END');

        use warnings;
        use strict qw(refs vars);
        use IO::File;
        $|=1;
        my $started= <DATA>;  defined $started or die $!;
        my $logpat= <DATA>;   defined $logpat or die $!;

        my %done;
        for (;;) {
            my $anydone= 0;
            foreach my $logfile (glob $logpat) {
                my $lh= new IO::File $logfile, 'r';
                if (!defined $lh) {
                    $!==&ENOENT or warn "$logfile $!";
                    next;
                }
                stat $lh or die "$logfile $!";
                my $inum= (stat _)[1];
                my $lfage= (stat _)[9];
                if ($lfage < $started) {
                    next if $done{$inum};
                    print "M $logfile modified $lfage, skipping\n" or die $!
                        unless $done{$inum};
                    $done{$inum}= 1;
                    next;
                }
                next if defined $done{$inum} and $done{$inum} >= 2;
                $done{$inum}= 2;
                print "F $logfile\n" or die $!;
                for (;;) {
                    my $data;
                    my $r= read $lh, $data, 65536;
                    die "$logfile $!" unless defined $r;
                    print "D ".(length $data)."\n" or die $!;
                    print $data or die $!;
                    last unless $r;
                }
                print "E\n" or die $!;
                $anydone= 1;
            }
            last unless $anydone;
        }
        print "X\n" or die $!;
END

    my $w= $remote->{Write};
    print( $w "$started\n$logpat\n" ) or die $!;

    for (;;) {
        $_= $remote->{Read}->getline();
        chomp or die $!;
        last if m/^X$/;
        if (s/^M //) { logm($_); next; }
        m/^F (\S+)$/ or die "$_ $!";
        my $logfile= $1;
        my $df= $logfile;
        $df =~ s,.*/,,;
        $df = "serial-$df";
        logm("stashing $logfile as $df");

        my $dh= open_unique_stashfile(\$df);
        for (;;) {
            $_= $remote->{Read}->getline();
            chomp or die $!;
            last if m/^E$/;
            m/^D (\d+)$/ or die "$_ $!";
            my $len= $1;
            my $data;
            my $r= read $remote->{Read}, $data, $len;
            die $! unless $r==$len;
            print $dh $data or die "$df $!";
        }
        close $dh or die "$df $!";
    }

    remote_perl_script_done($remote);
}

1;
