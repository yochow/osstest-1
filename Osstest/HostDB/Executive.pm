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


package Osstest::HostDB::Executive;

use strict;
use warnings;

use Osstest;
use Osstest::Executive;
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

sub new { return bless {}, $_[0]; }

sub get_properties ($$$) {
    my ($hd, $name, $hp) = @_;
    
    my $q = $dbh_tests->prepare(<<END);
        SELECT * FROM resource_properties
            WHERE restype='host' AND resname=?
END
    $q->execute($name);
    while (my $row = $q->fetchrow_hashref()) {
	my $name = $row->{name};
	$hp->{propname_massage($name)} = $row->{val};
    }
}

sub get_flags ($$) {
    my ($hd, $ho) = @_;

    my $flags = { };
    my $flagsq= $dbh_tests->prepare(<<END);
        SELECT hostflag FROM hostflags WHERE hostname=?
END
    $flagsq->execute($ho->{Name});

    while (my ($flag) = $flagsq->fetchrow_array()) {
        $flags->{$flag}= 1;
    }
    $flagsq->finish();
    return $flags;
}

sub get_arch_platforms ($$) {
    my ($hd, $blessing, $arch) = @_;

    my @plats = ( );
    my $platsq = $dbh_tests->prepare(<<END);
SELECT DISTINCT hostflag
           FROM hostflags h0
   WHERE EXISTS (
       SELECT *
         FROM hostflags h1, hostflags h2
        WHERE h0.hostname = h1.hostname AND h1.hostname = h2.hostname
          AND h1.hostflag = ?
          AND h2.hostflag = ?
   )
   AND hostflag like 'platform-%';
END

    $platsq->execute("blessed-$blessing", "arch-$arch");

    while (my ($plat) = $platsq->fetchrow_array()) {
	$plat =~ s/^platform-//g or die;
	push @plats, $plat;
    }

    $platsq->finish();
    return @plats;
}

sub default_methods ($$) {
    my ($hd, $ho) = @_;

    return if $ho->{Flags}{'no-reinstall'};
    return if $ho->{Ether} && $ho->{Power};

    return if $c{HostDB_Executive_NoConfigDB};

    my $dbh_config= opendb('configdb');
    my $selname= $ho->{Fqdn};
    my $sth= $dbh_config->prepare(<<END);
            SELECT * FROM ips WHERE reverse_dns = ?
END
    $sth->execute($selname);
    my $row= $sth->fetchrow_hashref();
    my $name= $ho->{Name};
    die "$ho->{Ident} $name $selname ?" unless $row;
    die if $sth->fetchrow_hashref();
    $sth->finish();
    my $get= sub {
	my ($k,$nowarn) = @_;
	my $v= $row->{$k};
	defined $v or $nowarn or
	    warn "host $name: undefined $k in configdb::ips\n";
	return $v;
    };
    $ho->{Asset}= $get->('asset',1);
    $ho->{Ether} ||= $get->('hardware');
    $ho->{Power} ||= "statedb $ho->{Asset}";
    push @{ $ho->{Info} }, "(asset=$ho->{Asset})" if defined $ho->{Asset};
    $dbh_config->disconnect();
}

1;
