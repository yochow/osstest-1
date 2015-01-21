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


package Osstest::Toolstack::libvirt;

use strict;
use warnings;

use Osstest::TestSupport;

sub new {
    my ($class, $ho, $methname,$asset) = @_;
    return bless { Name => "libvirt",
		   Host => $ho,
		   NewDaemons => [qw(libvirtd)],
		   Dom0MemFixed => 1,
		   ExtraPackages => [qw(libnl1 libavahi-client3)],
    }, $class;
}

sub destroy ($$) {
    my ($self,$gho) = @_;
    my $gn = $gho->{Name};
    target_cmd_root($self->{Host}, "virsh destroy $gn", 40);
}

sub create ($$) {
    my ($self,$gho) = @_;
    my $ho = $self->{Host};
    my $cfg = $gho->{CfgPath};
    my $lcfg = $cfg;
    $lcfg =~ s,/,-,g;
    $lcfg = "$ho->{Name}--$lcfg";
    target_cmd_root($ho, "virsh domxml-from-native xen-xl $cfg > $cfg.xml", 30);
    target_getfile_root($ho,60,"$cfg.xml", "$stash/$lcfg");
    target_cmd_root($ho, "virsh create --file $cfg.xml", 100);
}

sub consolecmd ($$) {
    my ($self,$gho) = @_;
    my $gn = $gho->{Name};
    return "virsh console $gn";
}

sub shutdown_wait ($$$) {
    my ($self,$gho,$timeout) = @_;
    my $ho = $self->{Host};
    my $gn = $gho->{Name};
    target_cmd_root($ho, "virsh shutdown $gn", 30);
    guest_await_destroy($gho,$timeout);
}

sub migrate_check ($) {
    my ($self) = @_;
    die "Migration check is not yet supported on libvirt.";
}

sub migrate ($) {
    my ($self,$gho,$dst,$timeout) = @_;
    die "Migration is not yet supported on libvirt.";
}

sub save ($$$$) {
    my ($self,$gho,$f,$timeout) = @_;
    die "Save is not yet supported on libvirt.";
}

sub restore ($$$$) {
    my ($self,$gho,$f,$timeout) = @_;
    die "Restore is not yet supported on libvirt.";
}

1;
