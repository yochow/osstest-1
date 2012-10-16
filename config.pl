# things which may need sorting at the use site

$c{GenEtherPrefix}= '5a:36:0e';


$c{Repos}= "$ENV{HOME}/repos";

$c{GitCache}='teravault-1.cam.xci-test.com:/export/home/xc_osstest/git-cache/';
$c{GitCacheLocal}= '/home/xc_osstest/git-cache/';

$c{PubBaseUrl}= 'http://www.chiark.greenend.org.uk/~xensrcts';
$c{ReportHtmlPubBaseUrl}= "$c{PubBaseUrl}/logs";
$c{ResultsHtmlPubBaseUrl}= "$c{PubBaseUrl}/results";
    
$c{ReportTrailer}= <<END;
Logs, config files, etc. are available at
    $c{ReportHtmlPubBaseUrl}

Test harness code can be found at
    http://xenbits.xensource.com/gitweb?p=osstest.git;a=summary
END

$c{PlanRogueAllocationDuration}= 86400*7;

$c{SerialLogPattern}= '/root/sympathy/%host%.log*';

$c{Publish}= 'xensrcts@login.chiark.greenend.org.uk:/home/ian/work/xc_osstest';

$c{GlobalLockDir}= "/export/home/osstest/testing.git";

$c{LogsPublish}= "$c{Publish}/logs";
$c{ResultsPublish}= "$c{Publish}/results";

$c{HarnessPublishGitUserHost}= 'xen@xenbits.xensource.com';
$c{HarnessPublishGitRepoDir}= 'git/osstest.git';

$c{Tftp}= '/tftpboot/pxe';

$c{TftpPxeGroup}= 'osstest';

#$c{Baud}= 38400;
$c{Baud}= 115200;
$c{PxeDiBase}= 'osstest/debian-installer';

$c{Suite}= 'squeeze';
$c{PxeDiVersion}= '2012-01-30-squeeze';

$c{GuestSuite}= 'squeeze';
$c{HostDiskBoot}=   '300'; #Mby
$c{HostDiskRoot}= '10000'; #Mby
$c{HostDiskSwap}=  '2000'; #Mby

$c{BisectionRevisonGraphSize}= '600x300';

# We use the IP address because Citrix can't manage reliable nameservice
#$c{DebianMirrorHost}= 'debian.uk.xensource.com';
$c{DebianMirrorHost}= '10.80.16.196';
$c{DebianMirrorSubpath}= 'debian';

$c{TestingLib}= '.';

$c{Preseed}= <<END;
d-i clock-setup/ntp-server string ntp.uk.xensource.com
END

1;
