$c{Domain}= 'uk.xensource.com';
$c{TestHostDomain}= 'cam.xci-test.com';

$c{WebspaceFile}= '/export/home/osstest/public_html/';
$c{WebspaceUrl}= "http://woking.$c{Domain}/~osstest/";
$c{WebspaceCommon}= 'osstest/';
$c{WebspaceLog}= '/var/log/apache2/access.log';

$c{BuildStash}= '/export/home/xc_osstest/builds';

$c{Tftp}= '/tftpboot/pxe';

#$c{Baud}= 38400;
$c{Baud}= 115200;
$c{PxeDiBase}= 'debian-installer';

$c{Suite}= 'lenny';

$c{Preseed}= <<END;
d-i mirror/http/hostname string debian.uk.xensource.com
d-i mirror/http/directory string /debian
d-i clock-setup/ntp-server string ntp.uk.xensource.com
END

$c{AuthorizedKeysFiles}= '';
$c{AuthorizedKeysAppend}= <<'END';
ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEA2m8+FRm8zaCy4+L2ZLsINt3OiRzDu82JE67b4Xyt3O0+IEyflPgw5zgGH69ypOn2GqYTaiBoiYNoAn9bpUksMk71q+co4gsZJ17Acm0256A3NP46ByT6z6/AKTl58vwwNKSCEAzNru53sXTYw2TcCZUN8A4vXY76OeJNJmCmgBDHCNod9fW6+EOn8ZSU1YjFUBV2UmS2ekKmsGNP5ecLAF1bZ8I13KpKUIDIY+UiG0UMwTWDfQY59SNsz6bCxv9NsxSXL29RS2XHFeIQis7t6hJuyZTT4b9YzjEAxvk8kdGzzK6314kwILibm1O1Y8LLyrYsWK1AvnJQFIhcYXF0EQ== iwj@mariner
END

$r{Host}= 'spider';
$r{Arch}= 'i386';
$r{Job}= '100';
$r{Task}= 'x';

$r{Tree_Xen}= 'http://hg.uk.xensource.com/xen-unstable.hg';
$r{Revision_Xen}= 'tip';

$r{Tree_Qemu}= 'git://mariner.uk.xensource.com/qemu-xen-unstable.git';
$r{Revision_Qemu}= 'HEAD';

#$r{Tree_Linux}= 'git://git.kernel.org/pub/scm/linux/kernel/git/x86/linux-2.6-tip.git';
#$r{Revision_Linux}= 'HEAD';

1;
