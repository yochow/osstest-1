
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
    $process->("HostFlags_$ho->{Name}");

    return $flags;
}

sub default_methods ($$) { #method
    my ($hd, $ho) = @_;

    die "need ethernet address for $ho->{Name}" unless $ho->{Ether};
    $ho->{Power} ||= "manual $ho->{Name}";
}

1;
