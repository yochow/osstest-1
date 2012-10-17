
package Osstest::Serial::noop;

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

sub new {
    my ($class, $ho) = @_;
    return bless { }, $class;
}

sub fetch_logs {
    my ($mo) = @_;
    logm("serial access method \`noop',".
	 " not requesting debug keys or capturing serial logs");
}

1;
