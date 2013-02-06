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


package Osstest::JobDB::Standalone;

use strict;
use warnings;

use Osstest;
use Osstest::TestSupport;

BEGIN {
    use Exporter ();
    our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
    $VERSION     = 1.00;
    @ISA         = qw(Exporter);
    @EXPORT      = qw();
    %EXPORT_TAGS = ( );

    @EXPORT_OK   = qw();
}

augmentconfigdefaults(
    JobDBStandaloneFilename => 'standalone.db',
);

sub new { return bless {}, $_[0]; };

sub begin_work { }
sub dbfl_check { }

sub open ($) {
    my $dbi = "dbi:SQLite:dbname=$c{JobDBStandaloneFilename}";
    
    my $dbh= DBI->connect($dbi, '','', {
        AutoCommit => 1,
        RaiseError => 1,
        ShowErrorStatement => 1,
        })
        or die "could not open standalone db $dbi";
    return $dbh;
}

sub flight_create ($$$) {
    my ($obj, $branch, $intended) = @_;
    my $fl = $ENV{'OSSTEST_FLIGHT'};
    $fl = 'standalone' unless defined $fl && length $fl;
    die "flight names may not contain ." if $fl =~ m/\./;
    foreach my $table (qw(runvars jobs flights)) {
	$dbh_tests->do(<<END, {}, $fl)
	     DELETE FROM $table WHERE flight = ?
END
    }
    $dbh_tests->do(<<END, {}, $fl, $branch, $intended);
             INSERT INTO flights
                         (flight, branch, intended)
                  VALUES (?, ?, ?)
END
    return $fl
}

sub current_flight ($) {
    return $ENV{'OSSTEST_FLIGHT'} || 'standalone';
}

sub job_ensure_started ($) { }

sub host_check_allocated ($$) { #method
    my ($jd, $ho) = @_;

    if ($ENV{'OSSTEST_HOST_REUSE'}) {
	logm("OSSTEST_HOST_REUSE");
	$ho->{SharedReady}= 1;
    }
}

sub jobdb_postfork ($) { }

sub gen_ether_offset ($$) { #method
    my ($mo,$ho,$fl) = @_;
    return $< & 0xffff;
}

sub jobdb_resource_shared_mark_ready { } #method

sub jobdb_check_other_job { } #method

sub jobdb_flight_started_for_log_capture ($$) { #method
    my ($mo, $flight) = @_;
    return time - 1; # just the most recent serial log then
}

sub jobdb_enable_log_capture ($) { #method
    return $c{CaptureLogs} || 0;
}

sub jobdb_db_glob ($) { #method
    my ($mo,$str) = @_;
    return "GLOB '$str'";
}

1;
