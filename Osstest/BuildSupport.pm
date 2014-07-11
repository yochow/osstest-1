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

                      submodulefixup submodule_have

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
    $builddir= target_jobdir($ho);
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
    $xendist = target_extract_jobdistpath_subdir
	($ho, 'xendist', '', $r{"buildjob"});
}

#----- submodules -----

sub submodulefixup ($$$$) {
    my ($ho, $subdir, $basewhich, $submodmap) = @_;

    my @submodules;
    target_editfile($ho, "$builddir/$subdir/.gitmodules",
		    "$subdir-gitmodules", sub {
        my $submod;
	my $log1 = sub { logm("submodule $submod->{OurName} @_"); };
        while (<::EI>) {
	    if (m/^\[submodule \"(.*)\"\]$/) {
		$submod = { TheirName => $1 },
		push @submodules, $submod;
		my $mapped = $submodmap->{$1};
		die "unknown submodule $1" unless defined $mapped;
		$submod->{OurName} = $mapped;
		$log1->("($submod->{TheirName}):");
	    } elsif (m/^\s*path\s*=\s*(\S+)/) {
		die unless $submod;
		$submod->{Path} = $1;
		$log1->("  subpath=$submod->{Path}");
	    } elsif (m/^(\s*url\s*\=\s*)(\S+)/) {
		die unless $submod;
		my $l = $1;
		my $u = $submod->{OrgUrl} = $2;
		my $urv = "tree_${basewhich}_$submod->{OurName}";
		if (length $r{$urv}) {
		    $log1->("  overriding url=$u with runvar $urv=$r{$urv}");
		    $u = $r{$urv};
		} else {
		    $log1->("  recording url=$u");
		    store_runvar($urv, $u);
		}
		my $nu = $submod->{Url} =
		    git_massage_url($u, GitFetchBestEffort => 1);
		# If we don't manage to fetch a version which contains the
		# necessary commit(s), we will fail later.
		$_ = "${l}${nu}\n";
	    }
	    print ::EO or die $!;
	}
    });

    target_cmd_build($ho,  60,"$builddir/$subdir","git submodule init");
    target_cmd_build($ho,3600,"$builddir/$subdir","git submodule update");

    foreach my $submod (@submodules) {
	my $wantrev = $r{"revision_${basewhich}_$submod->{OurName}"};
	if (length $wantrev) {
	    target_cmd_build($ho,200,"$builddir/$subdir/$submod->{Path}",
			     "git reset --hard $wantrev");
	} else {
	    store_revision($ho, "${basewhich}_$submod->{OurName}",
			   "$builddir/$subdir/$submod->{Path}");
	}
    }

    return \@submodules;
}

sub submodule_have ($$) {
    my ($submodules, $ourname) = @_;
    return !!grep { $_->{OurName} eq $ourname } @$submodules;
}

1;
