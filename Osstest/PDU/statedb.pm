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


package Osstest::PDU::statedb;

use strict;
use warnings;

use Osstest;
use Osstest::Executive;
use Osstest::TestSupport;

sub power_state_await ($$$) {
    my ($sth, $want, $msg) = @_;
    poll_loop(30,1, "power: $msg $want", sub {
        $sth->execute();
        my ($got) = $sth->fetchrow_array();
        $sth->finish();
        return undef if $got eq $want;
        return "state=\"$got\"";
    });
}

sub new {
    my ($class, $ho, $methname,$asset) = @_;
    return bless { Asset => $asset }, $class;
}

sub power_state {
    my ($mo,$on) = @_;
    my $asset = $mo->{Asset};

    my $want= (qw(s6 s1))[!!$on];

    my $dbh_state= opendb_state();
    my $sth= $dbh_state->prepare
        ('SELECT current_power FROM control WHERE asset = ?');

    my $current= $dbh_state->selectrow_array
        ('SELECT desired_power FROM control WHERE asset = ?',
         undef, $asset);
    die "not found $asset" unless defined $current;

    $sth->bind_param(1, $asset);
    power_state_await($sth, $current, 'checking');

    my $rows= $dbh_state->do
        ('UPDATE control SET desired_power=? WHERE asset=?',
         undef, $want, $asset);
    die "$rows updating desired_power for $asset in statedb::control\n"
        unless $rows==1;
    
    $sth->bind_param(1, $asset);
    power_state_await($sth, $want, 'awaiting');
    $sth->finish();

    $dbh_state->disconnect();
}

1;
