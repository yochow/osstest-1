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


package Osstest::BuildSupport;

use strict;
use warnings;

use POSIX;
use IO::File;

use Osstest::TestSupport;

BEGIN {
    use Exporter ();
    our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
    $VERSION     = 1.00;
    @ISA         = qw(Exporter);
    @EXPORT      = qw(

                      selectbuildhost
                      $whhost $ho

                      builddirsprops
                      $builddir $makeflags

                      prepbuilddirs

                      xendist
                      $xendist

                      );
    %EXPORT_TAGS = ( );

    @EXPORT_OK   = qw();
}

our ($whhost,$ho);
our ($builddir,$makeflags);
our ($xendist);

sub selectbuildhost {
    # pass @ARGV
    ($whhost) = @_;
    $whhost ||= 'host';
    $ho= selecthost($whhost);
}

sub builddirsprops {
    my (%xbuildopts) = @_;

    $xbuildopts{DefMakeFlags} ||= '-j4';

    my $leaf= "build.$flight.$job";
    my $homedir = get_host_property($ho, 'homedir', '/home/osstest');
    $builddir= "$homedir/$leaf";

    $makeflags= get_host_property($ho, 'build make flags',
				  $xbuildopts{DefMakeFlags});
}

sub prepbuilddirs {
    my (@xbuilddirs) = @_;
    my $cmd = "rm -rf $builddir && mkdir $builddir";
    $cmd .= " && mkdir $builddir/$_" foreach @xbuilddirs;
    target_cmd($ho,$cmd,600);
}

sub xendist () {
    $xendist= "$builddir/xendist";
    target_cmd($ho,"rm -rf $xendist && mkdir $xendist",60);

    my $path = get_stashed("path_dist", $r{"buildjob"});
    my $distcopy= "$builddir/dist.tar.gz";
    target_putfile($ho, 300, $path, $distcopy);
    target_cmd($ho, "tar -C $xendist -hzxf $distcopy", 300);
}

1;
