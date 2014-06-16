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


package Osstest::Toolstack::xl;

use strict;
use warnings;

use Osstest::TestSupport;

sub new {
    my ($class, $ho, $methname,$asset) = @_;
    return bless { Name => "xl",
		   Host => $ho,
		   NewDaemons => [],
		   Dom0MemFixed => 1,
		   Command => 'xl',
		   CfgPathVar => 'cfgpath',
		   RestoreNeedsConfig => 1,
    }, $class;
}

sub destroy ($$) {
    my ($self,$gho) = @_;
    my $gn = $gho->{Name};
    target_cmd_root($self->{Host}, $self->{Command}." destroy $gn", 40);
}

sub create ($$) {
    my ($self,$cfg) = @_;
    target_cmd_root($self->{Host}, $self->{Command}." create $cfg", 100);
}

1;
