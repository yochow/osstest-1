# This is part of "osstest", an automated testing framework for Xen.
# Copyright (C) 2015 Intel Inc.
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

# Send debug keys to nested host (L1).

package Osstest::Serial::guest;

use strict;
use warnings;

use Osstest;
use Osstest::TestSupport;
use Osstest::Serial::keys_real;

BEGIN {
    use Exporter ();
    our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
    $VERSION     = 1.00;
    @ISA         = qw(Exporter Osstest::Serial::keys_real);
    @EXPORT      = qw();
    %EXPORT_TAGS = ( );

    @EXPORT_OK   = qw();
}

sub new {
    my ($class, $l1ho, $methname, @args) = @_;
    my $mo = { Target => $l1ho, Parent => $l1ho->{Host} };

    logm("serial method $methname $mo->{Target}{Name}: @args");
    return bless $mo, $class;
}

sub keys_prepare {
    my ($mo) = @_;

    my $gho = $mo->{Target};
    my $pho = $mo->{Parent};
    my $puho = sshuho('root',$pho);
    my $domname = $r{"$gho->{Guest}_domname"};

    my $fifo = "/root/$flight.$job.$domname.serial.in";

    # NB this by-hand construction and execution of an
    # ssh command line bypasses the usual timeout arrangements.
    my ($sshopts) = sshopts();
    my $cmd = "ssh @$sshopts $puho 'cat >$fifo'";
    logm("spawning $cmd");

    # timeouts: open will carry on regardless even if the command hangs
    open SERIALWRITE, "|$cmd" or die $!;
    autoflush SERIALWRITE 1;
}

sub keys_write {
    my ($mo, $what,$str,$pause) = @_;
    logm("xenuse sending $what");

    # timeouts: we are going to write much less than any plausible
    # PIPE_MAX so there is no risk that we will block on write
    print SERIALWRITE $str or die $!;
    sleep($pause);
}

sub keys_shutdown {
    my ($mo) = @_;

    # timeouts: close waits for the child to exit, so set an alarm
    alarm(15);
    $!=0; $?=0; close SERIALWRITE or die "$? $!";
    alarm(0);
}

sub fetch_logs {
    my ($mo) = @_;

    logm("$mo->{Target}{Name} (nested host) serial console logs".
	 " will be found in guest logs from $mo->{Parent}{Name} (parent)");
    return;
}

1;
