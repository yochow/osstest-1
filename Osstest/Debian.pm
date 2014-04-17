# This is part of "osstest", an automated testing framework for Xen.
# Copyright (C) 2009-2013 Citrix Inc.
# 
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
# 
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.


package Osstest::Debian;

use strict;
use warnings;

use IO::File;
use File::Copy;

use Osstest;
use Osstest::TestSupport;

BEGIN {
    use Exporter ();
    our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
    $VERSION     = 1.00;
    @ISA         = qw(Exporter);
    @EXPORT      = qw(debian_boot_setup
                      %preseed_cmds
                      preseed_base
                      preseed_create
                      preseed_hook_command preseed_hook_installscript
                      di_installcmdline_core
                      );
    %EXPORT_TAGS = ( );

    @EXPORT_OK   = qw();
}

#---------- manipulation of Debian bootloader setup ----------

sub debian_boot_setup ($$$$;$) {
    # $xenhopt==undef => is actually a guest, do not set up a hypervisor
    my ($ho, $want_kernver, $xenhopt, $distpath, $hooks) = @_;

    target_kernkind_check($ho);
    target_kernkind_console_inittab($ho,$ho,"/");

    my $kopt;
    my $console= target_var($ho,'console');
    if (defined $console && length $console) {
        $kopt= "console=$console";
    } else {
        $kopt= "xencons=ttyS console=ttyS0,$c{Baud}n8";
    }

    my $targkopt= target_var($ho,'linux_boot_append');
    if (defined $targkopt) {
        $kopt .= ' '.$targkopt;
    }

    foreach my $hook ($hooks ? @$hooks : ()) {
        my $bo_hook= $hook->{EditBootOptions};
        $bo_hook->($ho, \$xenhopt, \$kopt) if $bo_hook;
    }

    my $bootloader;
    if ( $ho->{Flags}{'need-uboot-bootscr'} ) {
	$bootloader= setupboot_uboot($ho, $want_kernver, $xenhopt, $kopt);
    } elsif ($ho->{Suite} =~ m/lenny/) {
        $bootloader= setupboot_grub1($ho, $want_kernver, $xenhopt, $kopt);
    } else {
        $bootloader= setupboot_grub2($ho, $want_kernver, $xenhopt, $kopt);
    }

    $bootloader->{UpdateConfig}($ho);

    my $kern= $bootloader->{GetBootKern}();
    logm("dom0 kernel is $kern");

    system "tar zvtf $distpath->{kern} boot/$kern";
    $? and die "$distpath->{kern} boot/$kern $?";

    my $kernver= $kern;
    $kernver =~ s,^/?(?:boot/)?(?:vmlinu[xz]-)?,, or die "$kernver ?";
    my $kernpath= $kern;
    $kernpath =~ s,^(?:boot/)?,/boot/,;

    target_cmd_root($ho,
                    "update-initramfs -k $kernver -c ||".
                    " update-initramfs -k $kernver -u",
                    200);

    $bootloader->{PreFinalUpdate}();

    $bootloader->{UpdateConfig}($ho);

    store_runvar(target_var_prefix($ho).'xen_kernel_path',$kernpath);
    store_runvar(target_var_prefix($ho).'xen_kernel_ver',$kernver);
}

sub bl_getmenu_open ($$$) {
    my ($ho, $rmenu, $lmenu) = @_;
    target_getfile($ho, 60, $rmenu, $lmenu);
    my $f= new IO::File $lmenu, 'r' or die "$lmenu $?";
    return $f;
}

sub setupboot_uboot ($$$) {
    my ($ho,$want_kernver,$xenhopt,$xenkopt) = @_;
    my $bl= { };

    $bl->{UpdateConfig}= sub {
	my ( $ho ) = @_;

	my $xen = "xen";
	my $kern = "vmlinuz-$want_kernver";
	my $initrd = "initrd.img-$want_kernver";

	my $root= target_guest_lv_name($ho,"root");

	logm("Xen options: $xenhopt");
	logm("Linux options: $xenkopt");

	my $early_commands = get_host_property($ho, 'UBootScriptEarlyCommands', '');

	target_cmd_root($ho, <<END);
if test ! -f /boot/$kern ; then
    exit 1
fi
# Save a copy of the original
cp -n /boot/boot /boot/boot.bak
cp -n /boot/boot.scr /boot/boot.scr.bak

xen=`readlink /boot/$xen`

cat >/boot/boot <<EOF

mw.l 800000 0 10000
scsi scan

fdt addr \\\${fdt_addr}
fdt resize

${early_commands}

fdt set /chosen \\\#address-cells <1>
fdt set /chosen \\\#size-cells <1>

setenv xen_addr_r 0x01000000
#   kernel_addr_r=0x02000000
#  ramdisk_addr_r=0x04000000

ext2load scsi 0 \\\${xen_addr_r} \$xen
setenv bootargs "$xenhopt"
echo Loaded \$xen to \\\${xen_addr_r} (\\\${filesize})
echo command line: \\\${bootargs}

ext2load scsi 0 \\\${kernel_addr_r} $kern
fdt mknod /chosen module\@0
fdt set /chosen/module\@0 compatible "xen,linux-zimage" "xen,multiboot-module"
fdt set /chosen/module\@0 reg <\\\${kernel_addr_r} \\\${filesize}>
fdt set /chosen/module\@0 bootargs "$xenkopt ro root=$root"
echo Loaded $kern to \\\${kernel_addr_r} (\\\${filesize})
echo command line: $xenkopt ro root=$root

ext2load scsi 0 \\\${ramdisk_addr_r} $initrd
fdt mknod /chosen module\@1
fdt set /chosen/module\@1 compatible "xen,linux-initrd" "xen,multiboot-module"
fdt set /chosen/module\@1 reg <\\\${ramdisk_addr_r} \\\${filesize}>
echo Loaded $initrd to \\\${ramdisk_addr_r} (\\\${filesize})

fdt print /chosen

echo Booting \\\${xen_addr_r} - \\\${fdt_addr}
bootz \\\${xen_addr_r} - \\\${fdt_addr}
EOF
mkimage -A arm -T script -d /boot/boot /boot/boot.scr
END
    };

    $bl->{GetBootKern}= sub {
	return "vmlinuz-$want_kernver";
    };

    $bl->{PreFinalUpdate}= sub { };

    return $bl;
}

sub setupboot_grub1 ($$$) {
    my ($ho,$want_kernver,$xenhopt,$xenkopt) = @_;
    my $bl= { };

    my $rmenu= "/boot/grub/menu.lst";
    my $lmenu= "$stash/$ho->{Name}--menu.lst.out";

    target_editfile_root($ho, $rmenu, sub {
        while (<::EI>) {
            if (m/^## ## Start Default/ ..
                m/^## ## End Default/) {
                s/^# xenhopt=.*/# xenhopt= $xenhopt/ if defined $xenhopt;
                s/^# xenkopt=.*/# xenkopt= $xenkopt/;
            }
            print ::EO or die $!;
        }
    });

    $bl->{UpdateConfig}= sub {
	my ( $ho ) = @_;
	target_cmd_root($ho, "update-grub");
    };

    $bl->{GetBootKern}= sub {
        my $f= bl_getmenu_open($ho, $rmenu, $lmenu);

        my $def;
        while (<$f>) {
            last if m/^\s*title\b/;
            next unless m/^\s*default\b/;
            die "$_ ?" unless m/^\s*default\s+(\d+)\s*$/;
            $def= $1;
            last;
        }
        my $ix= -1;
        die unless defined $def;
        logm("boot check: grub default is option $def");

        my $kern;
        while (<$f>) {
            s/^\s*//; s/\s+$//;
            if (m/^title\b/) {
                $ix++;
                if ($ix==$def) {
                    logm("boot check: title $'");
                }
                next;
            }
            next unless $ix==$def;
            if (m/^kernel\b/) {
                die "$_ ?" unless
  m,^kernel\s+/(?:boot/)?((?:xen|vmlinuz)\-[-+.0-9a-z]+\.gz)(?:\s.*)?$,;
		my $actualkernel= $1;
                logm("boot check: actual kernel: $actualkernel");
		if (defined $xenhopt) {
		    die unless $actualkernel =~ m/^xen/;
		} else {
		    die unless $actualkernel =~ m/^vmlinu/;
		    $kern= $1;
		}
            }
            if (m/^module\b/ && defined $xenhopt) {
                die "$_ ?" unless m,^module\s+/((?:boot/)?\S+)(?:\s.*)?$,;
		die "unimplemented kernel version check for grub1"
		    if defined $want_kernver;
                $kern= $1;
                logm("boot check: kernel: $kern");
                last;
            }
        }
        die "$def $ix" unless defined $kern;
        return $kern;
    };


    $bl->{PreFinalUpdate}= sub { };

    return $bl;
}

sub setupboot_grub2 ($$$) {
    my ($ho,$want_kernver,$xenhopt,$xenkopt) = @_;
    my $bl= { };

    my $rmenu= '/boot/grub/grub.cfg';
    my $kernkey= (defined $xenhopt ? 'KernDom0' : 'KernOnly');
 
    my $parsemenu= sub {
        my $f= bl_getmenu_open($ho, $rmenu, "$stash/$ho->{Name}--grub.cfg.1");
    
        my $count= 0;
        my $entry;
        while (<$f>) {
            next if m/^\s*\#/ || !m/\S/;
            if (m/^\s*\}\s*$/) {
                die unless $entry;
                my (@missing) =
                    grep { !defined $entry->{$_} } 
		        (defined $xenhopt
			 ? qw(Title Hv KernDom0 KernVer)
			 : qw(Title Hv KernOnly KernVer));
		if (@missing) {
		    logm("(skipping entry at $entry->{StartLine};".
			 " no @missing)");
		} elsif (defined $want_kernver &&
			 $entry->{KernVer} ne $want_kernver) {
		    logm("(skipping entry at $entry->{StartLine};".
			 " kernel $entry->{KernVer}, not $want_kernver)");
		} else {
		    # yes!
		    last;
		}
                $entry= undef;
                next;
            }
            if (m/^function.*\{/) {
                $entry= { StartLine => $. };
            }
            if (m/^menuentry\s+[\'\"](.*)[\'\"].*\{\s*$/) {
                die $entry->{StartLine} if $entry;
                $entry= { Title => $1, StartLine => $., Number => $count };
                $count++;
            }
            if (m/^\s*multiboot\s*\/(xen\-[0-9][-+.0-9a-z]*\S+)/) {
                die unless $entry;
                $entry->{Hv}= $1;
            }
            if (m/^\s*multiboot\s*\/(vmlinu[xz]-(\S+))/) {
                die unless $entry;
                $entry->{KernOnly}= $1;
                $entry->{KernVer}= $2;
            }
            if (m/^\s*module\s*\/(vmlinu[xz]-(\S+))/) {
                die unless $entry;
                $entry->{KernDom0}= $1;
                $entry->{KernVer}= $2;
            }
            if (m/^\s*module\s*\/(initrd\S+)/) {
                $entry->{Initrd}= $1;
            }
        }
        die 'grub 2 bootloader entry not found' unless $entry;

        die unless $entry->{Title};

        logm("boot check: grub2, found $entry->{Title}");

	die unless $entry->{$kernkey};
	if (defined $xenhopt) {
	    die unless $entry->{Hv};
	}

        return $entry;
    };


    $bl->{UpdateConfig}= sub {
	my ( $ho ) = @_;
	target_cmd_root($ho, "update-grub");
    };

    $bl->{GetBootKern}= sub { return $parsemenu->()->{$kernkey}; };

    $bl->{PreFinalUpdate}= sub {
        my $entry= $parsemenu->();
        
        target_editfile_root($ho, '/etc/default/grub', sub {
            my %k;
            while (<::EI>) {
                if (m/^\s*([A-Z_]+)\s*\=\s*(.*?)\s*$/) {
                    my ($k,$v) = ($1,$2);
                    $v =~ s/^\s*([\'\"])(.*)\1\s*$/$2/;
                    $k{$k}= $v;
                }
                next if m/^GRUB_CMDLINE_(?:XEN|LINUX).*\=|^GRUB_DEFAULT.*\=/;
                print ::EO;
            }
            print ::EO <<END or die $!;

GRUB_DEFAULT=$entry->{Number}
END

            print ::EO <<END or die $! if defined $xenhopt;
GRUB_CMDLINE_XEN="$xenhopt"

END
            foreach my $k (qw(GRUB_CMDLINE_LINUX GRUB_CMDLINE_LINUX_DEFAULT)) {
                my $v= $k{$k};
                $v =~ s/\bquiet\b//;
                $v =~ s/\b(?:console|xencons)=[0-9A-Za-z,]+//;
                $v .= " $xenkopt" if $k eq 'GRUB_CMDLINE_LINUX';
                print ::EO "$k=\"$v\"\n" or die $!;
            }
        });
    };

    return $bl;
}

#---------- installation of Debian via debian-installer ----------

our %preseed_cmds;
# $preseed_cmds{$di_key}[]= $cmd

sub di_installcmdline_core ($$;@) {
    my ($tho, $ps_url, %xopts) = @_;

    $ps_url =~ s,^http://,,;

    my $netcfg_interface= get_host_property($tho,'interface force','auto');

    my @cl= qw(
               auto=true preseed
               hw-detect/load_firmware=false
               DEBCONF_DEBUG=5
               );
    my $difront = get_host_property($tho,'DIFrontend','text');
    push @cl, (
               "DEBIAN_FRONTEND=$difront",
               "hostname=$tho->{Name}",
               "url=$ps_url",
               "netcfg/dhcp_timeout=150",
               "netcfg/choose_interface=$netcfg_interface"
               );

    my $debconf_priority= $xopts{DebconfPriority};
    push @cl, "debconf/priority=$debconf_priority"
        if defined $debconf_priority;

    return @cl;
}

sub preseed_base ($$;@) {
    my ($suite,$extra_packages,%xopts) = @_;

    return <<"END";
d-i mirror/suite string $suite

d-i debian-installer/locale string en_GB
d-i console-keymaps-at/keymap select gb
d-i keyboard-configuration/xkb-keymap string en_GB

#d-i debconf/frontend string readline

d-i mirror/country string manual
d-i mirror/http/proxy string

d-i clock-setup/utc boolean true
d-i time/zone string Europe/London
d-i clock-setup/ntp boolean true

d-i partman-md/device_remove_md boolean true
d-i partman-lvm/device_remove_lvm boolean true
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman-lvm/confirm boolean true

d-i partman/confirm_nooverwrite true
d-i partman-lvm/confirm_nooverwrite true
d-i partman-md/confirm_nooverwrite true
d-i partman-crypto/confirm_nooverwrite true

#d-i netcfg/disable_dhcp boolean true
d-i netcfg/get_nameservers string $c{NetNameservers}
d-i netcfg/confirm_static boolean true
d-i netcfg/get_domain string $c{TestHostDomain}
d-i netcfg/wireless_wep string

d-i passwd/root-password password xenroot
d-i passwd/root-password-again password xenroot
d-i passwd/user-fullname string FLOSS Xen Test
d-i passwd/username string osstest
d-i passwd/user-password password osstest
d-i passwd/user-password-again password osstest

console-common  console-data/keymap/policy      select  Don't touch keymap
console-data    console-data/keymap/policy      select  Don't touch keymap
console-data    console-data/keymap/family      select  qwerty
console-data console-data/keymap/template/layout select British

popularity-contest popularity-contest/participate boolean false
tasksel tasksel/first multiselect standard, web-server

d-i grub-installer/only_debian boolean true

d-i finish-install/keep-consoles boolean true
d-i finish-install/reboot_in_progress note
d-i cdrom-detect/eject boolean false

d-i mirror/http/hostname string $c{DebianMirrorHost}
d-i mirror/http/directory string /$c{DebianMirrorSubpath}
d-i apt-setup/use_mirror boolean yes
d-i apt-setup/another boolean false
d-i apt-setup/non-free boolean false
d-i apt-setup/contrib boolean false

d-i pkgsel/include string openssh-server, ntp, ntpdate, $extra_packages

$xopts{ExtraPreseed}

### END OF DEBIAN PRESEED BASE

END
}          

sub preseed_create ($$;@) {
    my ($ho, $sfx, %xopts) = @_;

    my $authkeys_url= create_webfile($ho, "authkeys$sfx", authorized_keys());

    my $hostkeyfile= "$c{OverlayLocal}/etc/ssh/ssh_host_rsa_key.pub";
    my $hostkey= get_filecontents($hostkeyfile);
    chomp($hostkey); $hostkey.="\n";
    my $knownhosts= '';

    my $disk= $xopts{DiskDevice} || '/dev/sda';
    my $suite= $xopts{Suite} || $c{DebianSuite};

    my $hostsq= $dbh_tests->prepare(<<END);
        SELECT val FROM runvars
         WHERE flight=? AND name LIKE '%host'
         GROUP BY val
END
    $hostsq->execute($flight);
    while (my ($node) = $hostsq->fetchrow_array()) {
        my $longname= "$node.$c{TestHostDomain}";
        my (@hostent)= gethostbyname($longname);
        if (!@hostent) {
            logm("skipping host key for nonexistent host $longname");
            next;
        }
        my $specs= join ',', $longname, $node, map {
            join '.', unpack 'W4', $_;
        } @hostent[4..$#hostent];
        logm("adding host key for $specs");
        $knownhosts.= "$specs ".$hostkey;
    }
    $hostsq->finish();

    $knownhosts.= "localhost,127.0.0.1 ".$hostkey;
    my $knownhosts_url= create_webfile($ho, "known_hosts$sfx", $knownhosts);

    my $overlays= '';
    my $create_overlay= sub {
        my ($srcdir, $tfilename) = @_;
        my $url= create_webfile($ho, "$tfilename$sfx", sub {
            my ($fh) = @_;
            contents_make_cpio($fh, 'ustar', $srcdir);
        });
        $overlays .= <<END;
wget -O overlay.tar '$url'
cd /target
tar xf \$r/overlay.tar
cd \$r
rm overlay.tar

END
    };

    $create_overlay->('overlay',        'overlay.tar');
    $create_overlay->($c{OverlayLocal}, 'overlay-local.tar');

    preseed_hook_installscript($ho, $sfx,
          '/lib/partman/init.d', '000override-parted-devices', <<END);
#!/bin/sh
set -ex
cd /bin
if test -f parted_devices.real; then exit 0; fi
mv parted_devices parted_devices.real
cat <<END2 >parted_devices
#!/bin/sh
/bin/parted_devices.real | grep -v '	0	'
END2
chmod +x parted_devices
END

    preseed_hook_installscript($ho, $sfx,
          '/lib/partman/init.d', '25erase-other-disks', <<END);
#!/bin/sh
set -ex
stamp=/var/erase-other-disks.stamp
if test -f \$stamp; then exit 0; fi
>\$stamp
zero () {
    if test -b \$dev; then
        dd if=/dev/zero of=\$dev count=64 ||:
    fi
}
for sd in sd hd; do
    for b in a b c d e f; do
        dev=/dev/\${sd}\${b}
        zero
    done
    for dev in /dev/\${sd}a[0-9]; do
        zero
    done
done
for dev in ${disk}*; do
    zero
done
echo ===
set +e
ls -l /dev/sd*
true
END

    preseed_hook_command($ho, 'late_command', $sfx, <<END);
#!/bin/sh
set -ex

r=/target/root
cd \$r

umask 022
mkdir .ssh
wget -O .ssh/authorized_keys '$authkeys_url'
wget -O .ssh/known_hosts     '$knownhosts_url'

u=osstest
h=/home/\$u
mkdir /target\$h/.ssh
cp .ssh/authorized_keys /target\$h/.ssh
chroot /target chown -R \$u.\$u \$h/.ssh

echo FANCYTTY=0 >> /target/etc/lsb-base-logging.sh

$overlays

echo latecmd done.
END

    foreach my $kp (keys %{ $ho->{Flags} }) {
	$kp =~ s/need-kernel-deb-// or next;

	my $d_i= $ho->{Tftp}{Path}.'/'.$ho->{Tftp}{DiBase}.'/'.$r{arch}.'/'.
	    $c{TftpDiVersion}.'-'.$ho->{Suite};

	my $kurl = create_webfile($ho, "kernel", sub {
	    copy("$d_i/$kp.deb", $_[0])
		or die "Copy kernel failed: $!";
        });

	my $iurl = create_webfile($ho, "initramfs-tools", sub {
	    copy("$d_i/initramfs-tools.deb", $_[0])
		or die "Copy initramfs-tools failed: $!";
        });

	preseed_hook_command($ho, 'late_command', $sfx, <<END);
#!/bin/sh
set -ex

r=/target

wget -O \$r/tmp/kern.deb $kurl
wget -O \$r/tmp/initramfs-tools.deb $iurl

# This will fail due to dependencies...
in-target dpkg -i /tmp/kern.deb /tmp/initramfs-tools.deb || true
# ... Now fix everything up...
in-target apt-get install -f -y
END
    }

    if ( $ho->{Flags}{'need-uboot-bootscr'} ) {
	my $root=target_guest_lv_name($ho,"root");

	preseed_hook_command($ho, 'late_command', $sfx, <<END);
#!/bin/sh
set -ex

r=/target #/

kernel=`readlink \$r/vmlinuz | sed -e 's|boot/||'`
initrd=`readlink \$r/initrd.img | sed -e 's|boot/||'`

cat >\$r/boot/boot <<EOF
setenv bootargs console=ttyAMA0 root=$root
mw.l 800000 0 10000
scsi scan
ext2load scsi 0 \\\${kernel_addr_r} \$kernel
ext2load scsi 0 \\\${ramdisk_addr_r} \$initrd
bootz \\\${kernel_addr_r} \\\${ramdisk_addr_r}:\\\${filesize} 0x1000
EOF

in-target mkimage -A arm -T script -d /boot/boot /boot/boot.scr
END
    }

    my @extra_packages = ();
    push(@extra_packages, "u-boot-tools") if $ho->{Flags}{'need-uboot-bootscr'};

    my $extra_packages = join(",",@extra_packages);

    my $preseed_file= preseed_base($suite,$extra_packages,%xopts);

    $preseed_file .= (<<END);
d-i partman-auto/method string lvm
#d-i partman-auto/method string regular

#d-i partman-auto/init_automatically_partition select regular
d-i partman-auto/disk string $disk

d-i partman-ext3/no_mount_point boolean false
d-i partman-basicmethods/method_only boolean false

d-i partman-auto/expert_recipe string					\\
	boot-root ::							\\
		$c{HostDiskBoot} 50 $c{HostDiskBoot} ext3		\\
			\$primary{ } \$bootable{ }			\\
			method{ format } format{ }			\\
			use_filesystem{ } filesystem{ ext3 }		\\
			mountpoint{ /boot }				\\
		.							\\
		$c{HostDiskRoot} 50 $c{HostDiskRoot} ext3		\\
			method{ format } format{ } \$lvmok{ }		\\
			use_filesystem{ } filesystem{ ext3 }		\\
			mountpoint{ / }					\\
		.							\\
		$c{HostDiskSwap} 40 100% linux-swap			\\
			method{ swap } format{ } \$lvmok{ }		\\
		.							\\
		1 30 1000000000 ext3					\\
			method{ keep } \$lvmok{ }			\\
			lv_name{ dummy }				\\
		.

END

    foreach my $di_key (keys %preseed_cmds) {
        $preseed_file .= "d-i preseed/$di_key string ".
            (join ' && ', @{ $preseed_cmds{$di_key} }). "\n";
    }

    if ($ho->{Flags}{'no-di-kernel'}) {
	$preseed_file .= <<END;
d-i anna/no_kernel_modules boolean true
d-i base-installer/kernel/skip-install boolean true
d-i nobootloader/confirmation_common boolean true
END
    }

    $preseed_file .= "$c{DebianPreseed}\n";

    foreach my $name (keys %{ $xopts{Properties} }) {
        next unless $name =~ m/^preseed $suite /;
        $preseed_file .= "$' $xopts{Properties}{$name}\n";
    }

    return create_webfile($ho, "preseed$sfx", $preseed_file);
}

sub preseed_hook_command ($$$$) {
    my ($ho, $di_key, $sfx, $text) = @_;
    my $ix= $#{ $preseed_cmds{$di_key} } + 1;
    my $url= create_webfile($ho, "$di_key-$ix$sfx", $text);
    my $file= "/tmp/$di_key-$ix";
    my $cmd_cmd= "wget -O $file '$url' && chmod +x $file && $file";
    push @{ $preseed_cmds{$di_key} }, $cmd_cmd;
}

sub preseed_hook_installscript ($$$$$) {
    my ($ho, $sfx, $installer_dir, $installer_leaf, $data) = @_;
    my $installer_pathname= "$installer_dir/$installer_leaf";
    my $urlfile= $installer_pathname;
    $urlfile =~ s/[^-_0-9a-z]/ sprintf "X%02x", ord($&) /ge;
    my $url= create_webfile($ho, $urlfile, $data);
    preseed_hook_command($ho, 'early_command', $sfx, <<END);
#!/bin/sh
set -ex
mkdir -p '$installer_dir'
wget -O '$installer_pathname' '$url'
chmod +x '$installer_pathname'
END
}

1;
