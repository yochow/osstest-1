# This is part of "osstest", an automated testing framework for Xen.
# Copyright (C) 2014 Citrix Inc.
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


package Osstest::Toolstack::xend;

use strict;
use warnings;

# Defer to xl driver for most things
use parent qw(Osstest::Toolstack::xl);

sub new {
    my ($class, $ho, $methname,$asset) = @_;
    return bless { Name => "xend",
		   Host => $ho,
		   NewDaemons => [qw(xend)],
		   OldDaemonInitd => 'xend',
		   _Command => 'xm',
		   _VerboseCommand => 'xm', # no verbosity here
		   Dom0MemFixed => 1,
    }, $class;
}

# xend always supported migration
sub migrate_check ($) { return 0; }

1;
