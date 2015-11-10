# This is part of "osstest", an automated testing framework for Xen.
# Copyright (C) 2015 Citrix Inc.
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


package Osstest::Serial::keys_real;

# Base class providing debug keys for real serial ports.
# Derived class is expected to provide:
#   $mo->keys_prepare();
#   $mo->keys_prepare($what,$str,$pause);
#   $mo->keys_shutdown();


use strict;
use warnings;

use Osstest::TestSupport;

sub request_debug {
    my ($mo,$conswitch,$xenkeys,$guestkeys) = @_;

    if (!eval {
	local ($SIG{'PIPE'}) = 'IGNORE';

	$mo->keys_prepare();

	my $debugkeys= sub {
	    my ($what, $keys) = @_;
	    foreach my $k (split //, $keys) {
		$mo->keys_write("$what debug info request, debug key $k",
				$k, 2);
	    }
	};

	$mo->keys_write('request for input to Xen', $conswitch, 1);
	$debugkeys->('Xen', $xenkeys);
	sleep(10);
	$debugkeys->('guest', $guestkeys);
	sleep(10);
	$mo->keys_write("RET to dom0","$conswitch\r", 5);

	$mo->keys_shutdown();

	1;
    }) {
	warn "failed to send debug key(s): $@\n";
	return 0;
    }
    return 1;
}

1;
