#---------- logtailer ----------

use strict;
use warnings;

package Osstest::Logtailer;

use Fcntl qw(:seek);
use POSIX;

BEGIN {
    use Exporter ();
    our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
    $VERSION     = 1.00;
    @ISA         = qw(Exporter);
    @EXPORT      = qw();
    %EXPORT_TAGS = (
	);

    @EXPORT_OK   = qw();
}

sub new ($$) {
    my ($class, $fn) = @_;
    my $fh= new IO::File $fn,'r';
    my $ino= -1;
    if (!$fh) {
        $!==&ENOENT or die "$fn $!";
    } else {
        seek $fh, 0, SEEK_END or die "$fn $!";
        stat $fh or die "$fn $!";
        $ino= (stat _)[1];
    }
    my $lt= { Path => $fn, Handle => $fh, Ino => $ino, Buf => '' };
    bless $lt, $class;
    return $lt;
}

sub getline ($) {
    my ($lt) = @_;

    for (;;) {
        if ($lt->{Buf} =~ s/^(.*)\n//) {
            return $1;
        }

        if ($lt->{Handle}) {
            seek $lt->{Handle}, 0, SEEK_CUR or die "$lt->{Path} $!";

            my $more;
            my $got= read $lt->{Handle}, $more, 4096;
            die "$lt->{Path} $!" unless defined $got;
            if ($got) {
                $lt->{Buf} .= $more;
                next;
            }
        }

        if (!stat $lt->{Path}) {
            $!==&ENOENT or die "$lt->{Path} $!";
            return undef;
        }
        my $nino= (stat _)[1];
        return undef
            unless $nino != $lt->{Ino};

        my $nfh= new IO::File $lt->{Path},'r';
        if (!$nfh) {
            $!==&ENOENT or die "$lt->{Path} $!";
            warn "newly-created $lt->{Path} vanished again";
            return undef;
        }
        stat $nfh or die $!;
        $nino= (stat _)[1];

        $lt->_close();
        $lt->{Handle}= $nfh;
        $lt->{Ino}= $nino;
    }
}

sub _close ($) {
    my ($lt) = @_;
    if ($lt->{Handle}) {
        close $lt->{Handle} or die "$lt->{Path} $!";
        $lt->{Handle}= undef;
        $lt->{Ino}= -1;
    }
}

sub close ($) {
    my ($lt) = @_;
    $lt->_close();
    $lt->{Buf}= '';
}

sub DESTROY ($) {
    my ($lt) = @_;
    local $!;
    $lt->_close();
}

1;
