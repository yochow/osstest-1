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

use POSIX;

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
                      preseed_create_guest
                      preseed_ssh
                      preseed_hook_command preseed_hook_installscript
                      preseed_hook_overlay
                      preseed_hook_cmds
                      di_installcmdline_core
                      );
    %EXPORT_TAGS = ( );

    @EXPORT_OK   = qw();
}

#---------- manipulation of Debian bootloader setup ----------

sub debian_boot_setup ($$$$$;$) {
    # $xenhopt==undef => is actually a guest, do not set up a hypervisor
    my ($ho, $want_kernver, $want_xsm, $xenhopt, $distpath, $hooks) = @_;

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
        $bootloader= setupboot_uboot($ho, $want_kernver,
                                     $want_xsm, $xenhopt, $kopt);
    } elsif ($ho->{Suite} =~ m/lenny/) {
        $bootloader= setupboot_grub1($ho, $want_kernver,
                                     $want_xsm, $xenhopt, $kopt);
    } else {
        $bootloader= setupboot_grub2($ho, $want_kernver,
                                     $want_xsm, $xenhopt, $kopt);
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

sub uboot_common_kernel_bootargs ($)
{
    my ($ho) = @_;

    my $root= target_guest_lv_name($ho,"root");
    my $rootdelay= get_host_property($ho, "rootdelay");

    my @bootargs;
    push @bootargs, "ro";
    push @bootargs, "root=$root";
    push @bootargs, "rootdelay=$rootdelay" if $rootdelay;

    return @bootargs;
}

sub uboot_scr_load_dtb () {
    return <<'END';
if test -z "\${fdt_addr}" && test -n "\${fdtfile}" ; then
    echo Loading dtbs/\${fdtfile}
    ext2load scsi 0 \${fdt_addr_r} dtbs/\${fdtfile}
    setenv fdt_addr \${fdt_addr_r}
fi
END
}

sub setupboot_uboot ($$$$) {
    my ($ho,$want_kernver,$want_xsm,$xenhopt,$xenkopt) = @_;
    my $bl= { };

    $bl->{UpdateConfig}= sub {
	my ( $ho ) = @_;

	my $xen = "xen";
	my $kern = "vmlinuz-$want_kernver";
	my $initrd = "initrd.img-$want_kernver";

	# According to u-boot policy $filesize is an unprefixed hex
	# number, but fdt set requires numbers to be prefixed
	# (e.g. with 0x for a hex number). See:
	#
	# http://lists.denx.de/pipermail/u-boot/2014-October/193622.html,
	# http://lists.denx.de/pipermail/u-boot/2014-November/194150.html and
	# http://lists.denx.de/pipermail/u-boot/2014-November/194150.html.
	#
	# However some older u-boot versions (e.g. on midway) erroneously
	# include the 0x prefix when setting $filesize from ext*load
	# commands, meaning we cannot simply unconditionally prepend
	# the 0x. Base it on a host flag quirk.
	my $size_hex_prefix =
	    $ho->{Flags}{'quirk-load-filesize-has-0x-prefix'} ?
	    '' : '0x';

	my $flask_commands = "";
	if ($want_xsm) {
	    # Use the flaskpolicy from tools build job because we might
	    # want to test cross releases policy compatibility.
	    my $flaskpolicy = get_runvar('flaskpolicy',$r{buildjob});
	    my $flask_policy_addr_r =
		get_host_property($ho, 'UBootSetFlaskAddrR', undef);
	    my $set_flask_addr_r =
		$flask_policy_addr_r ?
		"setenv flask_policy_addr_r $flask_policy_addr_r" : "";

	    $xenhopt .= " flask=enforcing";
	    $flask_commands = <<END;

${set_flask_addr_r}
ext2load scsi 0 \\\${flask_policy_addr_r} $flaskpolicy
fdt mknod /chosen module\@2
fdt set /chosen/module\@2 compatible "xen,xsm-policy" "xen,multiboot-module"
fdt set /chosen/module\@2 reg <\\\${flask_policy_addr_r} ${size_hex_prefix}\\\${filesize}>
echo Loaded $flaskpolicy to \\\${flask_policy_addr_r} (\\\${filesize})

END
	}

	logm("Xen options: $xenhopt");

	# Common kernel options
	my @kopt = uboot_common_kernel_bootargs($ho);

	# Dom0 specific kernel options
	my @xenkopt = @kopt;
	push @xenkopt, $xenkopt;
	# http://bugs.xenproject.org/xen/bug/45
	push @xenkopt, "clk_ignore_unused"
	    if $ho->{Suite} =~ m/wheezy|jessie/;

	$xenkopt = join ' ', @xenkopt;
	logm("Dom0 Linux options: $xenkopt");

	# Native specific kernel options
	my $natcons = get_host_native_linux_console($ho);
	my @natkopt = @kopt;
	push @natkopt, "console=$natcons" unless $natcons eq "NONE";

	my $natkopt = join ' ', @natkopt;
	logm("Native linux options: $natkopt");

	my $early_commands = get_host_property($ho, 'UBootScriptEarlyCommands', '');
	my $xen_addr_r = get_host_property($ho, 'UBootSetXenAddrR', undef);

	my $load_dtb = uboot_scr_load_dtb();

	my $set_xen_addr_r =
	    $xen_addr_r ? "setenv xen_addr_r $xen_addr_r" : "";

	target_cmd_root($ho, <<END);
if test ! -f /boot/$kern ; then
    exit 1
fi
# Save a copy of the original
cp -n /boot/boot.xen /boot/boot.xen.bak
cp -n /boot/boot.scr.xen /boot/boot.scr.xen.bak

xen=`readlink /boot/$xen`

cat >/boot/boot.xen <<EOF
${load_dtb}

fdt addr \\\${fdt_addr}
fdt resize

${early_commands}
${set_xen_addr_r}

fdt set /chosen \\\#address-cells <1>
fdt set /chosen \\\#size-cells <1>

ext2load scsi 0 \\\${xen_addr_r} \$xen
setenv bootargs "$xenhopt"
echo Loaded \$xen to \\\${xen_addr_r} (\\\${filesize})
echo command line: \\\${bootargs}

ext2load scsi 0 \\\${kernel_addr_r} $kern
fdt mknod /chosen module\@0
fdt set /chosen/module\@0 compatible "xen,linux-zimage" "xen,multiboot-module"
fdt set /chosen/module\@0 reg <\\\${kernel_addr_r} ${size_hex_prefix}\\\${filesize}>
fdt set /chosen/module\@0 bootargs "$xenkopt"
echo Loaded $kern to \\\${kernel_addr_r} (\\\${filesize})
echo command line: $xenkopt

ext2load scsi 0 \\\${ramdisk_addr_r} $initrd
fdt mknod /chosen module\@1
fdt set /chosen/module\@1 compatible "xen,linux-initrd" "xen,multiboot-module"
fdt set /chosen/module\@1 reg <\\\${ramdisk_addr_r} ${size_hex_prefix}\\\${filesize}>
echo Loaded $initrd to \\\${ramdisk_addr_r} (\\\${filesize})

${flask_commands}

fdt chosen

fdt print /chosen

echo Booting \\\${xen_addr_r} - \\\${fdt_addr}
bootz \\\${xen_addr_r} - \\\${fdt_addr}
EOF
mkimage -A arm -T script -d /boot/boot.xen /boot/boot.scr.xen
cp /boot/boot.scr.xen /boot/boot.scr

# Create boot.scr.nat for convenience too
cat >/boot/boot.nat <<EOF
setenv bootargs $natkopt
${load_dtb}
echo Loading $kern
ext2load scsi 0 \\\${kernel_addr_r} $kern
echo Loading $initrd
ext2load scsi 0 \\\${ramdisk_addr_r} $initrd
echo Booting
bootz \\\${kernel_addr_r} \\\${ramdisk_addr_r}:\\\${filesize} \\\${fdt_addr}
EOF
mkimage -A arm -T script -d /boot/boot.nat /boot/boot.scr.nat

END
    };

    $bl->{GetBootKern}= sub {
	return "vmlinuz-$want_kernver";
    };

    $bl->{PreFinalUpdate}= sub { };

    return $bl;
}

sub setupboot_grub1 ($$$$) {
    my ($ho,$want_kernver,$want_xsm,$xenhopt,$xenkopt) = @_;
    my $bl= { };

    my $rmenu= "/boot/grub/menu.lst";
    my $lmenu= "$stash/$ho->{Name}--menu.lst.out";

    if ($want_xsm) {
	die "Enabling XSM with GRUB is not supported";
    }

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

# Note on running OSSTest on Squeeze with old Xen kernel: check out
# Debian bug #633127 "/etc/grub/20_linux does not recognise some old
# Xen kernels"
# Currently setupboot_grub2 relies on Grub menu not having submenu.
# Check Debian bug #690538.
sub setupboot_grub2 ($$$$) {
    my ($ho,$want_kernver,$want_xsm,$xenhopt,$xenkopt) = @_;
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
		} elsif ($want_xsm && !defined $entry->{Xenpolicy}) {
		    logm("(skipping entry at $entry->{StartLine};".
			 " XSM policy file not present)");
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
	    if (m/^\s*module\s*\/(xenpolicy\S+)/) {
                $entry->{Xenpolicy}= $1;
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
    push @cl, "rescue/enable=true" if $xopts{RescueMode};

    return @cl;
}

sub preseed_ssh ($$) {
    my ($ho,$sfx) = @_;

    my $authkeys_url= create_webfile($ho, "authkeys$sfx", authorized_keys());

    my $hostkeyfile= "$c{OverlayLocal}/etc/ssh/ssh_host_rsa_key.pub";
    my $hostkey= get_filecontents($hostkeyfile);
    chomp($hostkey); $hostkey.="\n";
    my $knownhosts= '';

    my $hostsq= $dbh_tests->prepare(<<END);
        SELECT val FROM runvars
         WHERE flight=? AND name LIKE '%host'
         GROUP BY val
END
    $hostsq->execute($flight);
    while (my ($node) = $hostsq->fetchrow_array()) {
        my $defaultfqdn = $node;
        $defaultfqdn .= ".$c{TestHostDomain}" unless $defaultfqdn =~ m/\./;

        my %props;
        $mhostdb->get_properties($node, \%props);

        my $longname= $props{Fqdn} // $defaultfqdn;
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
END
}

sub preseed_base ($$$$;@) {
    my ($ho,$suite,$sfx,$extra_packages,%xopts) = @_;

    $xopts{ExtraPreseed} ||= '';

    preseed_ssh($ho, $sfx);
    preseed_hook_overlay($ho, $sfx, $c{OverlayLocal}, 'overlay-local.tar');
    preseed_hook_overlay($ho, $sfx, 'overlay', 'overlay.tar');

    my $preseed = <<"END";
d-i mirror/suite string $suite

d-i debian-installer/locale string en_GB
d-i console-keymaps-at/keymap select gb
d-i keyboard-configuration/xkb-keymap string en_GB

#d-i debconf/frontend string readline

d-i mirror/country string manual
d-i mirror/http/proxy string

d-i clock-setup/utc boolean true
d-i time/zone string $c{Timezone}
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
d-i mirror/http/proxy string $c{DebianMirrorProxy}
d-i mirror/http/directory string /$c{DebianMirrorSubpath}
d-i apt-setup/use_mirror boolean yes
d-i apt-setup/another boolean false
d-i apt-setup/non-free boolean false
d-i apt-setup/contrib boolean false

d-i pkgsel/include string openssh-server, ntp, ntpdate, ethtool, chiark-utils-bin, $extra_packages

$xopts{ExtraPreseed}

END

    my $ntpserver = get_target_property($ho,'NtpServer');
    $preseed .= <<"END" if $ntpserver;
d-i clock-setup/ntp-server string $ntpserver
END

    $preseed .= <<"END";

### END OF DEBIAN PRESEED BASE
END

    return $preseed;
}

sub preseed_create_guest ($$;@) {
    my ($ho, $sfx, %xopts) = @_;

    my $suite= $xopts{Suite} || $c{DebianSuite};

    my $preseed_file= preseed_base($ho, $suite, $sfx, '', %xopts);
    $preseed_file.= (<<END);
d-i     partman-auto/method             string regular
d-i     partman-auto/choose_recipe \\
                select All files in one partition (recommended for new users)

d-i     grub-installer/bootdev          string /dev/xvda

END

    $preseed_file .= preseed_hook_cmds();

    return create_webfile($ho, "preseed$sfx", $preseed_file);
}

sub preseed_create ($$;@) {
    my ($ho, $sfx, %xopts) = @_;

    my $disk= $xopts{DiskDevice} || '/dev/sda';
    my $suite= $xopts{Suite} || $c{DebianSuite};

    my $d_i= $ho->{Tftp}{Path}.'/'.$ho->{Tftp}{DiBase}.'/'.$r{arch}.'/'.
	$c{TftpDiVersion}.'-'.$ho->{Suite};

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

echo FANCYTTY=0 >> /target/etc/lsb-base-logging.sh
END

    my $dtbs = "$d_i/dtbs.tar.gz";
    if (!stat $dtbs) {
        $!==&ENOENT or die "dtbs $!";
    } elsif (-e _) {
	my $durl = create_webfile($ho, "dtbs", sub {
	    copy("$d_i/dtbs.tar.gz", $_[0])
		or die "Copy dtbs failed: $!";
	});
	preseed_hook_command($ho, 'late_command', $sfx, <<END);
#!/bin/sh
set -ex

r=/target

wget -O \$r/tmp/dtbs.tar.gz $durl

in-target tar -C /boot -xaf /tmp/dtbs.tar.gz
END
    }

    foreach my $kp (keys %{ $ho->{Flags} }) {
	$kp =~ s/need-kernel-deb-// or next;

	my $kern = "$d_i/$kp.deb";
	my $kurl = create_webfile($ho, "kernel", sub {
	    copy($kern, $_[0])
		or die "Copy kernel $kern failed: $!";
        });

	my $ird = "$d_i/initramfs-tools.deb";
	my $iurl = create_webfile($ho, "initramfs-tools", sub {
	    copy($ird, $_[0])
		or die "Copy initramfs-tools $ird failed: $!";
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
	my @bootargs = uboot_common_kernel_bootargs($ho);

	my $console=get_host_native_linux_console($ho);

	push @bootargs, "console=$console" unless $console eq "NONE";

	my $bootargs = join ' ', @bootargs;

	my $load_dtb = uboot_scr_load_dtb();

	preseed_hook_command($ho, 'late_command', $sfx, <<END);
#!/bin/sh
set -ex

r=/target #/

kernel=`readlink \$r/vmlinuz | sed -e 's|boot/||'`
initrd=`readlink \$r/initrd.img | sed -e 's|boot/||'`

cat >\$r/boot/boot.deb <<EOF
setenv bootargs $bootargs
${load_dtb}
echo Loading \$kernel
ext2load scsi 0 \\\${kernel_addr_r} \$kernel
echo Loading \$initrd
ext2load scsi 0 \\\${ramdisk_addr_r} \$initrd
echo Booting
bootz \\\${kernel_addr_r} \\\${ramdisk_addr_r}:\\\${filesize} \\\${fdt_addr}
EOF

in-target mkimage -A arm -T script -d /boot/boot.deb /boot/boot.scr.deb
in-target cp /boot/boot.scr.deb /boot/boot.scr
END
    }

    my $modules = get_host_property($ho, "ExtraInitramfsModules", "NONE");
    if ( $modules ne "NONE" )
    {
	# This is currently the best available way to add modules to
	# the installed initramfs. See
	# https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=764805
        preseed_hook_command($ho, 'late_command', $sfx, <<END);
#!/bin/sh
set -ex

for i in $modules ; do
    echo \$i >> /target/etc/initramfs-tools/modules
done
in-target update-initramfs -u -k all
END
    }

    my @extra_packages = ();
    push(@extra_packages, "u-boot-tools") if $ho->{Flags}{'need-uboot-bootscr'};

    my $extra_packages = join(",",@extra_packages);

    my $preseed_file= preseed_base($ho,$suite,$sfx,$extra_packages,%xopts);

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

    $preseed_file .= preseed_hook_cmds();

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

sub preseed_hook_overlay ($$$$) {
    my ($ho, $sfx, $srcdir, $tfilename) = @_;
    my $url= create_webfile($ho, "$tfilename$sfx", sub {
        my ($fh) = @_;
        contents_make_cpio($fh, 'ustar', $srcdir);
    });
    preseed_hook_command($ho, 'late_command', $sfx, <<END);
#!/bin/sh
set -ex

r=/target/root
cd \$r

umask 022

wget -O overlay.tar '$url'
cd /target
tar xf \$r/overlay.tar
cd \$r
rm overlay.tar

END
}

sub preseed_hook_cmds () {
    my $preseed;
    foreach my $di_key (keys %preseed_cmds) {
        $preseed .= "d-i preseed/$di_key string ".
            (join ' && ', @{ $preseed_cmds{$di_key} }). "\n";
    }
    return $preseed;
}

1;
