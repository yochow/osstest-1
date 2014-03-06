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

package Osstest::CXFabric;

use strict;
use warnings;

use Osstest;
use Osstest::TestSupport;

BEGIN {
    use Exporter ();
    our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
    $VERSION     = 1.00;
    @ISA         = qw(Exporter);
    @EXPORT      = qw(
                      setup_cxfabric
                      );
    %EXPORT_TAGS = ( );

    @EXPORT_OK   = qw();
}

sub setup_cxfabric($)
{
    my ($ho) = @_;

    # This is only needed on Calxeda boxes, which given that they have folded
    # is unlikely to be anything other than exactly our marilith box.
    return unless $ho->{Flags}{'equiv-marilith'};

    logm("Setting up CX fabric hook script");

    if ( $ho->{Suite} =~ m/wheezy/ )
    {
        # iproute2 is not in Wheezy nor wheezy-backports. Use our own backport.
        my $images = "$c{Images}/wheezy-iproute2";
        my $ver = '3.12.0-1~xen70+1';
        my @debs = ("iproute_${ver}_all.deb", "iproute2_${ver}_armhf.deb");

        target_putfile_root($ho, 10, "$images/$_", $_) foreach @debs;
        target_cmd_root($ho, "dpkg -i @debs");
    } else {
        target_install_packages($ho, qw(iproute2));
    }

    target_cmd_root($ho, 'mkdir -p /etc/xen/scripts/vif-post.d');
    target_putfilecontents_root_stash($ho,10,<<'END','/etc/xen/scripts/vif-post.d/cxfabric.hook');
# (De)register the new device with the CX Fabric. Ignore errors from bridge fdb
# since the MAC might already be present etc.
cxfabric() {
	local command=$1
	local mac=$(xenstore_read "$XENBUS_PATH/mac")
	case $command in
	online|add)
		log debug "Adding $mac to CXFabric fdb"
		do_without_error bridge fdb add $mac dev eth0
		;;
	offline)
		log debug "Removing $mac from CXFabric fdb"
		do_without_error bridge fdb del $mac dev eth0
		;;
	esac
}
cxfabric $command

END
    target_cmd_root($ho, 'chmod +x /etc/xen/scripts/vif-post.d/cxfabric.hook');
}

1;
