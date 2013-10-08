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

# Fetch logs from a web directory export.

package Osstest::Serial::http;

use strict;
use warnings;

use Osstest;
use Osstest::TestSupport;

use File::Temp;
use File::Copy;

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
    my ($class, $ho, $methname, @args) = @_;
    my $mo = { Host => $ho, Name => $ho->{Name} };
    die if @args<1;
    push @args, "$ho->{Name}.txt*" if @args < 2;

    logm("serial method $methname $mo->{Host}{Name}: @args");
    ($mo->{Server}, $mo->{Pattern}) = @args;
    return bless $mo, $class;
}

sub request_debug {
    return 0;
}

sub fetch_logs {
    my ($mo) = @_;

    my $started= $mjobdb->jobdb_flight_started_for_log_capture($flight);

    my $ho = $mo->{Host};
    my $logpat = $mo->{Pattern};
    my $targhost= $mo->{Server};

    logm("serial http from $mo->{Name} fetching $mo->{Pattern} from $mo->{Server}");

    my $dir = File::Temp->newdir();
    my $tdir = $dir->dirname;

    my $lrf = "$tdir/log-retrieval.log";

    system_checked(qw(wget -nH --cut-dirs=1 -r -l1 --no-parent),
                   '-o', "$lrf",
                   '-A', $mo->{Pattern},
                   '-P', $tdir,
                   $mo->{Server});

    my $sr = "serial-retrieval.log";
    my $lr = open_unique_stashfile(\$sr);
    File::Copy::copy($lrf, $lr);

    my %done;
    foreach my $logfile (glob "$tdir/$mo->{Pattern}") {
	my $lh= new IO::File $logfile, 'r';
	if (!defined $lh) {
	    $!==&ENOENT or warn "$logfile $!";
	    next;
	}
	stat $lh or die "$logfile $!";
	my $inum= (stat _)[1];
	my $lfage= (stat _)[9];
        my $df= $logfile;
        $df =~ s,.*/,,;
	if ($lfage < $started) {
	    next if $done{$inum};
	    logm("$df modified $lfage, skipping")
		unless $done{$inum};
	    $done{$inum}= 1;
	    next;
	}
	next if defined $done{$inum} and $done{$inum} >= 2;
	$done{$inum}= 2;

        $df = "serial-$df";
        logm("stashing $df");

        my $dh= open_unique_stashfile(\$df);
        File::Copy::copy($logfile, $dh);
    }
    return;

}

1;
