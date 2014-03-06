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

    my $nr = 8;

    my $prefix = ether_prefix($ho);
    logm("Registering $nr MAC addresses with CX fabric using prefix $prefix");

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

    my $banner = '# osstest: register potential guest MACs with CX fabric';
    my $rclocal = "$banner\n";
    # Osstest::TestSupport::select_ether allocates sequentially from $prefix:00:01
    my $i = 0;
    while ( $i++ < $nr ) {
        $rclocal .= sprintf("bridge fdb add $prefix:%02x:%02x dev eth0\n",
                            $i >> 8, $i & 0xff);
    }

    target_editfile_root($ho, '/etc/rc.local', sub {
        my $had_banner = 0;
        while (<::EI>) {
            $had_banner = 1 if m/^$banner$/;
            print ::EO $rclocal if m/^exit 0$/ && !$had_banner;
            print ::EO;
        }
    });

}

1;
