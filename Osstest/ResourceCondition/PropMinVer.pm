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

package Osstest::ResourceCondition::PropMinVer;

use strict;
use warnings;

use Osstest;
use Osstest::TestSupport;

use Sort::Versions;

use overload '""' => 'stringify';

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
    my ($class, $name, $prop, $val) = @_;

    die "propname: $prop?" unless propname_check($prop);

    return bless {
	Prop => $prop,
	MinVal => $val
    }, $class;
}

sub stringify {
    my ($pmv) = @_;
    return "$pmv->{MinVal} >=(v) property $pmv->{Prop}";
}

sub check {
    my ($pmv, $restype, $resname) = @_;

    # Using _cached avoids needing to worry about $dbh_tests being
    # closed/reopened between invocations
    my $hpropq = $dbh_tests->prepare_cached(<<END);
       SELECT val FROM resource_properties
	WHERE restype = ? AND resname = ? AND name = ?
END
    $hpropq->execute($restype, $resname, $pmv->{Prop});

    my $row= $hpropq->fetchrow_arrayref();
    $hpropq->finish();

    return 1 unless $row; # No prop == no restriction.

    # If the maximum minimum is >= to the resource's minimum then the
    # resource meets the requirement.
    return versioncmp($pmv->{MinVal}, $row->[0]) >= 0;
}

1;
