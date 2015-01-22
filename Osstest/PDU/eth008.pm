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

package Osstest::PDU::eth008;

use strict;
use warnings;

use Osstest;
use Osstest::TestSupport;
use LWP::UserAgent;

BEGIN {
    use Exporter ();
    our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
    $VERSION     = 1.00;
    @ISA         = qw(Exporter);
    @EXPORT      = qw();
    %EXPORT_TAGS = ( );

    @EXPORT_OK   = qw();
}

sub new {
    my ($class, $ho, $methname, $pdu, $user, $pass, $port, @opts) = @_;
    return bless { Host => $ho,
		   PDU => $pdu,
		   User => $user,
		   Pass => $pass,
		   Port => $port,
		   Opts => \@opts }, $class;
}

sub pdu_power_state {
    my ($mo, $on) = @_;
    my $op= $on ? "DOA" : "DOI"; # Digital Output (In)Active

    # Use the CGI interface since it is less prone to being firewalled
    # off, unlike the standard interface on port 17494. This is only
    # available from firmware v4 onwards.

    my $ua = LWP::UserAgent->new;

    $ua->credentials("$mo->{PDU}:80", "Protected", $mo->{User}, $mo->{Pass});

    my $resp = $ua->get("http://$mo->{PDU}/io.cgi?$op$mo->{Port}=0");

    die "failed" unless $resp->is_success;
    logm($resp->decoded_content);
}

1;
