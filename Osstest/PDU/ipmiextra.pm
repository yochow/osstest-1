# This is part of "osstest", an automated testing framework for Xen.
# Copyright (C) 2013 Citrix Inc.
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

package Osstest::PDU::ipmiextra;

use strict;
use warnings;

use Osstest;
use Osstest::TestSupport;
use IO::File;

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
    my ($class, $ho, $methname, $when, $mgmt, $user, $pass, @opts) = @_;
    return bless { Host => $ho,
		   When => $when,
		   Mgmt => $mgmt,
		   User => $user,
		   Pass => $pass,
		   Opts => \@opts }, $class;
}

sub pdu_power_state {
    my ($mo, $on) = @_;
    my $onoff= $on ? "on" : "off";

    system_checked("ipmitool",
		   "-H", "$mo->{Mgmt}",
		   "-U", $mo->{User},
		   "-P", $mo->{Pass},
		   @{$mo->{Opts}})
	if $onoff eq $mo->{When} || $mo->{When} eq "both";
}

1;
