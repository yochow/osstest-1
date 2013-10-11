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

# Send debug keys via xenuse.

package Osstest::Serial::xenuse;

use strict;
use warnings;

use Osstest;
use Osstest::TestSupport;

use File::Temp;
use File::Copy;

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

    logm("serial method $methname $mo->{Host}{Name}: @args");
    return bless $mo, $class;
}

sub request_debug {
    my ($mo,$conswitch,$xenkeys,$guestkeys) = @_;
    my $xenuse= $c{XenUsePath} || "xenuse";

    my $ho= $mo->{Host};

    my $writer= sub {
        my ($what,$str,$pause) = @_;
        logm("xenuse sending $what");
        if (!eval {
            print XENUSEWRITE $str or die $!;
            sleep($pause);
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
	    $writer->("$what debug info request, debug key $k", $k, 2);
	}
    };

    local ($SIG{'PIPE'}) = 'IGNORE';
    open XENUSEWRITE, "|$xenuse -t $ho->{Name}" or die $!;
    autoflush XENUSEWRITE 1;

    $writer->('force attach', "\x05cf", 1); # ^E c f == force attach

    $writer->('request for input to Xen', $conswitch, 1);
    $debugkeys->('Xen', $xenkeys);
    sleep(10);
    $debugkeys->('guest', $guestkeys);
    sleep(10);
    $writer->("RET to dom0","$conswitch\r", 5);

    $writer->('dettach', "\x05c.", 1); # ^E c . == disconnect

    close XENUSEWRITE or die "$? $!";

    return 1;
}

sub fetch_logs {
    return;
}

1;
