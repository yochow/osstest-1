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


package Osstest::Management;

use strict;
use warnings;

use Osstest;

BEGIN {
    use Exporter ();
    our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
    $VERSION     = 1.00;
    @ISA         = qw(Exporter);
    @EXPORT      = qw(
                      );
    %EXPORT_TAGS = (
	'logs' => [qw(logs_select onloghost logcfg
                      $logcfgbase $loghost $logdir @logsshopts)]
	            );

    @EXPORT_OK   = qw();

    Exporter::export_ok_tags(qw(logs));
}

our ($logcfgbase, $loghost, $logdir);
our @logsshopts= qw(-o batchmode=yes);

sub logs_select ($) {
    ($logcfgbase) = @_;
    my $cfgvalue = $c{$logcfgbase};
    return 0 unless $cfgvalue;
    if ($cfgvalue =~ m/\:/) {
	($loghost, $logdir) = ($`,$'); #');
    } else {
	($loghost, $logdir) = (undef, $cfgvalue);
    }
    return 1;
}

sub onloghost ($) {
    my ($shellcmd) = @_;
    # returns list to run that command
    if (defined $loghost) {
	return qw(ssh -n), @logsshopts, $loghost, $shellcmd;
    } else {
	return qw(sh -ec), $shellcmd;
    }
}

sub logcfg ($) {
    my ($k) = @_;
    return $c{"${logcfgbase}${k}"} // $c{"Logs${k}"};
}

1;
