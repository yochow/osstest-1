
package Osstest::HostDB::Executive;

use strict;
use warnings;

use Osstest;
use Osstest::Executive;

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
    foreach my ($row = $q->fetchrow_hashref()) {
	my $name = $row->{name};
	$hp{propname_massage($name)} = $row->{val};
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

sub default_methods ($$) {
    my ($hd, $ho) = @_;

    return if $ho->{Ether} && $ho->{Power};

    my $dbh_config= opendb('configdb');
    my $selname= $ho->{Fqdn};
    my $sth= $dbh_config->prepare(<<END);
            SELECT * FROM ips WHERE reverse_dns = ?
END
    $sth->execute($selname);
    my $row= $sth->fetchrow_hashref();
    die "$ident $name $selname ?" unless $row;
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
