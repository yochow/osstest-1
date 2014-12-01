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

sub consolecmd ($$) {
    my ($self,$gho) = @_;
    my $gn = $gho->{Name};
    return $self->{Command}." console $gn";
}

sub shutdown_wait ($$$) {
    my ($self,$gho,$timeout) = @_;
    my $ho = $self->{Host};
    my $gn = $gho->{Name};
    target_cmd_root($ho,"$self->{Command} shutdown -w $gn", $timeout);
}

sub migrate_check ($) {
    my ($self) = @_;
    my $ho = $self->{Host};
    my $help = target_cmd_output_root($ho, $self->{Command}." help");
    my $rc = ($help =~ m/^\s*migrate/m) ? 0 : 1;
    logm("rc=$rc");
    return $rc;
}

sub migrate ($$$$) {
    my ($self,$gho,$dho,$timeout) = @_;
    my $sho = $self->{Host};
    my $dst = $dho->{Name};
    my $gn = $gho->{Name};
    target_cmd_root($sho,
		    $self->{Command}." migrate $gn $dst",
		    $timeout);
}

sub save ($$$$) {
    my ($self,$gho,$f,$timeout) = @_;
    my $ho = $self->{Host};
    my $gn = $gho->{Name};
    target_cmd_root($ho,$self->{Command}." save $gn $f", $timeout);
}

sub restore ($$$$) {
    my ($self,$gho,$f,$timeout) = @_;
    my $ho = $self->{Host};
    my $gn = $gho->{Name};
    my $cfg = $self->{RestoreNeedsConfig} ? $gho->{CfgPath} : '';
    target_cmd_root($ho,
		    $self->{Command}
		    ." restore "
		    .$cfg
		    ." $f", $timeout);
}

1;
