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

# Send debug keys via xenuse.

package Osstest::Serial::xenuse;

use strict;
use warnings;

use Osstest;
use Osstest::TestSupport;
use Osstest::Serial::keys_real;

use File::Temp;
use File::Copy;

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
    my ($class, $ho, $methname, @args) = @_;
    my $mo = { Host => $ho, Name => $ho->{Name} };

    logm("serial method $methname $mo->{Host}{Name}: @args");
    return bless $mo, $class;
}

sub keys_prepare {
    my ($mo) = @_;

    my $ho= $mo->{Host};

    my $xenuse= $c{XenUsePath} || "xenuse";

    open XENUSEWRITE, "|$xenuse -t $ho->{Name}" or die $!;
    autoflush XENUSEWRITE 1;

    $mo->keys_write('force attach', "\x05cf", 1); # ^E c f == force attach

    sleep 5;
}

sub keys_write {
    my ($mo, $what,$str,$pause) = @_;
    logm("xenuse sending $what");

    print XENUSEWRITE $str or die $!;
    sleep($pause);
}

sub keys_shutdown {
    my ($mo) = @_;

    $mo->keys_write('dettach', "\x05c.", 1); # ^E c . == disconnect

    close XENUSEWRITE or die "$? $!";
}

sub fetch_logs {
    return;
}

1;
