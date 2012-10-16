
package Osstest::PDU::msw;

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

sub new {
    my ($class, $ho, $methname,$pdu,$port) = @_;
    return bless { Pdu => $pdu, Port => $port }, $class;
}

sub power_state {
    my ($mo, $on) = @_;
    my $onoff= $on ? "on" : "off";
    system_checked("./pdu-msw $mo->{Pdu} $mo->{Port} $onoff");
}

1;
