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


package Osstest::HostDB::Static;


use strict;
use warnings;

use Osstest;

BEGIN {
    use Exporter ();
    our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
    $VERSION     = 1.00;
    @ISA         = qw(Exporter);
    @EXPORT      = qw();
    %EXPORT_TAGS = ( );

    @EXPORT_OK   = qw();
}

sub new { return bless {}, $_[0]; }

sub get_properties ($$$) { #method
    my ($hd, $name, $hp) = @_;
}

sub get_flags ($$) { #method
    my ($hd, $ho) = @_;

    my $flags = { };
    my $process = sub {
	my $str = $c{$_[0]};
	return unless defined $str;
	foreach my $fl (split /[ \t,;]+/, $str) {
	    next unless length $fl;
	    if ($fl =~ s/^\!//) {
		delete $flags->{$fl};
	    } else {
		$flags->{$fl} = 1;
	    }
	}
    };

    $process->('HostFlags');
    $process->("HostGroupFlags_$ho->{Properties}{HostGroup}")
	if $ho->{Properties}{HostGroup};
    $process->("HostFlags_$ho->{Name}");

    return $flags;
}

sub default_methods ($$) { #method
    my ($hd, $ho) = @_;

    $ho->{Power} ||= "manual $ho->{Name}";
}

1;
