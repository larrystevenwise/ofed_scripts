#!/usr/bin/perl
#
# Copyright (c) 2016 Mellanox Technologies. All rights reserved.
#
# This Software is licensed under one of the following licenses:
#
# 1) under the terms of the "Common Public License 1.0" a copy of which is
#    available from the Open Source Initiative, see
#    http://www.opensource.org/licenses/cpl.php.
#
# 2) under the terms of the "The BSD License" a copy of which is
#    available from the Open Source Initiative, see
#    http://www.opensource.org/licenses/bsd-license.php.
#
# 3) under the terms of the "GNU General Public License (GPL) Version 2" a
#    copy of which is available from the Open Source Initiative, see
#    http://www.opensource.org/licenses/gpl-license.php.
#
# Licensee has the right to choose one of the above licenses.
#
# Redistributions of source code must retain the above copyright
# notice and one of the license notices.
#
# Redistributions in binary form must reproduce both the above copyright
# notice, one of the license notices in the documentation
# and/or other materials provided with the distribution.


use strict;
use File::Basename;
use File::Path;
use File::Find;
use File::Copy;
use Cwd;
use Term::ANSIColor qw(:constants);
use sigtrap 'handler', \&sig_handler, 'normal-signals';

$ENV{"LANG"} = "en_US.UTF-8";

if ($<) {
    print RED "Only root can run $0", RESET "\n";
    exit 1;
}

$| = 1;
my $LOCK_EXCLUSIVE = 2;
my $UNLOCK         = 8;
#Setup some defaults
my $KEY_ESC=27;
my $KEY_CNTL_C=3;
my $KEY_ENTER=13;

my $BASIC = 1;
my $HPC = 2;
my $ALL = 3;
my $CUSTOM = 4;

my $interactive = 1;
my $quiet = 0;
my $verbose = 1;
my $verbose2 = 0;
my $verbose3 = 0;

my $print_available = 0;

my $clear_string = `clear`;
my $bonding_force_all_os = 0;

my $vendor_pre_install = "";
my $vendor_post_install = "";
my $vendor_pre_uninstall = "";
my $vendor_post_uninstall = "";

my $DISTRO = "";
my $rpmbuild_flags = "";
my $rpminstall_flags = "";

my $WDIR    = dirname($0);
chdir $WDIR;
my $CWD     = getcwd;
my $TMPDIR  = '/tmp';
my $netdir;

my $config = $CWD . '/ofed.conf';
chomp $config;
my $config_net;

my $builddir = "/var/tmp/";
chomp $builddir;

my $PACKAGE     = 'OFED';
my $ofedlogs = "/tmp/$PACKAGE.$$.logs";
mkpath([$ofedlogs]);

my $default_prefix = '/usr';
chomp $default_prefix;
my $prefix = $default_prefix;

my $build32 = 0;
my $arch = `uname -m`;
chomp $arch;
my $kernel = `uname -r`;
chomp $kernel;
my $linux_obj = "/lib/modules/$kernel/build";
chomp $linux_obj;
my $linux = "/lib/modules/$kernel/source";
chomp $linux;
my $ib_udev_rules = "/etc/udev/rules.d/90-ib.rules";

# Define RPMs environment
my $dist_rpm;
my $dist_rpm_ver = 0;
my $dist_rpm_rel = 0;

my $umad_dev_rw = 0;
my $config_given = 0;
my $config_net_given = 0;
my $kernel_given = 0;
my $kernel_source_given = 0;
my $install_option;
my $check_linux_deps = 1;
my $force = 0;
my $kmp = 1;
my $with_xeon_phi = 0;
my $libnl = "libnl3";
my $libnl_devel = "libnl3-devel";
my %disabled_packages;

while ( $#ARGV >= 0 ) {

   my $cmd_flag = shift(@ARGV);

    if ( $cmd_flag eq "-c" or $cmd_flag eq "--config" ) {
        $config = shift(@ARGV);
        $interactive = 0;
        $config_given = 1;
    } elsif ( $cmd_flag eq "-n" or $cmd_flag eq "--net" ) {
        $config_net = shift(@ARGV);
        $config_net_given = 1;
    } elsif ( $cmd_flag eq "-l" or $cmd_flag eq "--prefix" ) {
        $prefix = shift(@ARGV);
        $prefix =~ s/\/$//;
    } elsif ( $cmd_flag eq "-k" or $cmd_flag eq "--kernel" ) {
        $kernel = shift(@ARGV);
        $kernel_given = 1;
    } elsif ( $cmd_flag eq "-s" or $cmd_flag eq "--linux" ) {
        $linux = shift(@ARGV);
        $kernel_source_given = 1;
    } elsif ( $cmd_flag eq "-o" or $cmd_flag eq "--linux-obj" ) {
        $linux_obj = shift(@ARGV);
        $kernel_source_given = 1;
    } elsif ( $cmd_flag eq "-p" or $cmd_flag eq "--print-available" ) {
        $print_available = 1;
    } elsif ( $cmd_flag eq "--force" ) {
        $force = 1;
    } elsif ( $cmd_flag eq "--all" ) {
        $interactive = 0;
        $install_option = 'all';
    } elsif ( $cmd_flag eq "--hpc" ) {
        $interactive = 0;
        $install_option = 'hpc';
    } elsif ( $cmd_flag eq "--basic" ) {
        $interactive = 0;
        $install_option = 'basic';
    } elsif ( $cmd_flag eq "--umad-dev-rw" ) {
        $umad_dev_rw = 1;
    } elsif ( $cmd_flag eq "--build32" ) {
        if (supported32bit()) {
            $build32 = 1;
        }
    } elsif ( $cmd_flag eq "--without-depcheck" ) {
        $check_linux_deps = 0;
    } elsif ( $cmd_flag eq "--builddir" ) {
        $builddir = shift(@ARGV);
    } elsif ( $cmd_flag eq "-q" ) {
        $quiet = 1;
    } elsif ( $cmd_flag eq "-v" ) {
        $verbose = 1;
    } elsif ( $cmd_flag eq "-vv" ) {
        $verbose = 1;
        $verbose2 = 1;
    } elsif ( $cmd_flag eq "-vvv" ) {
        $verbose = 1;
        $verbose2 = 1;
        $verbose3 = 1;
    } elsif ( $cmd_flag eq "--with-xeon-phi" ) {
        $with_xeon_phi = 1;
    } elsif ( $cmd_flag =~ /--without|--disable/ ) {
        my $pckg = $cmd_flag;
        $pckg =~ s/--without-|--disable-//;
        $disabled_packages{$pckg} = 1;
    } else {
        &usage();
        exit 1;
    }
}

if (-f "/etc/issue") {
    if (-f "/usr/bin/dpkg") {
        if ( `which rpm` eq ""){
            print RED "rpm package is not installed. Exiting...", RESET "\n";
            print RED "Please run 'sudo apt-get install rpm'", RESET "\n";
            exit 1;
        }
        if (-f "/etc/lsb-release") {
            $dist_rpm  = `lsb_release -s -i`;
            $dist_rpm_ver = `lsb_release -s -r`;
        }
        else {
            print "lsb_release is required to continue\n";
            $dist_rpm = "unsupported";
        }
    }
    else {
        $dist_rpm = `rpm -qf /etc/issue 2> /dev/null | grep -v "is not owned by any package" | head -1`;
        chomp $dist_rpm;
        if ($dist_rpm) {
            $dist_rpm = `rpm -q --queryformat "[%{NAME}]-[%{VERSION}]-[%{RELEASE}]" $dist_rpm`;
            chomp $dist_rpm;
            $dist_rpm_ver = get_rpm_ver_inst($dist_rpm);
            $dist_rpm_rel = get_rpm_rel_inst($dist_rpm);
        } else {
            $dist_rpm = "unsupported";
        }
    }
}
else {
    $dist_rpm = "unsupported";
}
chomp $dist_rpm;

my $rpm_distro = '';

if ($dist_rpm =~ /openSUSE-release-11.2/) {
    $DISTRO = "openSUSE11.2";
    $rpm_distro = "opensuse11sp2";
} elsif ($dist_rpm =~ /openSUSE/) {
    $DISTRO = "openSUSE";
    $rpm_distro = "opensuse11sp0";
} elsif ($dist_rpm =~ /sles-release-12\.2|SLES.*release-12\.2/) {
    $DISTRO = "SLES12";
    $rpm_distro = "sles12sp2";
} elsif ($dist_rpm =~ /sles-release-12\.1|SLES.*release-12\.1/) {
    $DISTRO = "SLES12";
    $rpm_distro = "sles12sp1";
} elsif ($dist_rpm =~ /sles-release-12|SLES.*release-12/) {
    $DISTRO = "SLES12";
    $rpm_distro = "sles12sp0";
} elsif ($dist_rpm =~ /sles-release-11.4|SLES.*release-11.4/) {
    $DISTRO = "SLES11";
    $rpm_distro = "sles11sp4";
} elsif ($dist_rpm =~ /sles-release-11.3|SLES.*release-11.3/) {
    $DISTRO = "SLES11";
    $rpm_distro = "sles11sp3";
} elsif ($dist_rpm =~ /sles-release-11.2|SLES.*release-11.2/) {
    $DISTRO = "SLES11";
    $rpm_distro = "sles11sp2";
} elsif ($dist_rpm =~ /sles-release-11.1|SLES.*release-11.1/) {
    $DISTRO = "SLES11";
    $rpm_distro = "sles11sp1";
} elsif ($dist_rpm =~ /sles-release-11/) {
    $DISTRO = "SLES11";
    $rpm_distro = "sles11sp0";
} elsif ($dist_rpm =~ /sles-release-10-15.45.8/) {
    $DISTRO = "SLES10";
    $rpm_distro = "sles10sp3";
} elsif ($dist_rpm =~ /sles-release-10-15.57.1/) {
    $DISTRO = "SLES10";
    $rpm_distro = "sles10sp4";
} elsif ($dist_rpm =~ /redhat-release-.*-6.1|sl-release-6.1|centos-release-6-1/) {
    $DISTRO = "RHEL6.1";
    $rpm_distro = "rhel6u1";
} elsif ($dist_rpm =~ /redhat-release-.*-6.2|sl-release-6.2|centos-release-6-2/) {
    $DISTRO = "RHEL6.2";
    $rpm_distro = "rhel6u2";
} elsif ($dist_rpm =~ /redhat-release-.*-6.3|sl-release-6.3|centos-release-6-3/) {
    $DISTRO = "RHEL6.3";
    $rpm_distro = "rhel6u3";
} elsif ($dist_rpm =~ /redhat-release-.*-6.4|sl-release-6.4|centos-release-6-4/) {
    $DISTRO = "RHEL6.4";
    $rpm_distro = "rhel6u4";
} elsif ($dist_rpm =~ /redhat-release-.*-6.5|sl-release-6.5|centos-release-6-5/) {
    $DISTRO = "RHEL6.5";
    $rpm_distro = "rhel6u5";
} elsif ($dist_rpm =~ /redhat-release-.*-6.6|sl-release-6.6|centos-release-6-6/) {
    $DISTRO = "RHEL6.6";
    $rpm_distro = "rhel6u6";
} elsif ($dist_rpm =~ /redhat-release-.*-6.7|sl-release-6.7|centos-release-6-7/) {
    $DISTRO = "RHEL6.7";
    $rpm_distro = "rhel6u7";
} elsif ($dist_rpm =~ /redhat-release-.*-7.0|sl-release-7.0|centos-release-7-0/) {
    $DISTRO = "RHEL7.0";
    $rpm_distro = "rhel7u0";
} elsif ($dist_rpm =~ /redhat-release-.*-7.1|sl-release-7.1|centos-release-7-1/) {
    $DISTRO = "RHEL7.1";
    $rpm_distro = "rhel7u1";
} elsif ($dist_rpm =~ /redhat-release-.*-7.2|sl-release-7.2|centos-release-7-2/) {
    $DISTRO = "RHEL7.2";
    $rpm_distro = "rhel7u2";
} elsif ($dist_rpm =~ /redhat-release-.*-7.3|sl-release-7.3|centos-release-7-3/) {
    $DISTRO = "RHEL7.3";
    $rpm_distro = "rhel7u3";
} elsif ($dist_rpm =~ /oraclelinux-release-6.*-1.0.2/) {
    $DISTRO = "OEL6.1";
    $rpm_distro = "oel6u1";
} elsif ($dist_rpm =~ /oraclelinux-release-6.*-2.0.2/) {
    $DISTRO = "OEL6.2";
    $rpm_distro = "oel6u2";
} elsif ($dist_rpm =~ /redhat-release-.*-6.0|centos-release-6-0/) {
    $DISTRO = "RHEL6.0";
    $rpm_distro = "rhel6u0";
} elsif ($dist_rpm =~ /redhat-release-.*-5.8|centos-release-5-8|enterprise-release-5-8/) {
    $DISTRO = "RHEL5.8";
    $rpm_distro = "rhel5u8";
} elsif ($dist_rpm =~ /redhat-release-.*-5.7|centos-release-5-7|enterprise-release-5-7/) {
    $DISTRO = "RHEL5.7";
    $rpm_distro = "rhel5u7";
} elsif ($dist_rpm =~ /redhat-release-.*-5.6|centos-release-5-6|enterprise-release-5-6/) {
    $DISTRO = "RHEL5.6";
    $rpm_distro = "rhel5u6";
} elsif ($dist_rpm =~ /redhat-release-.*-5.5|centos-release-5-5|enterprise-release-5-5/) {
    system("grep -wq XenServer /etc/issue > /dev/null 2>&1");
    my $res = $? >> 8;
    my $sig = $? & 127;
    if ($sig or $res) {
        $DISTRO = "RHEL5.5";
        $rpm_distro = "rhel5u5";
    } else {
        $DISTRO = "XenServer5.6";
        $rpm_distro = "xenserver5u6";
    }
} elsif ($dist_rpm =~ /redhat-release-.*-5.4|centos-release-5-4/) {
    $DISTRO = "RHEL5.4";
    $rpm_distro = "rhel5u4";
} elsif ($dist_rpm =~ /redhat-release-.*-5.3|centos-release-5-3/) {
    $DISTRO = "RHEL5.3";
    $rpm_distro = "rhel5u3";
} elsif ($dist_rpm =~ /redhat-release-.*-5.2|centos-release-5-2/) {
    $DISTRO = "RHEL5.2";
    $rpm_distro = "rhel5u2";
} elsif ($dist_rpm =~ /redhat-release-4AS-9/) {
    $DISTRO = "RHEL4.8";
    $rpm_distro = "rhel4u8";
} elsif ($dist_rpm =~ /redhat-release-4AS-8/) {
    $DISTRO = "RHEL4.7";
    $rpm_distro = "rhel4u7";
} elsif ($dist_rpm =~ /fedora-release-12/) {
    $DISTRO = "FC12";
    $rpm_distro = "fc12";
} elsif ($dist_rpm =~ /fedora-release-13/) {
    $DISTRO = "FC13";
    $rpm_distro = "fc13";
} elsif ($dist_rpm =~ /fedora-release-14/) {
    $DISTRO = "FC14";
    $rpm_distro = "fc14";
} elsif ($dist_rpm =~ /fedora-release-15/) {
    $DISTRO = "FC15";
    $rpm_distro = "fc15";
} elsif ($dist_rpm =~ /fedora-release-16/) {
    $DISTRO = "FC16";
    $rpm_distro = "fc16";
} elsif ($dist_rpm =~ /fedora-release-17/) {
    $DISTRO = "FC17";
    $rpm_distro = "fc17";
} elsif ($dist_rpm =~ /fedora-release-18/) {
    $DISTRO = "FC18";
    $rpm_distro = "fc18";
} elsif ($dist_rpm =~ /fedora-release-19/) {
    $DISTRO = "FC19";
    $rpm_distro = "fc19";
} elsif ($dist_rpm =~ /Ubuntu/) {
    $DISTRO = "UBUNTU$dist_rpm_ver";
    $rpm_distro =~ tr/[A-Z]/[a-z]/;
    $rpm_distro =~ s/\./u/g;
} elsif ( -f "/etc/debian_version" ) {
    $DISTRO = "DEBIAN";
    $rpm_distro = "debian";
} else {
    $DISTRO = "unsupported";
    $rpm_distro = "unsupported";
}

my $SRPMS = $CWD . '/' . 'SRPMS/';
chomp $SRPMS;
my $RPMS  = $CWD . '/' . 'RPMS' . '/' . $dist_rpm . '/' . $arch;
chomp $RPMS;
if (not -d $RPMS) {
    mkpath([$RPMS]);
}

my $target_cpu  = `rpm --eval '%{_target_cpu}'`;
chomp $target_cpu;

my $target_cpu32;
if ($arch eq "x86_64") {
    if (-f "/etc/SuSE-release") {
        $target_cpu32 = 'i586';
    }
    else {
        $target_cpu32 = 'i686';
    }
}
elsif ($arch eq "ppc64") {
    $target_cpu32 = 'ppc';
}
elsif ($arch eq "sparc64") {
    $target_cpu32 = 'sparc';
}

chomp $target_cpu32;

if ($kernel_given and not $kernel_source_given) {
    if (-d "/lib/modules/$kernel/build") {
        $linux_obj = "/lib/modules/$kernel/build";
    }
    else {
        print RED "Provide path to the kernel sources for $kernel kernel.", RESET "\n";
        exit 1;
    }
}

my $kernel_rel = $kernel;
$kernel_rel =~ s/-/_/g;

if ($DISTRO eq "DEBIAN") {
    $check_linux_deps = 0;
}
if ($DISTRO =~ /UBUNTU.*/) {
    $rpminstall_flags .= ' --force-debian --nodeps ';
    $rpmbuild_flags .= ' --nodeps ';
}

if (not $check_linux_deps) {
    $rpmbuild_flags .= ' --nodeps';
    $rpminstall_flags .= ' --nodeps';
}

if ($with_xeon_phi) {
    $rpmbuild_flags .= "--define 'PSM_HAVE_SCIF 1'";
}

my $optflags  = `rpm --eval '%{optflags}'`;
chomp $optflags;

my $mandir      = `rpm --eval '%{_mandir}'`;
chomp $mandir;
my $sysconfdir  = `rpm --eval '%{_sysconfdir}'`;
chomp $sysconfdir;
my %main_packages = ();
my @selected_packages = ();
my @selected_by_user = ();
my @selected_modules_by_user = ();
my @packages_to_uninstall = ();
my @dependant_packages_to_uninstall = ();
my %selected_for_uninstall = ();
my @selected_kernel_modules = ();


my $gcc = "gcc";
my $gcc_cpp = "gcc-c++";
my $libstdc = '';
my $libgcc = 'libgcc';
my $libgfortran = '';
my $curl_devel = 'curl-devel';
my $libudev_devel = 'libudev-devel';
my $pkgconfig = "pkgconfig";
my $glibc_devel = 'glibc-devel';
my $cmake = 'cmake';
my $ninja = 'ninja';
if ($DISTRO =~ m/SLES11/) {
    $libstdc = 'libstdc++43';
    $libgcc = 'libgcc43';
    $libgfortran = 'libgfortran43';
    $curl_devel = 'libcurl-devel';
    if ($rpm_distro eq "sles11sp2") {
        $libstdc = 'libstdc++46';
        $libgcc = 'libgcc46';
        $libgfortran = 'libgfortran46';
    }
    $pkgconfig = "pkg-config";
} elsif ($DISTRO =~ m/SLES12/) {
    $cmake = 'cmake__3.5';
    $libstdc = 'libstdc++6';
    $libgcc = 'libgcc_s1';
    $libgfortran = 'libgfortran3';
    $curl_devel = 'libcurl-devel';
    $libnl = "libnl3-200";
    $libnl_devel = "libnl3-devel";
    $pkgconfig = "pkg-config";
} elsif ($DISTRO =~ m/RHEL|OEL|FC/) {
    $libstdc = 'libstdc++';
    $libgcc = 'libgcc';
    $libgfortran = 'gcc-gfortran';
    if ($DISTRO =~ m/RHEL6|OEL6|FC/) {
        $curl_devel = 'libcurl-devel';
    } elsif ($DISTRO =~ m/RHEL7/) {
        $curl_devel = 'libcurl-devel';
        $libudev_devel = 'systemd-devel';
    }
} else {
    $libstdc = 'libstdc++';
}
my $libstdc_devel = "$libstdc-devel";
if ($DISTRO =~ m/SLES12/) {
    $libstdc_devel = 'libstdc++-devel';
}

# Suffix for 32 and 64 bit packages
my $is_suse_suff64 = $arch eq "ppc64" && $DISTRO !~ /SLES11|SLES12/;
my $suffix_32bit = ($DISTRO =~ m/SLES|openSUSE/ && !$is_suse_suff64) ? "-32bit" : ".$target_cpu32";
my $suffix_64bit = ($DISTRO =~ m/SLES|openSUSE/ &&  $is_suse_suff64) ? "-64bit" : "";

sub usage
{
   print GREEN;
   print "\n Usage: $0 [-c <packages config_file>|--all|--hpc|--basic] [-n|--net <network config_file>]\n";

   print "\n           -c|--config <packages config_file>. Example of the config file can be found under docs (ofed.conf-example).";
   print "\n           -n|--net <network config_file>      Example of the config file can be found under docs (ofed_net.conf-example).";
   print "\n           -l|--prefix          Set installation prefix.";
   print "\n           -p|--print-available Print available packages for current platform.";
   print "\n                                And create corresponding ofed.conf file.";
   print "\n           -k|--kernel <kernel version>. Default on this system: $kernel";
   print "\n           -s|--linux           <path to the kernel sources>. Default on this system: $linux";
   print "\n           -o|--linux-obj       <path to the kernel sources>. Default on this system: $linux_obj";
   print "\n           --build32            Build 32-bit libraries. Relevant for x86_64 and ppc64 platforms";
   print "\n           --without-depcheck   Skip Distro's libraries check";
   print "\n           -v|-vv|-vvv          Set verbosity level";
   print "\n           -q                   Set quiet - no messages will be printed";
   print "\n           --force              Force uninstall RPM coming with Distribution";
   print "\n           --builddir           Change build directory. Default: $builddir";
   print "\n           --umad-dev-rw        Grant non root users read/write permission for umad devices instead of default";
   print "\n           --with-xeon-phi      Install XEON PHI support";
   print "\n           --without-<package>  Do not install package";
   print "\n\n           --all|--hpc|--basic    Install all,hpc or basic packages correspondingly";
   print RESET "\n\n";
}

my $sysfsutils;
my $sysfsutils_devel;

if ($DISTRO =~ m/SLES|openSUSE/) {
    $sysfsutils = "sysfsutils";
    $sysfsutils_devel = "sysfsutils";
} elsif ($DISTRO =~ m/RHEL5/) {
    $sysfsutils = "libsysfs";
    $sysfsutils_devel = "libsysfs";
} elsif ($DISTRO =~ m/RHEL6|RHEL7|OEL6/) {
    $sysfsutils = "libsysfs";
    $sysfsutils_devel = "libsysfs";
}

my $kernel_req = "";
if ($DISTRO =~ /RHEL|OEL/) {
    $kernel_req = "redhat-rpm-config";
} elsif ($DISTRO =~ /SLES10/) {
    $kernel_req = "kernel-syms";
} elsif ($DISTRO =~ /SLES11|SLES12/) {
    $kernel_req = "kernel-source";
}

my $network_dir;
if ($DISTRO =~ m/SLES/) {
    $network_dir = "/etc/sysconfig/network";
}
else {
    $network_dir = "/etc/sysconfig/network-scripts";
}

my $setpci = '/sbin/setpci';
my $lspci = '/sbin/lspci';

# List of packages that were included in the previous OFED releases
# for uninstall purpose
my @prev_ofed_packages = (
                        "mpich_mlx", "ibtsal", "openib", "opensm", "opensm-devel", "opensm-libs", "opensm-libs3",
                        "mpi_ncsa", "mpi_osu", "thca", "ib-osm", "osm", "diags", "ibadm",
                        "ib-diags", "ibgdiag", "ibdiag", "ib-management",
                        "ib-verbs", "ib-ipoib", "ib-cm", "ib-sdp", "ib-dapl", "udapl",
                        "udapl-devel", "libdat", "libibat", "ib-kdapl", "ib-srp", "ib-srp_target",
                        "libipathverbs", "libipathverbs-devel",
                        "libehca", "libehca-devel", "dapl", "dapl-devel",
                        "libibcm", "libibcm-devel", "libibcommon", "libibcommon-devel",
                        "libibmad", "libibmad-devel", "libibumad", "libibumad-devel",
                        "ibsim", "ibsim-debuginfo",
                        "libibverbs", "libibverbs-devel", "libibverbs-utils",
                        "libipathverbs", "libipathverbs-devel", "libmthca",
                        "libmthca-devel", "libmlx4", "libmlx4-devel",
                        "libsdp", "librdmacm", "librdmacm-devel", "librdmacm-utils", "ibacm",
                        "openib-diags", "openib-mstflint", "openib-perftest", "openib-srptools", "openib-tvflash",
                        "openmpi", "openmpi-devel", "openmpi-libs",
                        "ibutils", "ibutils-devel", "ibutils-libs", "ibutils2", "ibutils2-devel",
                        "libnes", "libnes-devel",
                        "infinipath-psm", "infinipath-psm-devel", "intel-mic-psm", "intel-mic-psm-devel",
                        "ibpd", "libibscif", "libibscif-devel",
                        "rdma-core", "rdma-core-compat",
                        "mvapich", "openmpi", "mvapich2"
                        );


my @distro_ofed_packages = (
                        "libamso", "libamso-devel", "dapl2", "dapl2-devel", "mvapich", "mvapich2", "mvapich2-devel",
                        "mvapich-devel", "libboost_mpi1_36_0", "boost-devel", "boost-doc", "libmthca-rdmav2", "libcxgb3-rdmav2", "libcxgb4-rdmav2",
                        "libmlx4-rdmav2", "libibverbs1", "libibmad1", "libibumad1", "libibcommon1", "ofed", "ofa", "libibdm1", "libibcm1", "libibnetdisc5",
                        "scsi-target-utils", "rdma-ofa-agent", "libibumad3", "libibmad5", "libibverbs-runtime", "librdmacm1"
                        );

my @mlnx_en_packages = (
                       "mlnx_en", "mlnx-en-devel", "mlnx_en-devel", "mlnx_en-doc", "mlnx-ofc", "mlnx-ofc-debuginfo"
                        );

# List of all available packages sorted following dependencies
my @kernel_packages = ("compat-rdma", "compat-rdma-devel", "ib-bonding", "ib-bonding-debuginfo");
my @basic_kernel_modules = ("core", "mthca", "mlx4", "mlx4_en", "mlx5", "cxgb3", "cxgb4", "nes", "ehca", "qib", "ocrdma", "ipoib");
my @ulp_modules = ("sdp", "srp", "srpt", "rds", "qlgc_vnic", "iser", "nfsrdma", "cxgb3i", "cxgb4i");
my @xeon_phi_kernel = ("ibscif", "ibp-server", "ibp-debug");

# kernel modules in "technology preview" status can be installed by
# adding "module=y" to the ofed.conf file in unattended installation mode
# or by selecting the module in custom installation mode during interactive installation
my @tech_preview;

my @kernel_modules = (@basic_kernel_modules, @ulp_modules);

my $kernel_configure_options = '';
my $user_configure_options = '';

my @misc_packages = ("ofed-docs", "ofed-scripts");

my @xeon_phi_user = ("ibpd", "libibscif");
my @non_xeon_phi_user = ("infinipath-psm", "infinipath-psm-devel");

my @user_packages = ("rdma-core",
                     "libibmad", "libibmad-devel", "libibmad-static", "libibmad-debuginfo",
                     "ibsim", "ibsim-debuginfo",
                     "opensm", "opensm-libs", "opensm-devel", "opensm-debuginfo", "opensm-static",
                     "compat-dapl", "compat-dapl-devel",
                     "dapl", "dapl-devel", "dapl-devel-static", "dapl-utils", "dapl-debuginfo",
                     "perftest", "mstflint", "libiwpm",
                     "qlvnictools", "sdpnetstat", "srptools", "rds-tools", "rds-devel",
                     "ibutils", "infiniband-diags", "qperf", "qperf-debuginfo",
                     "ofed-docs", "ofed-scripts",
                     "libfabric", "libfabric-devel", "libfabric-debuginfo",
                     "fabtests", "fabtests-debuginfo"
                     );

my @basic_kernel_packages = ("compat-rdma");
my @basic_user_packages = ("rdma-core",
                            "libiwpm", "mstflint", @misc_packages);

my @hpc_kernel_packages = ("compat-rdma", "ib-bonding");
my @hpc_kernel_modules = (@basic_kernel_modules);

# all_packages is required to save ordered (following dependencies) list of
# packages. Hash does not saves the order
my @all_packages = (@kernel_packages, @user_packages);

my %kernel_modules_info = (
        'core' =>
            { name => "core", available => 1, selected => 0,
            included_in_rpm => 0, requires => [], },
        'mthca' =>
            { name => "mthca", available => 0, selected => 0,
            included_in_rpm => 0, requires => ["core"], },
        'mlx4' =>
            { name => "mlx4", available => 1, selected => 0,
            included_in_rpm => 0, requires => ["core"], },
        'mlx5' =>
            { name => "mlx5", available => 1, selected => 0,
            included_in_rpm => 0, requires => ["core"], },
        'mlx4_en' =>
            { name => "mlx4_en", available => 1, selected => 0,
            included_in_rpm => 0, requires => ["core","mlx4"], },
        'ehca' =>
            { name => "ehca", available => 0, selected => 0,
            included_in_rpm => 0, requires => ["core"], },
        'ipath' =>
            { name => "ipath", available => 0, selected => 0,
            included_in_rpm => 0, requires => ["core"], },
        'qib' =>
            { name => "qib", available => 0, selected => 0,
            included_in_rpm => 0, requires => ["core"], },
        'cxgb3' =>
            { name => "cxgb3", available => 1, selected => 0,
            included_in_rpm => 0, requires => ["core"], },
        'cxgb4' =>
            { name => "cxgb4", available => 1, selected => 0,
            included_in_rpm => 0, requires => ["core"], },
        'cxgb3i' =>
            { name => "cxgb3i", available => 0, selected => 0,
            included_in_rpm => 0, requires => ["core"], },
        'cxgb4i' =>
            { name => "cxgb4i", available => 0, selected => 0,
            included_in_rpm => 0, requires => ["core"], },
        'nes' =>
            { name => "nes", available => 1, selected => 0,
            included_in_rpm => 0, requires => ["core"], },
        'ocrdma' =>
            { name => "ocrdma", available => 0, selected => 0,
            included_in_rpm => 0, requires => ["core"], },
        'ipoib' =>
            { name => "ipoib", available => 1, selected => 0,
            included_in_rpm => 0, requires => ["core"], },
        'sdp' =>
            { name => "sdp", available => 0, selected => 0,
            included_in_rpm => 0, requires => ["core", "ipoib"], },
        'srp' =>
            { name => "srp", available => 1, selected => 0,
            included_in_rpm => 0, requires => ["core", "ipoib"], },
        'srpt' =>
            { name => "srpt", available => 0, selected => 0,
            included_in_rpm => 0, requires => ["core"], },
        'rds' =>
            { name => "rds", available => 0, selected => 0,
            included_in_rpm => 0, requires => ["core", "ipoib"], },
        'iser' =>
            { name => "iser", available => 1, selected => 0,
            included_in_rpm => 0, requires => ["core", "ipoib"], ofa_req_inst => [] },
        'qlgc_vnic' =>
            { name => "qlgc_vnic", available => 0, selected => 0,
            included_in_rpm => 0, requires => ["core"], },
        'nfsrdma' =>
            { name => "nfsrdma", available => 0, selected => 0,
            included_in_rpm => 0, requires => ["core", "ipoib"], },
        'ibscif' =>
            { name => "ibscif", available => 1, selected => 0,
            included_in_rpm => 0, requires => ["core"],
            dist_req_build => ["/lib/modules/$kernel/scif.symvers"], },
        'ibp-server' =>
            { name => "ibp-server", available => 1, selected => 0,
            included_in_rpm => 0, requires => ["core"], },
        'ibp-debug' =>
            { name => "ibp-debug", available => 1, selected => 0,
            included_in_rpm => 0, requires => ["core", "ibp-server"], },
        );

my %packages_info = (
        # Kernel packages
        'compat-rdma' =>
            { name => "compat-rdma", parent => "compat-rdma",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "kernel", dist_req_build => ["make", "gcc"],
            dist_req_inst => [], ofa_req_build => [], ofa_req_inst => ["ofed-scripts"], configure_options => '' },
        'compat-rdma' =>
            { name => "compat-rdma", parent => "compat-rdma",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "kernel", dist_req_build => ["make", "gcc"],
            dist_req_inst => ["pciutils"], ofa_req_build => [], ofa_req_inst => ["ofed-scripts"], },
        'compat-rdma-devel' =>
            { name => "compat-rdma-devel", parent => "compat-rdma",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "kernel", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => ["compat-rdma"], },
        'ib-bonding' =>
            { name => "ib-bonding", parent => "ib-bonding",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "kernel", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [], ofa_req_inst => [], configure_options => '' },
        'ib-bonding-debuginfo' =>
            { name => "ib-bonding-debuginfo", parent => "ib-bonding",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "kernel", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [], ofa_req_inst => [], },
        # User space libraries
        'rdma-core' =>
            { name => "rdma-core", parent => "rdma-core",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user",
            dist_req_build =>
            ($build32 == 1 )?["$cmake", "$ninja", "$pkgconfig", "$gcc", "$glibc_devel$suffix_64bit","$glibc_devel$suffix_32bit","$libgcc","$libgcc"."$suffix_32bit", "$libnl_devel"."$suffix_64bit", ($DISTRO =~ /SUSE/)?"$libnl_devel"."$suffix_32bit":(($arch =~ /ppc/)?"$libnl_devel":"$libnl_devel.$target_cpu32")]:["$cmake", "$ninja", "$pkgconfig","$gcc","$glibc_devel$suffix_64bit","$libgcc", "$libnl_devel"."$suffix_64bit"],
            dist_req_inst => ( $build32 == 1 )?["$pkgconfig","$libnl"."$suffix_64bit", ($dist_rpm !~ /sles-release-11.1/)?"$libnl"."$suffix_32bit":"$libnl.$target_cpu32"]:["$pkgconfig","$libnl"."$suffix_64bit"] ,
            ofa_req_build => [],
            ofa_req_inst => ["ofed-scripts"],
            install32 => 1, exception => 0 },
        'libfabric' =>
            { name => "libfabric", parent => "libfabric",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => ["$libnl_devel"],
            dist_req_inst => [], ofa_req_build => ["rdma-core"],
            ofa_req_inst => ["rdma-core"],
            install32 => 1, exception => 0, configure_options => '' },
        'libfabric-devel' =>
            { name => "libfabric-devel", parent => "libfabric",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libfabric"],
            ofa_req_inst => ["libfabric"],
            install32 => 1, exception => 0 },
        'libfabric-debuginfo' =>
            { name => "libfabric-debuginfo", parent => "libfabric",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libfabric"],
            ofa_req_inst => ["libfabric"],
            install32 => 0, exception => 0 },

        'fabtests' =>
            { name => "fabtests", parent => "fabtests",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libfabric-devel"],
            ofa_req_inst => ["libfabric"],
            install32 => 1, exception => 0, configure_options => '' },
        'fabtests-debuginfo' =>
            { name => "fabtests-debuginfo", parent => "fabtests",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["fabtests"],
            ofa_req_inst => ["fabtests"],
            install32 => 0, exception => 0 },

        # Management
        'libibmad' =>
            { name => "libibmad", parent => "libibmad",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => ["libtool"],
            dist_req_inst => [],ubuntu_dist_req_build => ["libtool"],ubuntu_dist_req_inst => [], ofa_req_build => ["rdma-core"],
            ofa_req_inst => ["rdma-core"],
            install32 => 1, exception => 0, configure_options => '' },
        'libibmad-devel' =>
            { name => "libibmad-devel", parent => "libibmad",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["rdma-core"],
            ofa_req_inst => ["libibmad", "rdma-core"],
            install32 => 1, exception => 0 },
        'libibmad-static' =>
            { name => "libibmad-static", parent => "libibmad",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["rdma-core"],
            ofa_req_inst => ["libibmad", "rdma-core"],
            install32 => 1, exception => 0 },
        'libibmad-debuginfo' =>
            { name => "libibmad-debuginfo", parent => "libibmad",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["rdma-core"],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'libibscif' =>
            { name => "libibscif", parent => "libibscif",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [],ubuntu_dist_req_build => [],
            ubuntu_dist_req_inst => [], ofa_req_build => ["rdma-core"],
            ofa_req_inst => ["rdma-core"],
            install32 => 1, exception => 0, configure_options => '' },
        'libibscif-devel' =>
            { name => "libibscif-devel", parent => "libibscif",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["rdma-core"],
            ofa_req_inst => ["rdma-core", "libibscif"],
            install32 => 1, exception => 0 },

        'ibpd' =>
            { name => "ibpd", parent => "ibpd",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [],ubuntu_dist_req_build => [],
            ubuntu_dist_req_inst => [], ofa_req_build => ["rdma-core"],
            ofa_req_inst => ["rdma-core"],
            install32 => 1, exception => 0, configure_options => '' },

        'opensm' =>
            { name => "opensm", parent => "opensm",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => ["bison", "flex"],
            dist_req_inst => [],ubuntu_dist_req_build => ["bison", "flex"],ubuntu_dist_req_inst => [], ofa_req_build => ["rdma-core"],
            ofa_req_inst => ["opensm-libs"],
            install32 => 0, exception => 0, configure_options => '' },
        'opensm-devel' =>
            { name => "opensm-devel", parent => "opensm",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["rdma-core"],
            ofa_req_inst => ["rdma-core", "opensm-libs"],
            install32 => 1, exception => 0 },
        'opensm-libs' =>
            { name => "opensm-libs", parent => "opensm",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => ["bison", "flex"],
            dist_req_inst => [],ubuntu_dist_req_build => ["bison", "flex"],ubuntu_dist_req_inst => [], ofa_req_build => ["rdma-core"],
            ofa_req_inst => ["rdma-core"],
            install32 => 1, exception => 0 },
        'opensm-static' =>
            { name => "opensm-static", parent => "opensm",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["rdma-core"],
            ofa_req_inst => ["rdma-core", "opensm-libs"],
            install32 => 1, exception => 0 },
        'opensm-debuginfo' =>
            { name => "opensm-debuginfo", parent => "opensm",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["rdma-core"],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'ibsim' =>
            { name => "ibsim", parent => "ibsim",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["rdma-core", "libibmad-devel"],
            ofa_req_inst => ["rdma-core", "libibmad"],
            install32 => 0, exception => 0, configure_options => '' },
        'ibsim-debuginfo' =>
            { name => "ibsim-debuginfo", parent => "ibsim",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["rdma-core", "libibmad-devel"],
            ofa_req_inst => [],
            install32 => 0, exception => 0, configure_options => '' },
        'perftest' =>
            { name => "perftest", parent => "perftest",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["rdma-core"],
            ofa_req_inst => ["rdma-core"],
            install32 => 0, exception => 0, configure_options => '' },
        'perftest-debuginfo' =>
            { name => "perftest-debuginfo", parent => "perftest",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'mstflint' =>
            { name => "mstflint", parent => "mstflint",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user",
            dist_req_build => ["zlib-devel$suffix_64bit", "$libstdc_devel$suffix_64bit", "gcc-c++"],
            dist_req_inst => [], ofa_req_build => ["libibmad-devel"],
            ubuntu_dist_req_build => ["zlib1g-dev", "$libstdc_devel", "gcc","g++","byacc"],ubuntu_dist_req_inst => [],
            ofa_req_inst => ["libibmad"],
            install32 => 0, exception => 0, configure_options => '' },
        'mstflint-debuginfo' =>
            { name => "mstflint-debuginfo", parent => "mstflint",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'ibvexdmtools' =>
            { name => "ibvexdmtools", parent => "qlvnictools",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["rdma-core"],
            ofa_req_inst => ["rdma-core"],
            install32 => 0, exception => 0, configure_options => '' },
        'qlgc_vnic_daemon' =>
            { name => "qlgc_vnic_daemon", parent => "qlvnictools",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0, configure_options => '' },
        'qlvnictools' =>
            { name => "qlvnictools", parent => "qlvnictools",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["rdma-core"],
            ofa_req_inst => ["ibvexdmtools", "qlgc_vnic_daemon", "rdma-core"],
            install32 => 0, exception => 0, configure_options => '' },
        'qlvnictools-debuginfo' =>
            { name => "qlvnictools-debuginfo", parent => "qlvnictools",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'rnfs-utils' =>
            { name => "rnfs-utils", parent => "rnfs-utils",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0, configure_options => '' },
        'rnfs-utils-debuginfo' =>
            { name => "rnfs-utils-debuginfo", parent => "rnfs-utils",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'rds-tools' =>
            { name => "rds-tools", parent => "rds-tools",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0, configure_options => '' },
        'rds-devel' =>
            { name => "rds-devel", parent => "rds-tools",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => ["rds-tools"],
            install32 => 0, exception => 0, configure_options => '' },
        'rds-tools-debuginfo' =>
            { name => "rds-tools-debuginfo", parent => "rds-tools",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'qperf' =>
            { name => "qperf", parent => "qperf",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["rdma-core"],
            ofa_req_inst => ["rdma-core"],
            install32 => 0, exception => 0, configure_options => '' },
        'qperf-debuginfo' =>
            { name => "qperf-debuginfo", parent => "qperf",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'ibutils' =>
            { name => "ibutils", parent => "ibutils",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => ["tcl__8.4", "tcl-devel__8.4", "tk", "$libstdc_devel"],
            dist_req_inst => ["tcl__8.4", "tk", "$libstdc"], ofa_req_build => ["rdma-core", "opensm-libs", "opensm-devel"],
            ofa_req_inst => ["rdma-core", "opensm-libs"],
            install32 => 0, exception => 0, configure_options => '' },
        'ibutils-debuginfo' =>
            { name => "ibutils-debuginfo", parent => "ibutils",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'infiniband-diags' =>
            { name => "infiniband-diags", parent => "infiniband-diags",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => ["glib2-devel", "$libudev_devel"],
            dist_req_inst => [], ofa_req_build => ["opensm-devel", "libibmad-devel", "rdma-core"],
            ofa_req_inst => ["libibumad", "libibmad", "opensm-libs"],
            install32 => 0, exception => 0, configure_options => '' },
        'infiniband-diags-debuginfo' =>
            { name => "infiniband-diags-debuginfo", parent => "infiniband-diags",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'compat-dapl' =>
            { name => "dapl", parent => "compat-dapl",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["rdma-core"],
            ofa_req_inst => ["rdma-core"],
            install32 => 1, exception => 0, configure_options => '' },
        'compat-dapl-devel' =>
            { name => "dapl-devel", parent => "compat-dapl",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["rdma-core"],
            ofa_req_inst => ["compat-dapl"],
            install32 => 1, exception => 0, configure_options => '' },
        'dapl' =>
            { name => "dapl", parent => "dapl",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["rdma-core"],
            ofa_req_inst => ["rdma-core"],
            install32 => 1, exception => 0, configure_options => '' },
        'dapl-devel' =>
            { name => "dapl-devel", parent => "dapl",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["rdma-core"],
            ofa_req_inst => ["dapl"],
            install32 => 1, exception => 0, configure_options => '' },
        'dapl-devel-static' =>
            { name => "dapl-devel-static", parent => "dapl",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["rdma-core"],
            ofa_req_inst => ["dapl"],
            install32 => 1, exception => 0, configure_options => '' },
        'dapl-utils' =>
            { name => "dapl-utils", parent => "dapl",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["rdma-core"],
            ofa_req_inst => ["dapl"],
            install32 => 0, exception => 0, configure_options => '' },
        'dapl-debuginfo' =>
            { name => "dapl-debuginfo", parent => "dapl",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["rdma-core"],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },


        'ofed-docs' =>
            { name => "ofed-docs", parent => "ofed-docs",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'ofed-scripts' =>
            { name => "ofed-scripts", parent => "ofed-scripts",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },
        );


my @hidden_packages = ("ibvexdmtools", "qlgc_vnic_daemon");

my $TOPDIR = $builddir . '/' . $PACKAGE . "_topdir";
chomp $TOPDIR;

rmtree ("$TOPDIR");
mkpath([$TOPDIR . '/BUILD' ,$TOPDIR . '/RPMS',$TOPDIR . '/SOURCES',$TOPDIR . '/SPECS',$TOPDIR . '/SRPMS']);

if ($config_given and $install_option) {
    print RED "\nError: '-c' option can't be used with '--all|--hpc|--basic'", RESET "\n";
    exit 1;
}

if ($config_given and not -e $config) {
    print RED "$config does not exist", RESET "\n";
    exit 1;
}

if (not $config_given and -e $config) {
    move($config, "$config.save");
}

if ($quiet) {
    $verbose = 0;
    $verbose2 = 0;
    $verbose3 = 0;
}

my %ifcfg = ();
if ($config_net_given and not -e $config_net) {
    print RED "$config_net does not exist", RESET "\n";
    exit 1;
}

my $eth_dev;
if ($config_net_given) {
    open(NET, "$config_net") or die "Can't open $config_net: $!";
    while (<NET>) {
        my ($param, $value) = split('=');
        chomp $param;
        chomp $value;
        my $dev = $param;
        $dev =~ s/(.*)_(ib[0-9]+)/$2/;
        chomp $dev;

        if ($param =~ m/IPADDR/) {
            $ifcfg{$dev}{'IPADDR'} = $value;
        }
        elsif ($param =~ m/NETMASK/) {
            $ifcfg{$dev}{'NETMASK'} = $value;
        }
        elsif ($param =~ m/NETWORK/) {
            $ifcfg{$dev}{'NETWORK'} = $value;
        }
        elsif ($param =~ m/BROADCAST/) {
            $ifcfg{$dev}{'BROADCAST'} = $value;
        }
        elsif ($param =~ m/ONBOOT/) {
            $ifcfg{$dev}{'ONBOOT'} = $value;
        }
        elsif ($param =~ m/LAN_INTERFACE/) {
            $ifcfg{$dev}{'LAN_INTERFACE'} = $value;
        }
        else {
            print RED "Unsupported parameter '$param' in $config_net\n" if ($verbose2);
        }
    }
    close(NET);
}

sub sig_handler
{
    exit 1;
}

sub getch
{
        my $c;
        system("stty -echo raw");
        $c=getc(STDIN);
        system("stty echo -raw");
        # Exit on Ctrl+c or Esc
        if ($c eq "\cC" or $c eq "\e") {
            print "\n";
            exit 1;
        }
        print "$c\n";
        return $c;
}

sub get_rpm_name_arch
{
    my $ret = `rpm --queryformat "[%{NAME}] [%{ARCH}]" -qp @_ | grep -v Freeing`;
    chomp $ret;
    return $ret;
}

sub get_rpm_ver
{
    my $ret = `rpm --queryformat "[%{VERSION}]\n" -qp @_ | uniq`;
    chomp $ret;
    return $ret;
}

sub get_rpm_rel
{
    my $ret = `rpm --queryformat "[%{RELEASE}]\n" -qp @_ | uniq`;
    chomp $ret;
    return $ret;
}

# Get RPM name and version of the INSTALLED package
sub get_rpm_ver_inst
{
    my $ret;
    if ($DISTRO =~ /DEBIAN|UBUNTU/) {
        $ret = `dpkg-query -W -f='\${Version}\n' @_ | cut -d ':' -f 2 | uniq`;
    }
    else {
        $ret = `rpm --queryformat '[%{VERSION}]\n' -q @_ | uniq`;
    }
    chomp $ret;
    return $ret;
}

sub get_rpm_rel_inst
{
    my $ret = `rpm --queryformat "[%{RELEASE}]\n" -q @_ | uniq`;
    chomp $ret;
    return $ret;
}

sub get_rpm_info
{
    my $ret = `rpm --queryformat "[%{NAME}] [%{VERSION}] [%{RELEASE}] [%{DESCRIPTION}]" -qp @_`;
    chomp $ret;
    return $ret;
}

sub supported32bit
{
    if ($arch =~ /i[0-9]86|ia64/) {
        return 0;
    }
    return 1
}

sub set_cfg
{
    my $srpm_full_path = shift @_;

    my $info = get_rpm_info($srpm_full_path);
    my $name = (split(/ /,$info,4))[0];
    my $version = (split(/ /,$info,4))[1];

    ( $main_packages{$name}{'name'},
      $main_packages{$name}{'version'},
      $main_packages{$name}{'release'},
      $main_packages{$name}{'description'} ) = split(/ /,$info,4);
      $main_packages{$name}{'srpmpath'}   = $srpm_full_path;

    print "set_cfg: " .
             "name: $name, " .
             "original name: $main_packages{$name}{'name'}, " .
             "version: $main_packages{$name}{'version'}, " .
             "release: $main_packages{$name}{'release'}, " .
             "srpmpath: $main_packages{$name}{'srpmpath'}\n" if ($verbose3);

}

# Set packages availability depending OS/Kernel/arch
sub set_availability
{
    if ($kernel =~ m/^4\.8/) {
            $kernel_modules_info{'rds'}{'available'} = 1;
            $packages_info{'rds-tools'}{'available'} = 1;
            $packages_info{'rds-devel'}{'available'} = 1;
            $packages_info{'rds-tools-debuginfo'}{'available'} = 1;
            $kernel_modules_info{'srpt'}{'available'} = 1;
    }
    # libfabric due to dependency on infinipath-psm
    if ($arch =~ m/x86_64/) {
        $packages_info{'libfabric'}{'ofa_req_build'} = ["rdma-core"];
        $packages_info{'libfabric'}{'ofa_req_inst'} = ["rdma-core"];
    }

    # require numa stuff where supported inbox
    if ($DISTRO =~ /RHEL|OEL|FC|POWERKVM/) {
        push(@{$packages_info{'rdma-core'}{'dist_req_build'}}, "numactl-devel$suffix_64bit");
        push(@{$packages_info{'rdma-core'}{'dist_req_build'}}, "numactl-devel$suffix_32bit") if ($build32 == 1);

        my $numactl = "numactl";
        if ($DISTRO =~ /FC19|FC[2-9]|OEL[7-9]|RHEL[7-9]|POWERKVM/) {
            $numactl = "numactl-libs";
        }
        push(@{$packages_info{'rdma-core'}{'dist_req_inst'}}, "${numactl}${suffix_64bit}");
        push(@{$packages_info{'rdma-core'}{'dist_req_inst'}}, "${numactl}${suffix_32bit}") if ($build32 == 1);
    }

    # Disable SRP on ppc64 platform to avoid update of scsi_transport_srp kernel module
    # which will prevent in-box ibmvscsi module load and, as a result, kernel panic upon boot
    if ($arch =~ m/ppc64/) {
        $kernel_modules_info{'srp'}{'available'} = 0;
    }

    # debuginfo RPM currently are not supported on SuSE
    if ($DISTRO =~ m/SLES/ or $DISTRO eq 'DEBIAN') {
        for my $package (@all_packages) {
            if ($package =~ m/-debuginfo/) {
                $packages_info{$package}{'available'} = 0;
            }
        }
    }

    for my $key ( keys %disabled_packages ) {
        if (exists $packages_info{$key}) {
            $packages_info{$key}{'available'} = 0;
        } elsif (exists $kernel_modules_info{$key}) {
            $kernel_modules_info{$key}{'available'} = 0;
        }
    }
}

# Set rpm_exist parameter for existing RPMs
sub set_existing_rpms
{
    # Check if the ofed-scripts RPM exist and its prefix is the same as required one
    my $scr_rpm = '';
    $scr_rpm = <$RPMS/ofed-scripts-*.$target_cpu.rpm>;
    if ( -f $scr_rpm ) {
        my $current_prefix = `rpm -qlp $scr_rpm | grep ofed_info | sed -e "s@/bin/ofed_info@@"`;
        chomp $current_prefix;
        print "Found $scr_rpm. Its installation prefix: $current_prefix\n" if ($verbose2);
        if (not $current_prefix eq $prefix) {
            print "Required prefix is: $prefix\n" if ($verbose2);
            print "Going to rebuild RPMs from scratch\n" if ($verbose2);
            return;
        }
    }

    for my $binrpm ( <$RPMS/*.rpm> ) {
        my ($rpm_name, $rpm_arch) = (split ' ', get_rpm_name_arch($binrpm));
        $main_packages{$rpm_name}{'rpmpath'}   = $binrpm;
        if ($rpm_name =~ /compat-rdma|ib-bonding/) {
            if (($rpm_arch eq $target_cpu) and (get_rpm_rel($binrpm) =~ /$kernel_rel/)) {
                $packages_info{$rpm_name}{'rpm_exist'} = 1;
                print "$rpm_name RPM exist\n" if ($verbose2);
            }
        }
        else {
            if ($rpm_arch eq $target_cpu) {
                $packages_info{$rpm_name}{'rpm_exist'} = 1;
                print "$rpm_name RPM exist\n" if ($verbose2);
            }
            elsif ($rpm_arch eq $target_cpu32) {
                $packages_info{$rpm_name}{'rpm_exist32'} = 1;
                print "$rpm_name 32-bit RPM exist\n" if ($verbose2);
            }
        }
    }
}

sub show_menu
{
    my $menu = shift @_;
    my $max_inp;

    print $clear_string;
    if ($menu eq "main") {
        print "$PACKAGE Distribution Software Installation Menu\n\n";
        print "   1) View $PACKAGE Installation Guide\n";
        print "   2) Install $PACKAGE Software\n";
        print "   3) Show Installed Software\n";
        print "   4) Configure IPoIB\n";
        print "   5) Uninstall $PACKAGE Software\n";
#        print "   6) Generate Supporting Information for Problem Report\n";
        print "\n   Q) Exit\n";
        $max_inp=5;
        print "\nSelect Option [1-$max_inp]:"
    }
    elsif ($menu eq "select") {
        print "$PACKAGE Distribution Software Installation Menu\n\n";
        print "   1) Basic ($PACKAGE modules and basic user level libraries)\n";
        print "   2) All packages (all of Basic, HPC)\n";
        print "   3) Customize\n";
        print "\n   Q) Exit\n";
        $max_inp=3;
        print "\nSelect Option [1-$max_inp]:"
    }

    return $max_inp;
}

# Select package for installation
sub select_packages
{
    my $cnt = 0;
    if ($interactive) {
        open(CONFIG, ">$config") || die "Can't open $config: $!";;
        flock CONFIG, $LOCK_EXCLUSIVE;
        my $ok = 0;
        my $inp;
        my $max_inp;
        while (! $ok) {
            $max_inp = show_menu("select");
            $inp = getch();
            if ($inp =~ m/[qQ]/ || $inp =~ m/[Xx]/ ) {
                die "Exiting\n";
            }
            if (ord($inp) == $KEY_ENTER) {
                next;
            }
            if ($inp =~ m/[0123456789abcdefABCDEF]/)
            {
                $inp = hex($inp);
            }
            if ($inp < 1 || $inp > $max_inp)
            {
                print "Invalid choice...Try again\n";
                next;
            }
            $ok = 1;
        }
        if ($inp == $BASIC) {
            for my $package (@basic_user_packages, @basic_kernel_packages) {
                next if (not $packages_info{$package}{'available'});
                my $parent = $packages_info{$package}{'parent'};
                next if (not $main_packages{$parent}{'srpmpath'});
                push (@selected_by_user, $package);
                print CONFIG "$package=y\n";
                $cnt ++;
            }
            for my $module ( @basic_kernel_modules ) {
                next if (not $kernel_modules_info{$module}{'available'});
                push (@selected_modules_by_user, $module);
                print CONFIG "$module=y\n";
            }
        }
        elsif ($inp == $ALL) {
            for my $package ( @all_packages, @hidden_packages ) {
                next if (not $packages_info{$package}{'available'});
                my $parent = $packages_info{$package}{'parent'};
                next if (not $main_packages{$parent}{'srpmpath'});
                push (@selected_by_user, $package);
                print CONFIG "$package=y\n";
                $cnt ++;
            }
            for my $module ( @kernel_modules ) {
                next if (not $kernel_modules_info{$module}{'available'});
                push (@selected_modules_by_user, $module);
                print CONFIG "$module=y\n";
            }
        }
        elsif ($inp == $CUSTOM) {
            my $ans;
            for my $package ( @all_packages ) {
                next if (not $packages_info{$package}{'available'});
                my $parent = $packages_info{$package}{'parent'};
                next if (not $main_packages{$parent}{'srpmpath'});
                print "Install $package? [y/N]:";
                $ans = getch();
                if ( $ans eq 'Y' or $ans eq 'y' ) {
                    print CONFIG "$package=y\n";
                    push (@selected_by_user, $package);
                    $cnt ++;

                    if ($package eq "compat-rdma") {
                        # Select kernel modules to be installed
                        for my $module ( @kernel_modules, @tech_preview ) {
                            next if (not $kernel_modules_info{$module}{'available'});
                            print "Install $module module? [y/N]:";
                            $ans = getch();
                            if ( $ans eq 'Y' or $ans eq 'y' ) {
                                push (@selected_modules_by_user, $module);
                                print CONFIG "$module=y\n";
                            }
                        }
                    }
                }
                else {
                    print CONFIG "$package=n\n";
                }
            }
            if ($arch eq "x86_64" or $arch eq "ppc64") {
                if (supported32bit()) {
                    print "Install 32-bit packages? [y/N]:";
                    $ans = getch();
                    if ( $ans eq 'Y' or $ans eq 'y' ) {
                        $build32 = 1;
                        print CONFIG "build32=1\n";
                    }
                    else {
                        $build32 = 0;
                        print CONFIG "build32=0\n";
                    }
                }
                else {
                    $build32 = 0;
                    print CONFIG "build32=0\n";
                }
            }
            print "Please enter the $PACKAGE installation directory: [$prefix]:";
            $ans = <STDIN>;
            chomp $ans;
            if ($ans) {
                $prefix = $ans;
                $prefix =~ s/\/$//;
            }
            print CONFIG "prefix=$prefix\n";
        }
        flock CONFIG, $UNLOCK;
    }
    else {
        if ($config_given) {
            open(CONFIG, "$config") || die "Can't open $config: $!";
            while(<CONFIG>) {
                next if (m@^\s+$|^#.*@);
                my ($package,$selected) = (split '=', $_);
                chomp $package;
                chomp $selected;

                print "$package=$selected\n" if ($verbose3);

                if ($package eq "build32") {
                    if (supported32bit()) {
                        $build32 = 1 if ($selected);
                    }
                    next;
                }

                if ($package eq "prefix") {
                    $prefix = $selected;
                    $prefix =~ s/\/$//;
                    next;
                }

                if ($package eq "bonding_force_all_os") {
                    if ($selected =~ m/[Yy]|[Yy][Ee][Ss]/) {
                        $bonding_force_all_os = 1;
                    }
                    next;
                }

                if (substr($package,0,length("vendor_config")) eq "vendor_config") {
                    next;
                }

               if ($package eq "vendor_pre_install") {
                   	if ( -f $selected ) {
                        $vendor_pre_install = dirname($selected) . '/' . basename($selected);
                    } else {
                        print RED "\nVendor script $selected is not found", RESET "\n" if (not $quiet);
                        exit 1
                    }
                    next;
                }

                if ($package eq "vendor_post_install") {
		            if ( -f $selected ) {
			            $vendor_post_install = dirname($selected) . '/' . basename($selected);
		            } else {
			            print RED "\nVendor script $selected is not found", RESET "\n" if (not $quiet);
			            exit 1
		            }
                    next;
                }

                if ($package eq "vendor_pre_uninstall") {
                    if ( -f $selected ) {
                        $vendor_pre_uninstall = dirname($selected) . '/' . basename($selected);
                    } else {
                        print RED "\nVendor script $selected is not found", RESET "\n" if (not $quiet);
                        exit 1
                    }
                    next;
                }

                if ($package eq "vendor_post_uninstall") {
                    if ( -f $selected ) {
                        $vendor_post_uninstall = dirname($selected) . '/' . basename($selected);
                    } else {
                        print RED "\nVendor script $selected is not found", RESET "\n" if (not $quiet);
                        exit 1
                    }
                    next;
                }

                if ($package eq "kernel_configure_options" or $package eq "OFA_KERNEL_PARAMS") {
                    $kernel_configure_options = $selected;
                    next;
                }

                if ($package eq "user_configure_options") {
                    $user_configure_options = $selected;
                    next;
                }

                if ($package =~ m/configure_options/) {
                    my $pack_name = (split '_', $_)[0];
                    $packages_info{$pack_name}{'configure_options'} = $selected;
                    next;
                }

                if (not $packages_info{$package}{'parent'}) {
                    my $modules = "@kernel_modules @tech_preview";
                    chomp $modules;
                    $modules =~ s/ /|/g;
                    if ($package =~ m/$modules/) {
                        if ( $selected eq 'y' ) {
                            if (not $kernel_modules_info{$package}{'available'}) {
                                print "$package is not available on this platform\n" if (not $quiet);
                            }
                            else {
                                push (@selected_modules_by_user, $package);
                            }
                            next;
                        }
                    }
                    else {
                       print "Unsupported package: $package\n" if (not $quiet);
                       next;
                    }
                }

                if (not $packages_info{$package}{'available'} and $selected eq 'y') {
                    print "$package is not available on this platform\n" if (not $quiet);
                    next;
                }

                if ( $selected eq 'y' ) {
                    my $parent = $packages_info{$package}{'parent'};
                    if (not $main_packages{$parent}{'srpmpath'}) {
                        print "Unsupported package: $package\n" if (not $quiet);
                        next;
                    }
                    push (@selected_by_user, $package);
                    print "select_package: selected $package\n" if ($verbose2);
                    $cnt ++;
                }
            }
        }
        else {
            open(CONFIG, ">$config") || die "Can't open $config: $!";
            flock CONFIG, $LOCK_EXCLUSIVE;
            if ($install_option eq 'all') {
                for my $package ( @all_packages ) {
                    next if (not $packages_info{$package}{'available'});
                    my $parent = $packages_info{$package}{'parent'};
                    next if (not $main_packages{$parent}{'srpmpath'});
                    push (@selected_by_user, $package);
                    print CONFIG "$package=y\n";
                    $cnt ++;
                }
                for my $module ( @kernel_modules ) {
                    next if (not $kernel_modules_info{$module}{'available'});
                    push (@selected_modules_by_user, $module);
                    print CONFIG "$module=y\n";
                }
            }
            elsif ($install_option eq 'basic') {
                for my $package (@basic_user_packages, @basic_kernel_packages) {
                    next if (not $packages_info{$package}{'available'});
                    my $parent = $packages_info{$package}{'parent'};
                    next if (not $main_packages{$parent}{'srpmpath'});
                    push (@selected_by_user, $package);
                    print CONFIG "$package=y\n";
                    $cnt ++;
                }
                for my $module ( @basic_kernel_modules ) {
                    next if (not $kernel_modules_info{$module}{'available'});
                    push (@selected_modules_by_user, $module);
                    print CONFIG "$module=y\n";
                }
            }
            else {
                print RED "\nUnsupported installation option: $install_option", RESET "\n" if (not $quiet);
                exit 1;
            }
        }

        flock CONFIG, $UNLOCK;
    }
    close(CONFIG);


    return $cnt;
}

sub module_in_rpm
{
    my $module = shift @_;
    my $ret = 1;

    my $name = 'compat-rdma';
    my $version = $main_packages{$packages_info{$name}{'parent'}}{'version'};
    my $release = $main_packages{$name}{'release'} . '.' . $kernel_rel;

    my $package = "$RPMS/$name-$version-$release.$target_cpu.rpm";

    if (not -f $package) {
        print "is_module_in_rpm: $package not found\n";
        return 1;
    }

    if ($module eq "nfsrdma") {
        $module = "xprtrdma";
    }

    open(LIST, "rpm -qlp $package |") or die "Can't run 'rpm -qlp $package': $!\n";
    while (<LIST>) {
        if (/$module[a-z_]*.ko/) {
            print "is_module_in_rpm: $module $_\n" if ($verbose3);
            $ret = 0;
            last;
        }
    }
    close LIST;

    if ($ret) {
        print "$module not in $package\n" if ($verbose2);
    }

    return $ret;
}

sub mark_for_uninstall
{
    my $package = shift @_;
    if (not $selected_for_uninstall{$package}) {
        push (@dependant_packages_to_uninstall, "$package");
        $selected_for_uninstall{$package} = 1;
    }
}

sub get_requires
{
    my $package = shift @_;

    # Strip RPM version
    my $pname = `rpm -q --queryformat "[%{NAME}]" $package`;
    chomp $pname;

    my @what_requires = `/bin/rpm -q --whatrequires $pname 2> /dev/null | grep -v "no package requires" 2> /dev/null`;

    for my $pack_req (@what_requires) {
        chomp $pack_req;
        print "get_requires: $pname is required by $pack_req\n" if ($verbose2);
        get_requires($pack_req);
        mark_for_uninstall($pack_req);
    }
}

sub select_dependent
{
    my $package = shift @_;

    if ($package eq "infinipath-psm" and $with_xeon_phi) {
        $packages_info{$package}{'ofa_req_build'} = ["libibscif-devel"];
        $packages_info{$package}{'ofa_req_inst'} = ["libibscif"];
    }


    if ( (not $packages_info{$package}{'rpm_exist'}) or
         ($build32 and not $packages_info{$package}{'rpm_exist32'}) ) {
        for my $req ( @{ $packages_info{$package}{'ofa_req_build'} } ) {
            next if not $req;
            if ($packages_info{$req}{'available'} and not $packages_info{$req}{'selected'}) {
                print "resolve_dependencies: $package requires $req for rpmbuild\n" if ($verbose2);
                select_dependent($req);
            }
        }
    }

    for my $req ( @{ $packages_info{$package}{'ofa_req_inst'} } ) {
        next if not $req;
        if ($packages_info{$req}{'available'} and not $packages_info{$req}{'selected'}) {
            print "resolve_dependencies: $package requires $req for rpm install\n" if ($verbose2);
            select_dependent($req);
        }
    }

    if (not $packages_info{$package}{'selected'}) {
        return if (not $packages_info{$package}{'available'});
        # Assume that the requirement is not strict.
        my $parent = $packages_info{$package}{'parent'};
        return if (not $main_packages{$parent}{'srpmpath'});
        $packages_info{$package}{'selected'} = 1;
        push (@selected_packages, $package);
        print "select_dependent: Selected package $package\n" if ($verbose2);
    }

}

sub select_dependent_module
{
    my $module = shift @_;

    for my $req ( @{ $kernel_modules_info{$module}{'requires'} } ) {
        print "select_dependent_module: $module requires $req for rpmbuild\n" if ($verbose2);
        if (not $kernel_modules_info{$req}{'selected'}) {
            select_dependent_module($req);
        }
    }
    if (not $kernel_modules_info{$module}{'selected'}) {
        $kernel_modules_info{$module}{'selected'} = 1;
        push (@selected_kernel_modules, $module);
        print "select_dependent_module: Selected module $module\n" if ($verbose2);
    }
}

sub resolve_dependencies
{
    for my $package ( @selected_by_user ) {
            # Get the list of dependencies
            select_dependent($package);
    }

    for my $module ( @selected_modules_by_user ) {
        select_dependent_module($module);
    }

    if ($packages_info{'compat-rdma'}{'rpm_exist'}) {
        for my $module (@selected_kernel_modules) {
            if (module_in_rpm($module)) {
                $packages_info{'compat-rdma'}{'rpm_exist'} = 0;
                last;
            }
        }
    }
}

sub check_linux_dependencies
{
    my $err = 0;
    my $p1 = 0;
    my $gcc_32bit_printed = 0;
    if (! $check_linux_deps) {
        return 0;
    }
    my $dist_req_build = ($DISTRO =~ m/UBUNTU/)?'ubuntu_dist_req_build':'dist_req_build';
    for my $package ( @selected_packages ) {
        # Check rpmbuild requirements
        if ($package =~ /compat-rdma/) {
            if (not $packages_info{$package}{'rpm_exist'}) {
                # Check that required kernel is supported
                if ($kernel !~ /2\.6\.3[0-9]|2\.6\.40|3\.[0-9]|3\.1[0-9]|4\.[0-8]/) {
                    print RED "Kernel $kernel is not supported.", RESET "\n";
                    print BLUE "For the list of Supported Platforms and Operating Systems see", RESET "\n";
                    print BLUE "$CWD/docs/OFED_release_notes.txt", RESET "\n";
                    exit 1;
                }
                # kernel sources required
                if ( not -d "$linux_obj/scripts" ) {
                    print RED "$linux_obj/scripts is required to build $package RPM.", RESET "\n";
                    print RED "Please install the corresponding kernel-source or kernel-devel RPM.", RESET "\n";
                    $err++;
                }
            }
        }

        if($DISTRO =~/UBUNTU/){
            if(not is_installed_deb("rpm")){
                print RED "rpm is required to build OFED", RESET "\n";
            }
        }

        if ($DISTRO =~ m/RHEL|FC/) {
            if (not is_installed("rpm-build")) {
                print RED "rpm-build is required to build OFED", RESET "\n";
                $err++;
            }
        }

        if ($package =~ /debuginfo/ and ($DISTRO =~ m/RHEL|FC/)) {
            if (not $packages_info{$package}{'rpm_exist'}) {
                if (not is_installed("redhat-rpm-config")) {
                    print RED "redhat-rpm-config rpm is required to build $package", RESET "\n";
                    $err++;
                }
            }
        }

        if (not $packages_info{$package}{'rpm_exist'}) {
            for my $req ( @{ $packages_info{$package}{$dist_req_build} } ) {
                my ($req_name, $req_version) = (split ('__',$req));
                next if not $req_name;
                print BLUE "check_linux_dependencies: $req_name  is required to build $package", RESET "\n" if ($verbose3);
                my $is_installed_flag = ($DISTRO =~ m/UBUNTU/)?(is_installed_deb($req_name)):(is_installed($req_name));
                if (not $is_installed_flag) {
                    print RED "$req_name rpm is required to build $package", RESET "\n";
                    $err++;
                }
                if ($req_version) {
                    my $inst_version = get_rpm_ver_inst($req_name);
                    print "check_linux_dependencies: $req_name installed version $inst_version, required at least $req_version\n" if ($verbose3);
                    if ($inst_version lt $req_version) {
                        print RED "$req_name-$req_version rpm is required to build $package", RESET "\n";
                        $err++;
                    }
                }
            }
                if ($package eq "compat-rdma") {
                    for my $module ( @selected_kernel_modules ) {
                        for my $req ( @{ $kernel_modules_info{$module}{'dist_req_build'} } ) {
                            if ((substr($req, 0, 1) eq "/" and not -f $req) or
                                (substr($req, 0, 1) ne "/" and not is_installed($req))) {
                                $err++;
                                print RED "$req is required to build $module", RESET "\n";
                            }
                        }
                    }
                }
                if ($build32) {
                    if (not -f "/usr/lib/crt1.o") {
                        if (! $p1) {
                            print RED "glibc-devel 32bit is required to build 32-bit libraries.", RESET "\n";
                            $p1 = 1;
                            $err++;
                        }
                    }
                    if ($DISTRO =~ m/SLES11/) {
                        if (not is_installed("gcc-32bit")) {
                            if (not $gcc_32bit_printed) {
                                print RED "gcc-32bit is required to build 32-bit libraries.", RESET "\n";
                                $gcc_32bit_printed++;
                                $err++;
                            }
                        }
                    }
                    if ($arch eq "ppc64") {
                        my @libstdc32 = </usr/lib/libstdc++.so.*>;
                        if ($package eq "mstflint") {
                            if (not scalar(@libstdc32)) {
                                print RED "$libstdc 32bit is required to build mstflint.", RESET "\n";
                                $err++;
                            }
                        }
                    }
                }
                if ($package eq "rnfs-utils") {
                    if (not is_installed("krb5-devel")) {
                        print RED "krb5-devel is required to build rnfs-utils.", RESET "\n";
                        $err++;
                    }
                    if ($DISTRO =~ m/RHEL|FC/) {
                        if (not is_installed("krb5-libs")) {
                            print RED "krb5-libs is required to build rnfs-utils.", RESET "\n";
                            $err++;
                        }
                        if (not is_installed("libevent-devel")) {
                            print RED "libevent-devel is required to build rnfs-utils.", RESET "\n";
                            $err++;
                        }
                        if (not is_installed("nfs-utils-lib-devel")) {
                            print RED "nfs-utils-lib-devel is required to build rnfs-utils.", RESET "\n";
                            $err++;
                        }
                        if (not is_installed("openldap-devel")) {
                            print RED "openldap-devel is required to build rnfs-utils.", RESET "\n";
                            $err++;
                        }
                    } else {
                    if ($DISTRO =~ m/SLES11/) {
                        if (not is_installed("libevent-devel")) {
                            print RED "libevent-devel is required to build rnfs-utils.", RESET "\n";
                            $err++;
                        }
                        if (not is_installed("nfsidmap-devel")) {
                            print RED "nfsidmap-devel is required to build rnfs-utils.", RESET "\n";
                            $err++;
                        }
                        if (not is_installed("libopenssl-devel")) {
                            print RED "libopenssl-devel is required to build rnfs-utils.", RESET "\n";
                            $err++;
                        }
                    } elsif ($DISTRO eq "SLES10") {
                        if (not is_installed("libevent")) {
                            print RED "libevent is required to build rnfs-utils.", RESET "\n";
                            $err++;
                        }
                        if (not is_installed("nfsidmap")) {
                            print RED "nfsidmap is required to build rnfs-utils.", RESET "\n";
                            $err++;
                        }
                    }
                    if (not is_installed("krb5")) {
                        print RED "krb5 is required to build rnfs-utils.", RESET "\n";
                        $err++;
                    }
                    if (not is_installed("openldap2-devel")) {
                        print RED "openldap2-devel is required to build rnfs-utils.", RESET "\n";
                        $err++;
                    }
                    if (not is_installed("cyrus-sasl-devel")) {
                        print RED "cyrus-sasl-devel is required to build rnfs-utils.", RESET "\n";
                        $err++;
                    }
                }
                        my $blkid_so = ($arch =~ m/x86_64/) ? "/usr/lib64/libblkid.so" : "/usr/lib/libblkid.so";
                        my $blkid_pkg = ($DISTRO =~ m/SLES10|RHEL5/) ? "e2fsprogs-devel" : "libblkid-devel";
                        $blkid_pkg .= ($arch =~ m/powerpc|ppc64/) ? "-32bit" : "";

                        if (not -e $blkid_so) {
                            print RED "$blkid_pkg is required to build rnfs-utils.", RESET "\n";
                            $err++;
                        }
                }
        }
        my $dist_req_inst = ($DISTRO =~ m/UBUNTU/)?'ubuntu_dist_req_inst':'dist_req_inst';
        # Check installation requirements
        for my $req ( @{ $packages_info{$package}{$dist_req_inst} } ) {
            my ($req_name, $req_version) = (split ('__',$req));
            next if not $req_name;
            my $is_installed_flag = ($DISTRO =~ m/UBUNTU/)?(is_installed_deb($req_name)):(is_installed($req_name));
            if (not $is_installed_flag) {
                print RED "$req_name rpm is required to install $package", RESET "\n";
                $err++;
            }
            if ($req_version) {
                my $inst_version = get_rpm_ver_inst($req_name);
                print "check_linux_dependencies: $req_name installed version $inst_version, required $req_version\n" if ($verbose3);
                if ($inst_version lt $req_version) {
                    print RED "$req_name-$req_version rpm is required to install $package", RESET "\n";
                    $err++;
                }
            }
        }
        if ($build32) {
            if (not -f "/usr/lib/crt1.o") {
                if (! $p1) {
                    print RED "glibc-devel 32bit is required to install 32-bit libraries.", RESET "\n";
                    $p1 = 1;
                    $err++;
                }
            }
            if ($arch eq "ppc64") {
                my @libstdc32 = </usr/lib/libstdc++.so.*>;
                if ($package eq "mstflint") {
                    if (not scalar(@libstdc32)) {
                        print RED "$libstdc 32bit is required to install mstflint.", RESET "\n";
                        $err++;
                    }
                }
            }
        }
    }
    if ($err) {
        exit 1;
    }
}

# Print the list of selected packages
sub print_selected
{
    print GREEN "\nBelow is the list of ${PACKAGE} packages that you have chosen
    \r(some may have been added by the installer due to package dependencies):\n", RESET "\n";
    for my $package ( @selected_packages ) {
        print "$package\n";
    }
    if ($build32) {
        print "32-bit binaries/libraries will be created\n";
    }
    print "\n";
}

sub build_kernel_rpm
{
    my $name = shift @_;
    my $cmd;
    my $res = 0;
    my $sig = 0;
    my $TMPRPMS;

    $cmd = "rpmbuild --rebuild $rpmbuild_flags --define '_topdir $TOPDIR'";

    if ($name eq 'compat-rdma') {
        $kernel_configure_options .= " $packages_info{'compat-rdma'}{'configure_options'}";

        for my $module ( @selected_kernel_modules ) {
            if ($module eq "core") {
                $kernel_configure_options .= " --with-core-mod --with-user_mad-mod --with-user_access-mod --with-addr_trans-mod";
            }
            elsif ($module eq "ipath") {
                $kernel_configure_options .= " --with-ipath_inf-mod";
            }
            elsif ($module eq "qib") {
                $kernel_configure_options .= " --with-qib-mod";
            }
            elsif ($module eq "srpt") {
                $kernel_configure_options .= " --with-srp-target-mod";
            }
            else {
                $kernel_configure_options .= " --with-$module-mod";
            }
        }

        if ($DISTRO eq "DEBIAN") {
                $kernel_configure_options .= " --without-modprobe";
        }

        # WA for Fedora C12
        if ($DISTRO =~ /FC12/) {
            $cmd .= " --define '__spec_install_pre %{___build_pre}'";
        }

        if ($DISTRO =~ /SLES11/) {
            $cmd .= " --define '_suse_os_install_post %{nil}'";
        }

        if ($DISTRO =~ /RHEL5/ and $target_cpu eq "i386") {
            $cmd .= " --define '_target_cpu i686'";
        }

        if ($DISTRO =~ /RHEL6.[34]/) {
            $cmd .= " --define '__find_provides %{nil}'";
        }
        $cmd .= " --nodeps";
        $cmd .= " --define '_dist .$rpm_distro'";
        $cmd .= " --define 'configure_options $kernel_configure_options'";
        $cmd .= " --define 'KVERSION $kernel'";
        $cmd .= " --define 'K_SRC $linux'";
        $cmd .= " --define 'K_SRC_OBJ $linux_obj'";
        $cmd .= " --define '_release $main_packages{'compat-rdma'}{'release'}.$kernel_rel'";
        $cmd .= " --define 'network_dir $network_dir'";
    }
    elsif ($name eq 'ib-bonding') {
        $cmd .= " --define 'KVERSION $kernel'";
        $cmd .= " --define '_release $kernel_rel'";
        $cmd .= " --define 'force_all_os $bonding_force_all_os'";
    }

    $cmd .= " --define '_prefix $prefix'";
    $cmd .= " --define '__arch_install_post %{nil}'";
    $cmd .= " $main_packages{$name}{'srpmpath'}";

    print "Running $cmd\n" if ($verbose);
    system("echo $cmd > $ofedlogs/$name.rpmbuild.log 2>&1");
    system("$cmd >> $ofedlogs/$name.rpmbuild.log 2>&1");
    $res = $? >> 8;
    $sig = $? & 127;
    if ($sig or $res) {
        print RED "Failed to build $name RPM", RESET "\n";
        print RED "See $ofedlogs/$name.rpmbuild.log", RESET "\n";
        exit 1;
    }

    $TMPRPMS = "$TOPDIR/RPMS/$target_cpu";
    chomp $TMPRPMS;

    print "TMPRPMS $TMPRPMS\n" if ($verbose2);

    for my $myrpm ( <$TMPRPMS/*.rpm> ) {
        print "Created $myrpm\n" if ($verbose2);
        system("/bin/rpm -qlp $myrpm | grep lib.modules | awk -F '/' '{print\$4}' | sort -u >> $RPMS/.supported_kernels");
        my ($myrpm_name, $myrpm_arch) = (split ' ', get_rpm_name_arch($myrpm));
        move($myrpm, $RPMS);
        $packages_info{$myrpm_name}{'rpm_exist'} = 1;
    }
}

sub build_rpm_32
{
    my $name = shift @_;
    my $parent = $packages_info{$name}{'parent'};
    my $cmd;
    my $res = 0;
    my $sig = 0;
    my $TMPRPMS;

    my $pref_env32;
    my $ldflags32;
    my $cflags32;
    my $cppflags32;
    my $cxxflags32;
    my $fflags32;
    my $ldlibs32;

    $ldflags32    .= " -m32 -g -O2 -L/usr/lib";
    $cflags32     .= " -m32 -g -O2";
    $cppflags32   .= " -m32 -g -O2";
    $cxxflags32   .= " -m32 -g -O2";
    $fflags32     .= " -m32 -g -O2";
    $ldlibs32     .= " -m32 -g -O2 -L/usr/lib";

    if ($prefix ne $default_prefix) {
        $ldflags32 .= " -L$prefix/lib";
        $cflags32 .= " -I$prefix/include";
        $cppflags32 .= " -I$prefix/include";
    }

    $pref_env32 .= " LDFLAGS='$ldflags32'";
    $pref_env32 .= " CFLAGS='$cflags32'";
    $pref_env32 .= " CPPFLAGS='$cppflags32'";
    $pref_env32 .= " CXXFLAGS='$cxxflags32'";
    $pref_env32 .= " FFLAGS='$fflags32'";
    $pref_env32 .= " LDLIBS='$ldlibs32'";

    $cmd = "$pref_env32 rpmbuild --rebuild $rpmbuild_flags --define '_topdir $TOPDIR'";
    $cmd .= " --target $target_cpu32";
    $cmd .= " --define '_prefix $prefix'";
    $cmd .= " --define 'dist %{nil}'";
    $cmd .= " --define '_exec_prefix $prefix'";
    $cmd .= " --define '_sysconfdir $sysconfdir'";
    $cmd .= " --define '_usr $prefix'";
    $cmd .= " --define '_lib lib'";
    $cmd .= " --define '__arch_install_post %{nil}'";

    if ($parent =~ m/dapl/) {
        my $def_doc_dir = `rpm --eval '%{_defaultdocdir}'`;
        chomp $def_doc_dir;
        $cmd .= " --define '_prefix $prefix'";
        $cmd .= " --define '_exec_prefix $prefix'";
        $cmd .= " --define '_sysconfdir $sysconfdir'";
        $cmd .= " --define '_defaultdocdir $def_doc_dir/$main_packages{$parent}{'name'}-$main_packages{$parent}{'version'}'";
        $cmd .= " --define '_usr $prefix'";
    }

    if ($DISTRO =~ m/SLES/) {
        $cmd .= " --define '_suse_os_install_post %{nil}'";
    }

    $cmd .= " $main_packages{$parent}{'srpmpath'}";

    print "Running $cmd\n" if ($verbose);
    open(LOG, "+>$ofedlogs/$parent.rpmbuild32bit.log");
    print LOG "Running $cmd\n";
    close LOG;
    system("$cmd >> $ofedlogs/$parent.rpmbuild32bit.log 2>&1");
    $res = $? >> 8;
    $sig = $? & 127;
    if ($sig or $res) {
        print RED "Failed to build $parent RPM", RESET "\n";
        print RED "See $ofedlogs/$parent.rpmbuild32bit.log", RESET "\n";
        exit 1;
    }

    $TMPRPMS = "$TOPDIR/RPMS/$target_cpu32";
    chomp $TMPRPMS;
    for my $myrpm ( <$TMPRPMS/*.rpm> ) {
        print "Created $myrpm\n" if ($verbose2);
        my ($myrpm_name, $myrpm_arch) = (split ' ', get_rpm_name_arch($myrpm));
        move($myrpm, $RPMS);
        $packages_info{$myrpm_name}{'rpm_exist32'} = 1;
    }
}

# Build RPM from source RPM
sub build_rpm
{
    my $name = shift @_;
    my $cmd;
    my $res = 0;
    my $sig = 0;
    my $TMPRPMS;

    my $ldflags;
    my $cflags;
    my $cppflags;
    my $cxxflags;
    my $fflags;
    my $ldlibs;
    my $parent = $packages_info{$name}{'parent'};
    my $srpmdir;
    my $srpmpath_for_distro;

    print "Build $name RPM\n" if ($verbose);

    my $pref_env = '';

    if (not $packages_info{$name}{'rpm_exist'}) {

        if ($arch eq "ppc64") {
            if ($DISTRO =~ m/SLES/ and $dist_rpm_rel gt 15.2) {
                # SLES 10 SP1
                if ($parent eq "ibutils") {
                    $packages_info{'ibutils'}{'configure_options'} .= " LDFLAGS=-L/usr/lib/gcc/powerpc64-suse-linux/4.1.2/64";
                }
                if ($parent eq "rds-tools" or $parent eq "rnfs-utils") {
                    $ldflags    = " -g -O2";
                    $cflags     = " -g -O2";
                    $cppflags   = " -g -O2";
                    $cxxflags   = " -g -O2";
                    $fflags     = " -g -O2";
                    $ldlibs     = " -g -O2";
                }
            }
            else {
                if ($parent =~ /rds-tools|rnfs-utils/) {
                    # Override compilation flags on RHEL 4.0 and 5.0 PPC64
                    $ldflags    = " -g -O2";
                    $cflags     = " -g -O2";
                    $cppflags   = " -g -O2";
                    $cxxflags   = " -g -O2";
                    $fflags     = " -g -O2";
                    $ldlibs     = " -g -O2";
                }
                elsif ($parent !~ /ibutils/) {
                    $ldflags    .= " $optflags -m64 -g -O2 -L/usr/lib64";
                    $cflags     .= " $optflags -m64 -g -O2";
                    $cppflags   .= " $optflags -m64 -g -O2";
                    $cxxflags   .= " $optflags -m64 -g -O2";
                    $fflags     .= " $optflags -m64 -g -O2";
                    $ldlibs     .= " $optflags -m64 -g -O2 -L/usr/lib64";
                }
            }
        }

        if ($ldflags) {
            $pref_env   .= " LDFLAGS='$ldflags'";
        }
        if ($cflags) {
            $pref_env   .= " CFLAGS='$cflags'";
        }
        if ($cppflags) {
            $pref_env   .= " CPPFLAGS='$cppflags'";
        }
        if ($cxxflags) {
            $pref_env   .= " CXXFLAGS='$cxxflags'";
        }
        if ($fflags) {
            $pref_env   .= " FFLAGS='$fflags'";
        }
        if ($ldlibs) {
            $pref_env   .= " LDLIBS='$ldlibs'";
        }

        $cmd = "$pref_env rpmbuild --rebuild $rpmbuild_flags --define '_topdir $TOPDIR'";
        $cmd .= " --define 'dist %{nil}'";
        $cmd .= " --target $target_cpu";
        if ($parent eq "rdma-core" and $DISTRO =~ m/SLES/) {
            my $make_jobs = `rpm --eval %make_jobs`;
            chomp $make_jobs;
            if ($make_jobs eq '%make_jobs') {
                $cmd .= " --define 'make_jobs %ninja_build'";
            }
        }

        if ($parent =~ m/libibmad|opensm|perftest|ibutils|infiniband-diags|qperf/) {
            $cmd .= " --nodeps";
        }

        # Prefix should be defined per package
        if ($parent eq "ibutils") {
            $packages_info{'ibutils'}{'configure_options'} .= " --with-osm=$prefix";
            if ($DISTRO =~ m/SLES12/) {
                my $tklib = `/bin/ls -1d /usr/lib*/tcl/tk8.6 2> /dev/null | head -1`;
                chomp $tklib;
                $packages_info{'ibutils'}{'configure_options'} .= " --with-tk-lib=$tklib" if ($tklib);
            }
            $cmd .= " --define '_prefix $prefix'";
            $cmd .= " --define '_exec_prefix $prefix'";
            $cmd .= " --define '_sysconfdir $sysconfdir'";
            $cmd .= " --define '_usr $prefix'";
            $cmd .= " --define 'build_ibmgtsim 1'";
            $cmd .= " --define '__arch_install_post %{nil}'";
        }
        elsif ($parent =~ m/dapl/) {
            my $def_doc_dir = `rpm --eval '%{_defaultdocdir}'`;
            chomp $def_doc_dir;
            $cmd .= " --define '_prefix $prefix'";
            $cmd .= " --define '_exec_prefix $prefix'";
            $cmd .= " --define '_sysconfdir $sysconfdir'";
            $cmd .= " --define '_defaultdocdir $def_doc_dir/$main_packages{$parent}{'name'}-$main_packages{$parent}{'version'}'";
            $cmd .= " --define '_usr $prefix'";
        }
        else {
            $cmd .= " --define '_prefix $prefix'";
            $cmd .= " --define '_exec_prefix $prefix'";
            $cmd .= " --define '_sysconfdir $sysconfdir'";
            $cmd .= " --define '_usr $prefix'";
        }

        if ($packages_info{$parent}{'configure_options'} or $user_configure_options) {
            $cmd .= " --define 'configure_options $packages_info{$parent}{'configure_options'} $user_configure_options'";
        }

        $cmd .= " $main_packages{$parent}{'srpmpath'}";

        print "Running $cmd\n" if ($verbose);
        open(LOG, "+>$ofedlogs/$parent.rpmbuild.log");
        print LOG "Running $cmd\n";
        close LOG;
        system("$cmd >> $ofedlogs/$parent.rpmbuild.log 2>&1");
        $res = $? >> 8;
        $sig = $? & 127;
        if ($sig or $res) {
            print RED "Failed to build $parent RPM", RESET "\n";
            print RED "See $ofedlogs/$parent.rpmbuild.log", RESET "\n";
            exit 1;
        }

        $TMPRPMS = "$TOPDIR/RPMS/$target_cpu";
        chomp $TMPRPMS;

        print "TMPRPMS $TMPRPMS\n" if ($verbose2);

        for my $myrpm ( <$TMPRPMS/*.rpm> ) {
            print "Created $myrpm\n" if ($verbose2);
            my ($myrpm_name, $myrpm_arch) = (split ' ', get_rpm_name_arch($myrpm));
            move($myrpm, $RPMS);
            $packages_info{$myrpm_name}{'rpm_exist'} = 1;
        }
    }

    if ($build32 and $packages_info{$name}{'install32'} and
        not $packages_info{$name}{'rpm_exist32'}) {
        build_rpm_32($name);
    }
}

sub install_kernel_rpm
{
    my $name = shift @_;
    my $cmd;
    my $res = 0;
    my $sig = 0;

    my $version = $main_packages{$packages_info{$name}{'parent'}}{'version'};
    my $release = $main_packages{$packages_info{$name}{'parent'}}{'release'} . '.' . $kernel_rel;

    my $package = "$RPMS/$name-$version-$release.$target_cpu.rpm";

    if (not -f $package) {
        print RED "$package does not exist", RESET "\n";
        exit 1;
    }

    $cmd = "rpm -iv $rpminstall_flags";
    if ($DISTRO =~ m/SLES/) {
        # W/A for ksym dependencies on SuSE
        $cmd .= " --nodeps";
    }
    $cmd .= " $package";

    print "Running $cmd\n" if ($verbose);
    system("$cmd > $ofedlogs/$name.rpminstall.log 2>&1");
    $res = $? >> 8;
    $sig = $? & 127;
    if ($sig or $res) {
        print RED "Failed to install $name RPM", RESET "\n";
        print RED "See $ofedlogs/$name.rpminstall.log", RESET "\n";
        exit 1;
    }
}

sub install_rpm_32
{
    my $name = shift @_;
    my $cmd;
    my $res = 0;
    my $sig = 0;
    my $package;

    my $version = $main_packages{$packages_info{$name}{'parent'}}{'version'};
    my $release = $main_packages{$packages_info{$name}{'parent'}}{'release'};

    $package = "$RPMS/$name-$version-$release.$target_cpu32.rpm";
    if (not -f $package) {
        print RED "$package does not exist", RESET "\n";
        # exit 1;
    }

    $cmd = "rpm -iv $rpminstall_flags";
    if ($DISTRO =~ m/SLES/) {
        $cmd .= " --force";
    }

    if ($name eq "libmlx4") {
        $cmd .= " --nodeps";
    }

    $cmd .= " $package";

    print "Running $cmd\n" if ($verbose);
    system("$cmd > $ofedlogs/$name.rpminstall.log 2>&1");
    $res = $? >> 8;
    $sig = $? & 127;
    if ($sig or $res) {
        print RED "Failed to install $name RPM", RESET "\n";
        print RED "See $ofedlogs/$name.rpminstall.log", RESET "\n";
        exit 1;
    }
}

# Install required RPM
sub install_rpm
{
    my $name = shift @_;
    my $tmp_name;
    my $cmd;
    my $res = 0;
    my $sig = 0;
    my $package;

    my $version = $main_packages{$packages_info{$name}{'parent'}}{'version'};
    my $release = $main_packages{$packages_info{$name}{'parent'}}{'release'};

    $package = "$RPMS/$name-$version-$release.$target_cpu.rpm";

    if (not -f $package) {
        print RED "$package does not exist", RESET "\n";
        exit 1;
    }

    if ($name eq "opensm" and $DISTRO eq "DEBIAN") {
        $rpminstall_flags .= " --nopost";
    }
    $cmd = "rpm -iv $rpminstall_flags";

    if ($name eq "rdma-core" and $DISTRO =~ m/SLES/) {
        $cmd .= " --nodeps";
    }

    if ($name =~ m/libibmad|opensm|perftest|ibutils|infiniband-diags|qperf/) {
        $cmd .= " --nodeps";
    }

    if ($name =~ m/infiniband-diags/) {
	    # Force infiniband-diags installation due to conflict with rdma-core
        $cmd .= " --force";
    }

    $cmd .= " $package";

    print "Running $cmd\n" if ($verbose);
    system("$cmd > $ofedlogs/$name.rpminstall.log 2>&1");
    $res = $? >> 8;
    $sig = $? & 127;
    if ($sig or $res) {
        print RED "Failed to install $name RPM", RESET "\n";
        print RED "See $ofedlogs/$name.rpminstall.log", RESET "\n";
        exit 1;
    }

    if ($build32 and $packages_info{$name}{'install32'}) {
        install_rpm_32($name);
    }
}

sub print_package_info
{
    print "\n\nDate:" . localtime(time) . "\n";
    for my $key ( keys %main_packages ) {
        print "$key:\n";
        print "======================================\n";
        my %pack = %{$main_packages{$key}};
        for my $subkey ( keys %pack ) {
            print $subkey . ' = ' . $pack{$subkey} . "\n";
        }
        print "\n";
    }
}

sub is_installed_deb
{
    my $res = 0;
    my $name = shift @_;
    my $result = `dpkg-query -W -f='\${version}' $name`;
    if (($result eq "") && ($? == 0) ){
        $res = 1;
    }
    return not $res;
}

sub is_installed
{
    my $res = 0;
    my $name = shift @_;

    if ($DISTRO eq "DEBIAN") {
        system("dpkg-query -W -f='\${Package} \${Version}\n' $name > /dev/null 2>&1");
    }
    else {
        system("rpm -q $name > /dev/null 2>&1");
    }
    $res = $? >> 8;

    return not $res;
}

sub count_ports
{
    my $cnt = 0;
    open(LSPCI, "/sbin/lspci -n|");

    while (<LSPCI>) {
        if (/15b3:6282/) {
            $cnt += 2;  # InfiniHost III Ex mode
        }
        elsif (/15b3:5e8c|15b3:6274/) {
            $cnt ++;    # InfiniHost III Lx mode
        }
        elsif (/15b3:5a44|15b3:6278/) {
            $cnt += 2;  # InfiniHost mode
        }
        elsif (/15b3:6340|15b3:634a|15b3:6354|15b3:6732|15b3:673c|15b3:6746|15b3:6750|15b3:1003/) {
            $cnt += 2;  # connectx
        }
    }
    close (LSPCI);

    return $cnt;
}

sub is_valid_ipv4
{
    my $ipaddr = shift @_;

    if( $ipaddr =~ m/^(\d\d?\d?)\.(\d\d?\d?)\.(\d\d?\d?)\.(\d\d?\d?)/ ) {
        if($1 <= 255 && $2 <= 255 && $3 <= 255 && $4 <= 255) {
            return 0;
        }
    }
    return 1;
}

sub get_net_config
{
    my $interface = shift @_;

    open(IFCONFIG, "/sbin/ifconfig $interface |") or die "Failed to run /sbin/ifconfig $interface: $!";
    while (<IFCONFIG>) {
        next if (not m/inet addr:/);
        my $line = $_;
        chomp $line;
        $ifcfg{$interface}{'IPADDR'} = (split (' ', $line))[1];
        $ifcfg{$interface}{'IPADDR'} =~ s/addr://g;
        $ifcfg{$interface}{'BROADCAST'} = (split (' ', $line))[2];
        $ifcfg{$interface}{'BROADCAST'} =~ s/Bcast://g;
        $ifcfg{$interface}{'NETMASK'} = (split (' ', $line))[3];
        $ifcfg{$interface}{'NETMASK'} =~ s/Mask://g;
        if ($DISTRO =~ /RHEL6|RHEL7/) {
            $ifcfg{$interface}{'NM_CONTROLLED'} = "yes";
            $ifcfg{$interface}{'TYPE'} = "InfiniBand";
        }
    }
    close(IFCONFIG);
}

sub is_carrier
{
    my $ifcheck = shift @_;
    open(IFSTATUS, "ip link show dev $ifcheck |");
    while ( <IFSTATUS> ) {
        next unless m@(\s$ifcheck).*@;
        if( m/NO-CARRIER/ or not m/UP/ ) {
            close(IFSTATUS);
            return 0;
        }
    }
    close(IFSTATUS);
    return 1;
}

sub config_interface
{
    my $interface = shift @_;
    my $ans;
    my $dev = "ib$interface";
    my $target = "$network_dir/ifcfg-$dev";
    my $ret;
    my $ip;
    my $nm;
    my $nw;
    my $bc;
    my $onboot = 1;
    my $found_eth_up = 0;

    if ($interactive) {
        print "\nDo you want to configure $dev? [Y/n]:";
        $ans = getch();
        if ($ans =~ m/[nN]/) {
            return;
        }
        if (-e $target) {
            print BLUE "\nThe current IPoIB configuration for $dev is:\n";
            open(IF,$target);
            while (<IF>) {
                print $_;
            }
            close(IF);
            print "\nDo you want to change this configuration? [y/N]:", RESET;
            $ans = getch();
            if ($ans !~ m/[yY]/) {
                return;
            }
        }
        print "\nEnter an IP Adress: ";
        $ip = <STDIN>;
        chomp $ip;
        $ret = is_valid_ipv4($ip);
        while ($ret) {
            print "\nEnter a valid IPv4 Adress: ";
            $ip = <STDIN>;
            chomp $ip;
            $ret = is_valid_ipv4($ip);
        }
        print "\nEnter the Netmask: ";
        $nm = <STDIN>;
        chomp $nm;
        $ret = is_valid_ipv4($nm);
        while ($ret) {
            print "\nEnter a valid Netmask: ";
            $nm = <STDIN>;
            chomp $nm;
            $ret = is_valid_ipv4($nm);
        }
        print "\nEnter the Network: ";
        $nw = <STDIN>;
        chomp $nw;
        $ret = is_valid_ipv4($nw);
        while ($ret) {
            print "\nEnter a valid Network: ";
            $nw = <STDIN>;
            chomp $nw;
            $ret = is_valid_ipv4($nw);
        }
        print "\nEnter the Broadcast Adress: ";
        $bc = <STDIN>;
        chomp $bc;
        $ret = is_valid_ipv4($bc);
        while ($ret) {
            print "\nEnter a valid Broadcast Adress: ";
            $bc = <STDIN>;
            chomp $bc;
            $ret = is_valid_ipv4($bc);
        }
        print "\nStart Device On Boot? [Y/n]:";
        $ans = getch();
        if ($ans =~ m/[nN]/) {
            $onboot = 0;
        }

        print GREEN "\nSelected configuration:\n";
        print "DEVICE=$dev\n";
        print "IPADDR=$ip\n";
        print "NETMASK=$nm\n";
        print "NETWORK=$nw\n";
        print "BROADCAST=$bc\n";
        if ($DISTRO =~ /RHEL6|RHEL7/) {
            print "NM_CONTROLLED=yes\n";
            print "TYPE=InfiniBand\n";
        }
        if ($onboot) {
            print "ONBOOT=yes\n";
        }
        else {
            print "ONBOOT=no\n";
        }
        print "\nDo you want to save the selected configuration? [Y/n]:";
        $ans = getch();
        if ($ans =~ m/[nN]/) {
            return;
        }
    }
    else {
        if (not $config_net_given) {
            return;
        }
        print "Going to update $target\n" if ($verbose2);
        if ($ifcfg{$dev}{'LAN_INTERFACE'}) {
            $eth_dev = $ifcfg{$dev}{'LAN_INTERFACE'};
            if (not -e "/sys/class/net/$eth_dev") {
                print "Device $eth_dev is not present\n" if (not $quiet);
                return;
            }
            if ( is_carrier ($eth_dev) ) {
                $found_eth_up = 1;
            }
        }
        else {
            # Take the first existing Eth interface
            my @eth_devs = </sys/class/net/eth*>;
            for my $tmp_dev ( @eth_devs ) {
                $eth_dev = $tmp_dev;
                $eth_dev =~ s@/sys/class/net/@@g;
                if ( is_carrier ($eth_dev) ) {
                    $found_eth_up = 1;
                    last;
                }
            }
        }

        if ($found_eth_up) {
            get_net_config("$eth_dev");
        }

        if (not $ifcfg{$dev}{'IPADDR'}) {
            print "IP address is not defined for $dev\n" if ($verbose2);
            print "Skipping $dev configuration...\n" if ($verbose2);
            return;
        }
        if (not $ifcfg{$dev}{'NETMASK'}) {
            print "Netmask is not defined for $dev\n" if ($verbose2);
            print "Skipping $dev configuration...\n" if ($verbose2);
            return;
        }
        if (not $ifcfg{$dev}{'NETWORK'}) {
            print "Network is not defined for $dev\n" if ($verbose2);
            print "Skipping $dev configuration...\n" if ($verbose2);
            return;
        }
        if (not $ifcfg{$dev}{'BROADCAST'}) {
            print "Broadcast address is not defined for $dev\n" if ($verbose2);
            print "Skipping $dev configuration...\n" if ($verbose2);
            return;
        }

        my @ipib = (split('\.', $ifcfg{$dev}{'IPADDR'}));
        my @nmib = (split('\.', $ifcfg{$dev}{'NETMASK'}));
        my @nwib = (split('\.', $ifcfg{$dev}{'NETWORK'}));
        my @bcib = (split('\.', $ifcfg{$dev}{'BROADCAST'}));

        my @ipeth = (split('\.', $ifcfg{$eth_dev}{'IPADDR'}));
        my @nmeth = (split('\.', $ifcfg{$eth_dev}{'NETMASK'}));
        my @nweth = (split('\.', $ifcfg{$eth_dev}{'NETWORK'}));
        my @bceth = (split('\.', $ifcfg{$eth_dev}{'BROADCAST'}));

        for (my $i = 0; $i < 4 ; $i ++) {
            if ($ipib[$i] =~ m/\*/) {
                if ($ipeth[$i] =~ m/(\d\d?\d?)/) {
                    $ipib[$i] = $ipeth[$i];
                }
                else {
                    print "Cannot determine the IP address of the $dev interface\n" if (not $quiet);
                    return;
                }
            }
            if ($nmib[$i] =~ m/\*/) {
                if ($nmeth[$i] =~ m/(\d\d?\d?)/) {
                    $nmib[$i] = $nmeth[$i];
                }
                else {
                    print "Cannot determine the netmask of the $dev interface\n" if (not $quiet);
                    return;
                }
            }
            if ($bcib[$i] =~ m/\*/) {
                if ($bceth[$i] =~ m/(\d\d?\d?)/) {
                    $bcib[$i] = $bceth[$i];
                }
                else {
                    print "Cannot determine the broadcast address of the $dev interface\n" if (not $quiet);
                    return;
                }
            }
            if ($nwib[$i] !~ m/(\d\d?\d?)/) {
                $nwib[$i] = $nweth[$i];
            }
        }

        $ip = "$ipib[0].$ipib[1].$ipib[2].$ipib[3]";
        $nm = "$nmib[0].$nmib[1].$nmib[2].$nmib[3]";
        $nw = "$nwib[0].$nwib[1].$nwib[2].$nwib[3]";
        $bc = "$bcib[0].$bcib[1].$bcib[2].$bcib[3]";

        print GREEN "IPoIB configuration for $dev\n";
        print "DEVICE=$dev\n";
        print "IPADDR=$ip\n";
        print "NETMASK=$nm\n";
        print "NETWORK=$nw\n";
        print "BROADCAST=$bc\n";
        if ($onboot) {
            print "ONBOOT=yes\n";
        }
        else {
            print "ONBOOT=no\n";
        }
        print RESET "\n";
    }

    open(IF, ">$target") or die "Can't open $target: $!";
    if ($DISTRO =~ m/SLES/) {
        print IF "BOOTPROTO='static'\n";
        print IF "IPADDR='$ip'\n";
        print IF "NETMASK='$nm'\n";
        print IF "NETWORK='$nw'\n";
        print IF "BROADCAST='$bc'\n";
        print IF "REMOTE_IPADDR=''\n";
        if ($onboot) {
            print IF "STARTMODE='onboot'\n";
        }
        else {
            print IF "STARTMODE='manual'\n";
        }
        print IF "WIRELESS=''\n";
    }
    else {
        print IF "DEVICE=$dev\n";
        print IF "BOOTPROTO=static\n";
        print IF "IPADDR=$ip\n";
        print IF "NETMASK=$nm\n";
        print IF "NETWORK=$nw\n";
        print IF "BROADCAST=$bc\n";
        if ($DISTRO =~ /RHEL6|RHEL7/) {
            print IF "NM_CONTROLLED=yes\n";
            print IF "TYPE=InfiniBand\n";
        }
        if ($onboot) {
            print IF "ONBOOT=yes\n";
        }
        else {
            print IF "ONBOOT=no\n";
        }
    }
    close(IF);
}

sub ipoib_config
{
    if ($interactive) {
        print BLUE;
        print "\nThe default IPoIB interface configuration is based on DHCP.";
        print "\nNote that a special patch for DHCP is required for supporting IPoIB.";
        print "\nThe patch is available under docs/dhcp";
        print "\nIf you do not have DHCP, you must change this configuration in the following steps.";
        print RESET "\n";
    }

    my $ports_num = count_ports();
    for (my $i = 0; $i < $ports_num; $i++ ) {
        config_interface($i);
    }

    if ($interactive) {
        print GREEN "IPoIB interfaces configured successfully",RESET "\n";
        print "Press any key to continue ...";
        getch();
    }

    if (-f "/etc/sysconfig/network/config") {
        my $nm = `grep ^NETWORKMANAGER=yes /etc/sysconfig/network/config`;
        chomp $nm;
        if ($nm) {
            print RED "Please set NETWORKMANAGER=no in the /etc/sysconfig/network/config", RESET "\n";
        }
    }

}

sub force_uninstall
{
    my $res = 0;
    my $sig = 0;
    my $cnt = 0;
    my @other_ofed_rpms = `rpm -qa 2> /dev/null | grep -wE "rdma|ofed|openib|ofa_kernel"`;
    my $cmd = "rpm -e --allmatches --nodeps";

    for my $package (@all_packages, @hidden_packages, @prev_ofed_packages, @other_ofed_rpms, @distro_ofed_packages) {
        chomp $package;
        if (is_installed($package)) {
            push (@packages_to_uninstall, $package);
            $selected_for_uninstall{$package} = 1;
        }
        if (is_installed("$package-static")) {
            push (@packages_to_uninstall, "$package-static");
            $selected_for_uninstall{$package} = 1;
        }
        if ($suffix_32bit and is_installed("$package$suffix_32bit")) {
            push (@packages_to_uninstall,"$package$suffix_32bit");
            $selected_for_uninstall{$package} = 1;
        }
        if ($suffix_64bit and is_installed("$package$suffix_64bit")) {
            push (@packages_to_uninstall,"$package$suffix_64bit");
            $selected_for_uninstall{$package} = 1;
        }
    }

    for my $package (@packages_to_uninstall) {
        get_requires($package);
    }

    for my $package (@packages_to_uninstall, @dependant_packages_to_uninstall) {
        if (is_installed("$package")) {
            $cmd .= " $package";
            $cnt ++;
        }
    }

    if ($cnt) {
        print "\n$cmd\n" if (not $quiet);
        open (LOG, "+>$ofedlogs/ofed_uninstall.log");
        print LOG "$cmd\n";
        close LOG;
        system("$cmd >> $ofedlogs/ofed_uninstall.log 2>&1");
        $res = $? >> 8;
        $sig = $? & 127;
        if ($sig or $res) {
            print RED "Failed to uninstall the previous installation", RESET "\n";
            print RED "See $ofedlogs/ofed_uninstall.log", RESET "\n";
            exit 1;
        }
    }
}

sub uninstall
{
    my $res = 0;
    my $sig = 0;
    my $distro_rpms = '';

    my $ofed_uninstall = `which ofed_uninstall.sh 2> /dev/null`;
    chomp $ofed_uninstall;
    if (-f "$ofed_uninstall") {
        print BLUE "Uninstalling the previous version of $PACKAGE", RESET "\n" if (not $quiet);
        system("yes | ofed_uninstall.sh >> $ofedlogs/ofed_uninstall.log 2>&1");
        $res = $? >> 8;
        $sig = $? & 127;
        if ($sig or $res) {
            system("yes | $CWD/uninstall.sh >> $ofedlogs/ofed_uninstall.log 2>&1");
            $res = $? >> 8;
            $sig = $? & 127;
            if ($sig or $res) {
                # Last try to uninstall
                force_uninstall();
            }
        } else {
            return 0;
        }
    } else {
        force_uninstall();
    }
}

sub install
{
    # Build and install selected RPMs
    for my $package ( @selected_packages ) {
        if ($packages_info{$package}{'internal'}) {
            my $parent = $packages_info{$package}{'parent'};
            if (not $main_packages{$parent}{'srpmpath'}) {
                print RED "$parent source RPM is not available", RESET "\n";
                next;
            }
        }

        if ($packages_info{$package}{'mode'} eq "user") {
            if (not $packages_info{$package}{'exception'}) {
                if ( (not $packages_info{$package}{'rpm_exist'}) or
                     ($build32 and $packages_info{$package}{'install32'} and
                      not $packages_info{$package}{'rpm_exist32'}) ) {
                    build_rpm($package);
                }

                if ( (not $packages_info{$package}{'rpm_exist'}) or
                     ($build32 and $packages_info{$package}{'install32'} and
                      not $packages_info{$package}{'rpm_exist32'}) ) {
                    print RED "$package was not created", RESET "\n";
                    exit 1;
                }
                print "Install $package RPM:\n" if ($verbose);
                install_rpm($package);
            }
        }
        else {
            # kernel modules
            if (not $packages_info{$package}{'rpm_exist'}) {
                my $parent = $packages_info{$package}{'parent'};
                print "Build $parent RPM\n" if ($verbose);
                build_kernel_rpm($parent);
            }
            if (not $packages_info{$package}{'rpm_exist'}) {
                print RED "$package was not created", RESET "\n";
                exit 1;
            }
            print "Install $package RPM:\n" if ($verbose);
            install_kernel_rpm($package);
        }
    }
}

sub check_pcie_link
{
    if (open (PCI, "$lspci -d 15b3: -n|")) {
        while(<PCI>) {
            my $devinfo = $_;
            $devinfo =~ /(15b3:[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])/;
            my $devid = $&;
            my $link_width = `$setpci -d $devid 72.B | cut -b1`;
            chomp $link_width;

            print BLUE "Device ($devid):\n";
            print "\t" . `$lspci -d $devid`;

            if ( $link_width eq "8" ) {
                print "\tLink Width: 8x\n";
            }
            else {
                print "\tLink Width is not 8x\n";
            }
            my $link_speed = `$setpci -d $devid 72.B | cut -b2`;
            chomp $link_speed;
            if ( $link_speed eq "1" ) {
                print "\tPCI Link Speed: 2.5Gb/s\n";
            }
            elsif ( $link_speed eq "2" ) {
                print "\tPCI Link Speed: 5Gb/s\n";
            }
            else {
                print "\tPCI Link Speed: Unknown\n";
            }
            print "", RESET "\n";
        }
        close (PCI);
    }
}

### MAIN AREA ###
sub main
{
    if ($print_available) {
        my @list = ();
        set_availability();

        for my $srcrpm ( <$SRPMS*> ) {
            set_cfg ($srcrpm);
        }

        if (!$install_option) {
            $install_option = 'all';
        }

        $config = $CWD . "/ofed-$install_option.conf";
        chomp $config;
        if ($install_option eq 'all') {
            @list = (@all_packages, @hidden_packages);
        }
        elsif ($install_option eq 'basic') {
            @list = (@basic_user_packages, @basic_kernel_packages);
            @kernel_modules = (@basic_kernel_modules);
        }

        @selected_by_user = (@list);
	if ($with_xeon_phi){
	    push (@selected_by_user, @xeon_phi_user);
	} else { 
	    push (@selected_by_user, @non_xeon_phi_user);
	}

        @selected_modules_by_user = (@kernel_modules);
        push (@selected_modules_by_user, @xeon_phi_kernel) if ($with_xeon_phi);

        resolve_dependencies();
        open(CONFIG, ">$config") || die "Can't open $config: $!";;
        flock CONFIG, $LOCK_EXCLUSIVE;
        print "\nOFED packages: ";
        for my $package ( @selected_packages ) {
            my $parent = $packages_info{$package}{'parent'};
            next if (not $packages_info{$package}{'available'} or not $main_packages{$parent}{'srpmpath'});
            print("$package available: $packages_info{$package}{'available'}\n") if ($verbose2);
            if ($package =~ /compat-rdma/ and $package !~ /devel/) {
                print "\nKernel modules: ";
                for my $module ( @selected_kernel_modules ) {
                    next if (not $kernel_modules_info{$module}{'available'});
                    print $module . ' ';
                    print CONFIG "$module=y\n";
                }
                print "\nRPMs: ";
            }
            print $package . ' ';
            print CONFIG "$package=y\n";
        }
        flock CONFIG, $UNLOCK;
        close(CONFIG);

	if ($DISTRO =~ /RHEL.*/ || $DISTRO =~ /SLES.*/ ) {
            print "\nTech Preview: ";
            print "xeon-phi ";
        }

        print "\n";
        print GREEN "Created $config", RESET "\n";
        exit 0;
    }

    my $num_selected = 0;

    push (@kernel_modules, @xeon_phi_kernel) if ($with_xeon_phi);
    if ($with_xeon_phi){
	push (@all_packages, @xeon_phi_user);
    } else { 
	push (@all_packages, @non_xeon_phi_user);
    }

    if ($interactive) {
        my $inp;
        my $ok = 0;
        my $max_inp;

        while (! $ok) {
            $max_inp = show_menu("main");
            $inp = getch();

            if ($inp =~ m/[qQ]/ || $inp =~ m/[Xx]/ ) {
                die "Exiting\n";
            }
            if (ord($inp) == $KEY_ENTER) {
                next;
            }
            if ($inp =~ m/[0123456789abcdefABCDEF]/)
            {
                $inp = hex($inp);
            }
            if ($inp < 1 || $inp > $max_inp)
            {
                print "Invalid choice...Try again\n";
                next;
            }
            $ok = 1;
        }

        if ($inp == 1) {
            if (-e "$CWD/docs/${PACKAGE}_Installation_Guide.txt") {
                system("less $CWD/docs/${PACKAGE}_Installation_Guide.txt");
            }
            elsif (-e "$CWD/README.txt") {
                system("less $CWD/README.txt");
            }
            else {
                print RED "$CWD/docs/${PACKAGE}_Installation_Guide.txt does not exist...", RESET;
            }

            return 0;
        }
        elsif ($inp == 2) {
            for my $srcrpm ( <$SRPMS*> ) {
                set_cfg ($srcrpm);
            }

            # Set RPMs info for available source RPMs
            set_availability();
            $num_selected = select_packages();
            set_existing_rpms();
            resolve_dependencies();
            check_linux_dependencies();
            if (not $quiet) {
                print_selected();
            }
        }
        elsif ($inp == 3) {
            my $cnt = 0;
            for my $package ( @all_packages, @hidden_packages) {
                if (is_installed($package)) {
                    print "$package\n";
                    $cnt ++;
                }
            }
            if (not $cnt) {
                print "\nThere is no $PACKAGE software installed\n";
            }
            print GREEN "\nPress any key to continue...", RESET;
            getch();
            return 0;
        }
        elsif ($inp == 4) {
            ipoib_config();
            return 0;
        }
        elsif ($inp == 5) {
            uninstall();
            exit 0;
        }

    }
    else {
        for my $srcrpm ( <$SRPMS*> ) {
            set_cfg ($srcrpm);
        }

        # Set RPMs info for available source RPMs
        set_availability();
        $num_selected = select_packages();
        set_existing_rpms();
        resolve_dependencies();
        check_linux_dependencies();
        if (not $quiet) {
            print_selected();
        }
    }

    if (not $num_selected) {
        print RED "$num_selected packages selected. Exiting...", RESET "\n";
        exit 1;
    }
    print BLUE "Detected Linux Distribution: $DISTRO", RESET "\n" if ($verbose3);

    # Uninstall the previous installations
    uninstall();
    my $vendor_ret;
    if (length($vendor_pre_install) > 0) {
            print BLUE "\nRunning vendor pre install script: $vendor_pre_install", RESET "\n" if (not $quiet);
            $vendor_ret = system ( "$vendor_pre_install", "CONFIG=$config",
                "RPMS=$RPMS", "SRPMS=$SRPMS", "PREFIX=$prefix", "TOPDIR=$TOPDIR", "QUIET=$quiet" );
            if ($vendor_ret != 0) {
                    print RED "\nExecution of vendor pre install script failed.", RESET "\n" if (not $quiet);
                    exit 1;
            }
    }
    install();

    system("/sbin/ldconfig > /dev/null 2>&1");

    if (-f "/etc/modprobe.conf.dist") {
        open(MDIST, "/etc/modprobe.conf.dist") or die "Can't open /etc/modprobe.conf.dist: $!";
        my @mdist_lines;
        while (<MDIST>) {
            push @mdist_lines, $_;
        }
        close(MDIST);

        open(MDIST, ">/etc/modprobe.conf.dist") or die "Can't open /etc/modprobe.conf.dist: $!";
        foreach my $line (@mdist_lines) {
            chomp $line;
            if ($line =~ /^\s*install ib_core|^\s*alias ib|^\s*alias net-pf-26 ib_sdp/) {
                print MDIST "# $line\n";
            } else {
                print MDIST "$line\n";
            }
        }
        close(MDIST);
    }

    if (length($vendor_pre_uninstall) > 0) {
	    system "cp $vendor_pre_uninstall $prefix/sbin/vendor_pre_uninstall.sh";
    }
    if (length($vendor_post_uninstall) > 0) {
	    system "cp $vendor_post_uninstall $prefix/sbin/vendor_post_uninstall.sh";
    }
    if (length($vendor_post_install) > 0) {
	    print BLUE "\nRunning vendor post install script: $vendor_post_install", RESET "\n" if (not $quiet);
	    $vendor_ret = system ( "$vendor_post_install", "CONFIG=$config",
		"RPMS=$RPMS", "SRPMS=$SRPMS", "PREFIX=$prefix", "TOPDIR=$TOPDIR", "QUIET=$quiet");
	    if ($vendor_ret != 0) {
		    print RED "\nExecution of vendor post install script failed.", RESET "\n" if (not $quiet);
		    exit 1;
	    }
    }

    if ($kernel_modules_info{'ipoib'}{'selected'}) {
        ipoib_config();

        # Decrease send/receive queue sizes on 32-bit arcitecture
        # BUG: https://bugs.openfabrics.org/show_bug.cgi?id=1420
        if ($arch =~ /i[3-6]86/) {
            if (-f "/etc/modprobe.d/ib_ipoib.conf") {
                open(MODPROBE_CONF, ">>/etc/modprobe.d/ib_ipoib.conf");
                print MODPROBE_CONF "options ib_ipoib send_queue_size=64 recv_queue_size=128\n";
                close MODPROBE_CONF;
            }
        }

        # BUG: https://bugs.openfabrics.org/show_bug.cgi?id=1449
        if (-f "/etc/modprobe.d/ipv6") {
            open(IPV6, "/etc/modprobe.d/ipv6") or die "Can't open /etc/modprobe.d/ipv6: $!";
            my @ipv6_lines;
            while (<IPV6>) {
                push @ipv6_lines, $_;
            }
            close(IPV6);

            open(IPV6, ">/etc/modprobe.d/ipv6") or die "Can't open /etc/modprobe.d/ipv6: $!";
            foreach my $line (@ipv6_lines) {
                chomp $line;
                if ($line =~ /^\s*install ipv6/) {
                    print IPV6 "# $line\n";
                } else {
                    print IPV6 "$line\n";
                }
            }
            close(IPV6);
        }
    }

    if ( not $quiet ) {
        check_pcie_link();
    }

    if ($umad_dev_rw) {
        if (-f $ib_udev_rules) {
            open(IB_UDEV_RULES, $ib_udev_rules) or die "Can't open $ib_udev_rules: $!";
            my @ib_udev_rules_lines;
            while (<IB_UDEV_RULES>) {
                push @ib_udev_rules_lines, $_;
            }
            close(IPV6);

            open(IB_UDEV_RULES, ">$ib_udev_rules") or die "Can't open $ib_udev_rules: $!";
            foreach my $line (@ib_udev_rules_lines) {
                chomp $line;
                if ($line =~ /umad/) {
                    print IB_UDEV_RULES "$line, MODE=\"0666\"\n";
                } else {
                    print IB_UDEV_RULES "$line\n";
                }
            }
            close(IB_UDEV_RULES);
        }
    }

    print GREEN "\nInstallation finished successfully.", RESET;
    if ($interactive) {
        print GREEN "\nPress any key to continue...", RESET;
        getch();
    }
    else {
        print "\n";
    }
}

while (1) {
    main();
    exit 0 if (not $interactive);
}
