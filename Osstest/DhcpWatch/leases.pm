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


package Osstest::DhcpWatch::leases;

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
    my ($class, $ho, $meth, $format, $source) = @_;
    die "$format (@_) ?" unless $format eq 'dhcp3';
    return bless {
	Format => $format,
	Source => $source,
    }, $class;
}

sub check_ip ($$) {
    my ($mo, $gho) = @_;

    my $leases;
    my $leasesfn = $mo->{Source};

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

1;
