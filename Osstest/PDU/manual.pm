
package Osstest::PDU::manual;

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

our $tty;

sub new {
    my ($class, $ho) = @_;
    return bless { Host => $ho }, $class;
}

sub power_state {
    my ($mo, $on) = @_;
    my $onoff= $on ? "on" : "off";

    if (!$tty) {
	$tty = new IO::File "/dev/tty", "+<"
	    or die "unable to open /dev/tty for manual power cycling";
    }
    for (;;) {
	print $tty "### Manual power switch request:".
	    " turn host $mo->{Host}{Name} $onoff ###";
	flush $tty;
	$_ = <$tty>;
	chomp or die;
	last if !length;
    }
}

1;
