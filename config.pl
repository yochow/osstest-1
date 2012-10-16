


$c{SerialLogPattern}= '/root/sympathy/%host%.log*';

$c{Tftp}= '/tftpboot/pxe';

$c{TftpPxeGroup}= 'osstest';

#$c{Baud}= 38400;
$c{Baud}= 115200;
$c{PxeDiBase}= 'osstest/debian-installer';

$c{PxeDiVersion}= '2012-01-30-squeeze';

$c{HostDiskBoot}=   '300'; #Mby
$c{HostDiskRoot}= '10000'; #Mby
$c{HostDiskSwap}=  '2000'; #Mby

$c{BisectionRevisonGraphSize}= '600x300';

# We use the IP address because Citrix can't manage reliable nameservice
#$c{DebianMirrorHost}= 'debian.uk.xensource.com';
$c{DebianMirrorHost}= '10.80.16.196';
$c{DebianMirrorSubpath}= 'debian';

$c{TestingLib}= '.';

1;
