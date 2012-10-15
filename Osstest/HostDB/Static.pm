
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

sub get_properties ($$) { #method
    my ($hd, $name) = @_;
    my $hp = { };
    my $k;
    foreach $k (keys %c) {
	next unless $k =~ m/^HostProp_([A-Z].*)$/;
	$hp->{$1} = $c{$k};
    }
    foreach $k (keys %c) {
	next unless $k =~ m/^HostProp_([a-z0-9]+)_(.*)$/;
	next unless $1 eq $name;
	$hp->{$2} = $c{$k};
    }
    return $hp;
}

sub get_property ($$$;$) { #method
    my ($hd, $ho, $prop, $defval) = @_;

    $prop = ucfirst $prop;
    while ($prop =~ m/-/) {
	$prop = $`.ucfirst $'; #';
    }

    my $val = $ho->{Properties}{$prop};
    return $defval unless defined $val;
    return $val;
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
    $process->("HostFlags_$ho->{Name}");

    return $flags;
}

sub default_methods ($$) { #method
    my ($hd, $ho) = @_;

    die "need ethernet address for $ho->{Name}" unless $ho->{Ether};
    $ho->{Power} ||= "manual $ho->{Name}";
}

1;
