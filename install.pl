#!/usr/bin/perl
#
# Copyright (c) 2006 Mellanox Technologies. All rights reserved.
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

# use Cwd;


sub usage
{
   print BLUE;
   print "\n Usage: $0 [-c <packages config_file>] [-n|--net <network config_file>]";
   print "\n           [-p|--print-available <kernel version>]";
   print "\n           [-k|--kernel <kernel version>]";
   print RESET . "\n\n";
}

$| = 1;
my $LOCK_EXCLUSIVE = 2;
my $UNLOCK         = 8;
#Setup some defaults
my $KEY_ESC=27;
my $KEY_CNTL_C=3;
my $KEY_ENTER=13;

my $INSTALL_CHOICE;

my $interactive = 1;
my $verbose = 0;
my $verbose2 = 0;
my $verbose3 = 0;

my $print_available = 0;

my $clear_string = `clear`;

my $distro;

my $build32 = 0;
my $arch = `uname -m`;
chomp $arch;
my $kernel = `uname -r`;
chomp $kernel;

my $PACKAGE     = 'OFED';

my $WDIR    = dirname($0);
chdir $WDIR;
my $CWD     = getcwd;
my $TMPDIR  = '/tmp';
my $netdir;

# Define RPMs environment
my $dist_rpm;
if (-f "/etc/issue") {
    $dist_rpm = `rpm -qf /etc/issue`;
}
else {
    $dist_rpm = "unsupported";
}

my $SRPMS = $CWD . '/' . 'SRPMS/';
chomp $SRPMS;
my $RPMS  = $CWD . '/' . 'RPMS' . '/' . $dist_rpm;
chomp $RPMS;
if (not -d $RPMS) {
    mkpath([$RPMS]);
}

my $config = $CWD . '/ofed.conf';
chomp $config;
my $config_net;

my $TOPDIR = "/var/tmp/" . $PACKAGE . "_topdir";
chomp $TOPDIR;

rmtree ("$TOPDIR");
mkpath([$TOPDIR . '/BUILD' ,$TOPDIR . '/RPMS',$TOPDIR . '/SOURCES',$TOPDIR . '/SPECS',$TOPDIR . '/SRPMS']);
my $ofedlogs = "/tmp/$PACKAGE.$$.logs";
mkpath([$ofedlogs]);

my $prefix ='/usr';
chomp $prefix;

my $target_cpu  = `rpm --eval '%{_target_cpu}'`;
chomp $target_cpu;

my $target_cpu32;
if (-f "/etc/SuSE-release") {
    $target_cpu32 = 'i586';
}
else {
    $target_cpu32 = 'i686';
}
chomp $target_cpu32;

my $mandir      = `rpm --eval '%{_mandir}'`;
chomp $mandir;
my $sysconfdir  = `rpm --eval '%{_sysconfdir}'`;
chomp $sysconfdir;
my %main_packages = ();
my @selected_packages = ();
my @selected_by_user = ();
my @selected_modules_by_user = ();
my @selected_kernel_modules = ();

# List of all available packages sorted following dependencies
my @kernel_packages = ("kernel-ib", "kernel-ib-devel", "ib-bonding", "ib-bonding-debuginfo");
my @basic_kernel_modules = ("core", "mthca", "mlx4", "ipoib");
my @kernel_modules = (@basic_kernel_modules, "sdp", "srp");

my $kernel_configure_options;

my @user_packages = ("libibverbs", "libibverbs-devel", "libibverbs-devel-static", 
                     "libibverbs-utils", "libibverbs-debuginfo",
                     "libmthca", "libmthca-devel-static", "libmthca-debuginfo", 
                     "libmlx4", "libmlx4-devel-static", "libmlx4-debuginfo",
                     "libehca", "libehca-devel-static", "libehca-debuginfo",
                     "libcxgb3", "libcxgb3-devel", "libcxgb3-debuginfo",
                     "libipathverbs", "libipathverbs-devel", "libipathverbs-debuginfo",
                     "libibcm", "libibcm-devel", "libibcm-debuginfo",
                     "libibcommon", "libibcommon-devel", "libibcommon-debuginfo",
                     "libibumad", "libibumad-devel", "libibumad-debuginfo",
                     "libibmad", "libibmad-devel", "libibmad-debuginfo",
                     "librdmacm", "librdmacm-devel", "librdmacm-debuginfo",
                     "libsdp", "libsdp-devel", "libsdp-debuginfo",
                     "opensm", "opensm-libs", "opensm-devel", "opensm-debuginfo", "opensm-static",
                     "perftest", "mstflint", "tvflash",
                     "qlvnictools", "sdpnetstat", "srptools", "rds-tools",
                     "ibutils", "infiniband-diags",
                     "ofed-docs", "ofed-scripts",
                     "mpi-selector", "mvapich", "mvapich2", "openmpi", "mpitests",
                     );

# all_packages is required to save ordered (following dependencies) list of
# packages. Hash does not saves the order
my @all_packages = (@kernel_packages, @user_packages);

my %kernel_modules_info = (
        'core' =>
            { name => "core", available => 1, selected => 0,
            included_in_rpm => 0, requires => [], },
        'mthca' =>
            { name => "mthca", available => 1, selected => 0,
            included_in_rpm => 0, requires => ["core"], },
        'mlx4' =>
            { name => "mlx4", available => 1, selected => 0,
            included_in_rpm => 0, requires => ["core"], },
        'ehca' =>
            { name => "ehca", available => 0, selected => 0,
            included_in_rpm => 0, requires => ["core"], },
        'ipath' =>
            { name => "ipath", available => 0, selected => 0,
            included_in_rpm => 0, requires => ["core"], },
        'cxgb3' =>
            { name => "cxgb3", available => 1, selected => 0,
            included_in_rpm => 0, requires => ["core"], },
        'ipoib' =>
            { name => "ipoib", available => 1, selected => 0,
            included_in_rpm => 0, requires => ["core"], },
        'sdp' =>
            { name => "sdp", available => 1, selected => 0,
            included_in_rpm => 0, requires => ["core", "ipoib"], },
        'srp' =>
            { name => "srp", available => 1, selected => 0,
            included_in_rpm => 0, requires => ["core", "ipoib"], },
        'rds' =>
            { name => "rds", available => 1, selected => 0,
            included_in_rpm => 0, requires => ["core", "ipoib"], },
        'iser' =>
            { name => "iser", available => 1, selected => 0,
            included_in_rpm => 0, requires => ["core", "ipoib"], },
        'vnic' =>
            { name => "vnic", available => 1, selected => 0,
            included_in_rpm => 0, requires => ["core", "ipoib"], },
        );

my %packages_info = (
        # Kernel packages
        'ofa_kernel' =>
            { name => "ofa_kernel", parent => "ofa_kernel",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "kernel", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [], ofa_req_inst => [], },
        'kernel-ib' =>
            { name => "kernel-ib", parent => "ofa_kernel",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "kernel", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [], ofa_req_inst => [], },
        'kernel-ib-devel' =>
            { name => "kernel-ib-devel", parent => "ofa_kernel",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "kernel", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [], },
        'ib-bonding' =>
            { name => "ib-bonding", parent => "ib-bonding",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "kernel", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [], ofa_req_inst => [], },
        'ib-bonding-debuginfo' =>
            { name => "ib-bonding-debuginfo", parent => "ib-bonding",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "kernel", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [], ofa_req_inst => [], },
        # User space libraries
        'libibverbs' =>
            { name => "libibverbs", parent => "libibverbs",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [], ofa_req_inst => [], 
            install32 => 1, exception => 0 },
        'libibverbs-devel' =>
            { name => "libibverbs-devel", parent => "libibverbs",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => ["libibverbs"],
            install32 => 1, exception => 0 },
        'libibverbs-devel-static' =>
            { name => "libibverbs-devel-static", parent => "libibverbs",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => ["libibverbs"],
            install32 => 1, exception => 0 },
        'libibverbs-utils' =>
            { name => "libibverbs-utils", parent => "libibverbs",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => ["libibverbs"],
            install32 => 0, exception => 0 },
        'libibverbs-debuginfo' =>
            { name => "libibverbs-debuginfo", parent => "libibverbs",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'libmthca' =>
            { name => "libmthca", parent => "libmthca",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs"],
            ofa_req_inst => ["libibverbs"],
            install32 => 1, exception => 0 },
        'libmthca-devel-static' =>
            { name => "libmthca-devel-static", parent => "libmthca",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs","libibverbs-devel"],
            ofa_req_inst => ["libibverbs", "libmthca"],
            install32 => 1, exception => 0 },
        'libmthca-debuginfo' =>
            { name => "libmthca-debuginfo", parent => "libmthca",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs","libibverbs-devel"],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'libmlx4' =>
            { name => "libmlx4", parent => "libmlx4",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs-devel"],
            ofa_req_inst => ["libibverbs"],
            install32 => 1, exception => 0 },
        'libmlx4-devel-static' =>
            { name => "libmlx4-devel-static", parent => "libmlx4",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs","libibverbs-devel"],
            ofa_req_inst => ["libibverbs", "libmlx4"],
            install32 => 1, exception => 0 },
        'libmlx4-debuginfo' =>
            { name => "libmlx4-debuginfo", parent => "libmlx4",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs","libibverbs-devel"],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'libehca' =>
            { name => "libehca", parent => "libehca",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs"],
            ofa_req_inst => ["libibverbs"],
            install32 => 1, exception => 0 },
        'libehca-devel-static' =>
            { name => "libehca-devel-static", parent => "libehca",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs","libibverbs-devel"],
            ofa_req_inst => ["libibverbs", "libehca"],
            install32 => 1, exception => 0 },
        'libehca-debuginfo' =>
            { name => "libehca-debuginfo", parent => "libehca",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs","libibverbs-devel"],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'libcxgb3' =>
            { name => "libcxgb3", parent => "libcxgb3",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs-devel"],
            ofa_req_inst => ["libibverbs"],
            install32 => 1, exception => 0 },
        'libcxgb3-devel' =>
            { name => "libcxgb3-devel", parent => "libcxgb3",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs","libibverbs-devel"],
            ofa_req_inst => ["libibverbs", "libcxgb3"],
            install32 => 1, exception => 0 },
        'libcxgb3-debuginfo' =>
            { name => "libcxgb3-debuginfo", parent => "libcxgb3",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs","libibverbs-devel"],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'libipathverbs' =>
            { name => "libipathverbs", parent => "libipathverbs",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs-devel"],
            ofa_req_inst => ["libibverbs"],
            install32 => 1, exception => 0 },
        'libipathverbs-devel' =>
            { name => "libipathverbs-devel", parent => "libipathverbs",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs","libibverbs-devel"],
            ofa_req_inst => ["libibverbs", "libipathverbs"],
            install32 => 1, exception => 0 },
        'libipathverbs-debuginfo' =>
            { name => "libipathverbs-debuginfo", parent => "libipathverbs",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs","libibverbs-devel"],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'libibcm' =>
            { name => "libibcm", parent => "libibcm",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs"],
            ofa_req_inst => ["libibverbs"],
            install32 => 1, exception => 0 },
        'libibcm-devel' =>
            { name => "libibcm-devel", parent => "libibcm",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs","libibverbs-devel"],
            ofa_req_inst => ["libibverbs", "libibverbs-devel", "libibcm"],
            install32 => 1, exception => 0 },
        'libibcm-debuginfo' =>
            { name => "libibcm-debuginfo", parent => "libibcm",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs","libibverbs-devel"],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },
        # Management
        'libibcommon' =>
            { name => "libibcommon", parent => "libibcommon",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs"],
            ofa_req_inst => ["libibverbs"],
            install32 => 1, exception => 0 },
        'libibcommon-devel' =>
            { name => "libibcommon-devel", parent => "libibcommon",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs","libibverbs-devel"],
            ofa_req_inst => ["libibverbs", "libibcommon"],
            install32 => 1, exception => 0 },
        'libibcommon-debuginfo' =>
            { name => "libibcommon-debuginfo", parent => "libibcommon",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs","libibverbs-devel"],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'libibumad' =>
            { name => "libibumad", parent => "libibumad",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs"],
            ofa_req_inst => ["libibverbs", "libibcommon"],
            install32 => 1, exception => 0 },
        'libibumad-devel' =>
            { name => "libibumad-devel", parent => "libibumad",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs","libibverbs-devel"],
            ofa_req_inst => ["libibverbs", "libibcommon-devel", "libibumad"],
            install32 => 1, exception => 0 },
        'libibumad-debuginfo' =>
            { name => "libibumad-debuginfo", parent => "libibumad",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs","libibverbs-devel"],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'libibmad' =>
            { name => "libibmad", parent => "libibmad",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibumad-devel"],
            ofa_req_inst => ["libibverbs", "libibumad"],
            install32 => 1, exception => 0 },
        'libibmad-devel' =>
            { name => "libibmad-devel", parent => "libibmad",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibumad-devel"],
            ofa_req_inst => ["libibmad", "libibumad-devel"],
            install32 => 1, exception => 0 },
        'libibmad-debuginfo' =>
            { name => "libibmad-debuginfo", parent => "libibmad",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'opensm' =>
            { name => "opensm", parent => "opensm",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => ["opensm-libs"],
            install32 => 0, exception => 0 },
        'opensm-devel' =>
            { name => "opensm-devel", parent => "opensm",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => ["libibumad-devel", "opensm-libs"],
            install32 => 1, exception => 0 },
        'opensm-libs' =>
            { name => "opensm-libs", parent => "opensm",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => ["libibumad"],
            install32 => 1, exception => 0 },
        'opensm-static' =>
            { name => "opensm-static", parent => "opensm",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => ["libibumad-devel", "opensm-libs"],
            install32 => 1, exception => 0 },
        'opensm-debuginfo' =>
            { name => "opensm-debuginfo", parent => "opensm",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'librdmacm' =>
            { name => "librdmacm", parent => "librdmacm",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => ["libibverbs", "libibverbs-devel"],
            install32 => 1, exception => 0 },
        'librdmacm-devel' =>
            { name => "librdmacm-devel", parent => "librdmacm",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => ["librdmacm"],
            install32 => 1, exception => 0 },
        'librdmacm-debuginfo' =>
            { name => "librdmacm-debuginfo", parent => "librdmacm",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'libsdp' =>
            { name => "libsdp", parent => "libsdp",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 1, exception => 0 },
        'libsdp-devel' =>
            { name => "libsdp-devel", parent => "libsdp",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => ["libsdp"],
            install32 => 1, exception => 0 },
        'libsdp-debuginfo' =>
            { name => "libsdp-debuginfo", parent => "libsdp",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'perftest' =>
            { name => "perftest", parent => "perftest",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs-devel", "librdmacm-devel"],
            ofa_req_inst => ["libibverbs", "librdmacm"],
            install32 => 0, exception => 1 },
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
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 1 },
        'mstflint-debuginfo' =>
            { name => "mstflint-debuginfo", parent => "mstflint",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'tvflash' =>
            { name => "tvflash", parent => "tvflash",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 1 },
        'tvflash-debuginfo' =>
            { name => "tvflash-debuginfo", parent => "tvflash",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'ibvexdmtools' =>
            { name => "ibvexdmtools", parent => "qlvnictools",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },
        'qlvnictools' =>
            { name => "qlvnictools", parent => "qlvnictools",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => ["ibvexdmtools"],
            install32 => 0, exception => 0 },
        'qlvnictools-debuginfo' =>
            { name => "qlvnictools-debuginfo", parent => "qlvnictools",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'sdpnetstat' =>
            { name => "sdpnetstat", parent => "sdpnetstat",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },
        'sdpnetstat-debuginfo' =>
            { name => "sdpnetstat-debuginfo", parent => "sdpnetstat",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'srptools' =>
            { name => "srptools", parent => "srptools",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => ["libibcommon", "libibumad", "libibverbs"],
            install32 => 0, exception => 0 },
        'srptools-debuginfo' =>
            { name => "srptools-debuginfo", parent => "srptools",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'rds-tools' =>
            { name => "rds-tools", parent => "rds-tools",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },
        'rds-tools-debuginfo' =>
            { name => "rds-tools-debuginfo", parent => "rds-tools",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'ibutils' =>
            { name => "ibutils", parent => "ibutils",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["opensm-libs", "opensm-devel"],
            ofa_req_inst => ["libibcommon", "libibumad", "opensm-libs"],
            install32 => 0, exception => 0 },
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
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["opensm-devel"],
            ofa_req_inst => ["libibcommon", "libibumad", "libibmad", "opensm-libs"],
            install32 => 0, exception => 0 },
        'infiniband-diags-debuginfo' =>
            { name => "infiniband-diags-debuginfo", parent => "infiniband-diags",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'mpi-selector' =>
            { name => "mpi-selector", parent => "mpi-selector",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'mvapich' =>
            { name => "mvapich", parent => "mvapich",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'mvapich2' =>
            { name => "mvapich2", parent => "mvapich2",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'openmpi' =>
            { name => "openmpi", parent => "openmpi",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'mpitests' =>
            { name => "mpitests", parent => "mpitests",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'open-iscsi-generic' =>
            { name => ($distro eq 'SuSE') ? 'open-iscsi': 'iscsi-initiator-utils', parent => "open-iscsi-generic",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 1 },
        'open-iscsi' =>
            { name => "open-iscsi", parent => "open-iscsi-generic",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 1 },
        'iscsi-initiator-utils' =>
            { name => "iscsi-initiator-utils", parent => "open-iscsi-generic",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 1 },
        'open-iscsi-generic-debuginfo' =>
            { name => "open-iscsi-generic", parent => "open-iscsi-generic",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
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


my @hidden_packages = ("open-iscsi-generic", "ibvexdmtools");

my %MPI_SUPPORTED_COMPILERS = (gcc => 0, pgi => 0, intel => 0, pathscale => 0);

# for  my $key ( keys %MPI_SUPPORTED_COMPILERS ) {
#   print $key . ' = ' . $MPI_SUPPORTED_COMPILERS{$key} . "\n";
# }

while ( $#ARGV >= 0 ) {

   my $cmd_flag = shift(@ARGV);

    if ( $cmd_flag eq "-c" ) {
        $config = shift(@ARGV);
        $interactive = 0;
    } elsif ( $cmd_flag eq "-n" or $cmd_flag eq "--net" ) {
        $config_net = shift(@ARGV);
    } elsif ( $cmd_flag eq "-k" or $cmd_flag eq "--kernel" ) {
        $kernel = shift(@ARGV);
    } elsif ( $cmd_flag eq "-p" or $cmd_flag eq "--print-available" ) {
        $print_available = 1;
    } elsif ( $cmd_flag eq "-v" ) {
        $verbose = 1;
    } elsif ( $cmd_flag eq "-vv" ) {
        $verbose = 1;
        $verbose2 = 1;
    } elsif ( $cmd_flag eq "-vvv" ) {
        $verbose = 1;
        $verbose2 = 1;
        $verbose3 = 1;
    } else {
        &usage();
        exit 1;
    }
}

my $kernel_rel = $kernel;
$kernel_rel =~ s/-/_/;

# Set Linux Distribution
if ( -f "/etc/SuSE-release" ) {
    $distro = "SuSE";
}
elsif ( -f "/etc/fedora-release" ) {
    if ($kernel =~ m/fc6/) {
            $distro = "fedora6";
    }
    else {
            $distro = "fedora";
    }
}
elsif ( -f "/etc/rocks-release" ) {
    $distro = "Rocks";
}
elsif ( -f "/etc/redhat-release" ) {
    if ($kernel =~ m/el5/) {
        $distro = "redhat5";
    }
    else {
        open(DISTRO, "/etc/redhat-release");
        if (<DISTRO> =~ m/release\s5/) {
            $distro = "redhat5";
        }
        else {
            $distro = "redhat";
        }
        close DISTRO;
    }
}
elsif ( -f "/etc/debian_version" ) {
    $distro = "debian";
}
else {
    $distro = "unsupported";
}

sub getch
{
        my $c;
        system("stty -echo raw");
        $c=getc(STDIN);
        system("stty echo -raw");
        print "$c\n";
        return $c;
}

sub get_rpm_name_arch
{
    return `rpm --queryformat "[%{NAME}] [%{ARCH}]" -qp @_`;
}

sub get_rpm_info
{
    return `rpm --queryformat "[%{NAME}] [%{VERSION}] [%{RELEASE}] [%{DESCRIPTION}]" -qp @_`;
}

sub set_cfg
{
    my $srpm_full_path = shift @_;

    my $info = get_rpm_info($srpm_full_path);
    my $name = (split(/ /,$info,4))[0];

    ( $main_packages{$name}{'name'},
      $main_packages{$name}{'version'},
      $main_packages{$name}{'release'},
      $main_packages{$name}{'description'} ) = split(/ /,$info,4);
      $main_packages{$name}{'srpmpath'}   = $srpm_full_path;

    print "set_cfg: " .
             "name: $main_packages{$name}{'name'}, " .
             "version: $main_packages{$name}{'version'}, " .
             "release: $main_packages{$name}{'release'}, " .
             "srpmpath: $main_packages{$name}{'srpmpath'}\n" if ($verbose3);

}

# Set packages availability depending OS/Kernel/arch
sub set_availability
{
    # Ehca
    if ($arch =~ m/ppc64|powerpc/ and
            $kernel =~ m/2.6.1[6-9]|2.6.2[0-9]|2.6.9-55/) {
            $kernel_modules_info{'ehca'}{'available'} = 1;
            $packages_info{'libehca'}{'available'} = 1;
            $packages_info{'libehca-devel-static'}{'available'} = 1;
            $packages_info{'libehca-debuginfo'}{'available'} = 1;
    }

    # Ipath
    if ( ($arch =~ m/ppc64/ and
            $kernel =~ m/2.6.16.[0-9.]*-[0-9.]*-[A-Za-z0-9.]*|2.6.1[7-9]|2.6.2[0-9]/) or
       ($arch =~ m/x86_64/ and
            $kernel =~ m/2.6.5|2.6.9-22|2.6.9-34|2.6.9-42|2.6.9-55|2.6.16.[0-9.]*-[0-9.]*-[A-Za-z0-9.]*|2.6.1[7-9]|2.6.2[0-9]/) ) {
            $kernel_modules_info{'ipath'}{'available'} = 1;
            $packages_info{'libipathverbs'}{'available'} = 1;
            $packages_info{'libipathverbs-devel'}{'available'} = 1;
            $packages_info{'libipathverbs-debuginfo'}{'available'} = 1;
    }

    # Iser
    if ($kernel =~ m/2.6.9-34|2.6.9-42|2.6.9-55|2.6.16.[0-9.]*-[0-9.]*-[A-Za-z0-9.]*|el5/) {
            $kernel_modules_info{'iser'}{'available'} = 1;
            $packages_info{'open-iscsi-generic'}{'available'} = 1;
    }

    # Vnic
    if ($kernel =~ m/2.6.9-34|2.6.9-42|2.6.9-55|2.6.16.[0-9.]*-[0-9.]*-[A-Za-z0-9.]*|2.6.19/) {
            $kernel_modules_info{'vnic'}{'available'} = 1;
            $packages_info{'ibvexdmtools'}{'available'} = 1;
            $packages_info{'qlvnictools'}{'available'} = 1;
            $packages_info{'qlvnictools-debuginfo'}{'available'} = 1;
    }
}

# Set rpm_exist parameter for existing RPMs
sub set_existing_rpms
{
    for my $binrpm ( <$RPMS/*.rpm> ) {
        my ($rpm_name, $rpm_arch) = (split ' ', get_rpm_name_arch($binrpm));
        if ($rpm_arch eq $target_cpu) {
            $packages_info{$rpm_name}{'rpm_exist'} = 1;
            print "$rpm_name RPM exist\n" if ($verbose2);
        }
        else {
            $packages_info{$rpm_name}{'rpm_exist32'} = 1;
            print "$rpm_name 32-bit RPM exist\n" if ($verbose2);
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
        print "   2) HPC ($PACKAGE modules and libraries, MPI and diagnostic tools)\n";
        print "   3) All packages (all of Basic, HPC)\n";
        print "   4) Customize\n";
        print "\n   Q) Exit\n";
        $max_inp=4;
        print "\nSelect Option [1-$max_inp]:"
    }

    return $max_inp;
}

# Select package for installation
sub select_packages
{
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
        }
        elsif ($inp == 2) {
            $ok = 0;
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
            if ($inp == 1) {
                # BASIC packages
            }
            elsif ($inp == 2) {
                # HPC packages
            }
            elsif ($inp == 3) {
                # All packages
            }
            elsif ($inp == 4) {
                # Custom installation
                my $ans;
                open(CONFIG, "+>$config") || die "Can't open $config: $!";;
                flock CONFIG, $LOCK_EXCLUSIVE;
                for my $package ( @all_packages ) {
                    next if (not $packages_info{$package}{'available'});
                    print "Install $package? [y/N]:";
                    $ans = getch();
                    if ( $ans eq 'Y' or $ans eq 'y' ) {
                        print CONFIG "$package=y\n";
                        push (@selected_by_user, $package);

                        if ($package eq "kernel-ib") {
                            # Select kernel modules to be installed
                            for my $module ( @kernel_modules ) {
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
                print "Please enter the $PACKAGE installation directory: [$prefix]:";
                $ans = <STDIN>;
                chomp $ans;
                if ($ans) {
                    $prefix = $ans;
                }
                print CONFIG "prefix=$prefix\n";
            }
        }
        elsif ($inp == 3) {
        }
        elsif ($inp == 4) {
        }
        elsif ($inp == 5) {
        }

    }
    else {
        open(CONFIG, "$config") || die "Can't open $config: $!";
        flock CONFIG, $LOCK_EXCLUSIVE;
        while(<CONFIG>) {
            next if (m@^\s+$|^#.*@);
            my ($package,$selected) = (split '=', $_);
            chomp $package;
            chomp $selected;

            print "$package=$selected\n" if ($verbose3);

            if ($package eq "build32") {
                $build32 = 1 if ($selected);
                next;
            }

            if ($package eq "prefix") {
                $prefix = $selected;
                next;
            }

            if (not $packages_info{$package}{'parent'}) {
               print "Unsupported package: $package\n";
               next;
            }

            if (not $packages_info{$package}{'available'} and $selected eq 'y') {
                print "$package is not available on this platform\n";
                next;
            }

            if ( $selected eq 'y' ) {
                push (@selected_by_user, $package);
                print "select_package: selected $package\n" if ($verbose);
            }
        }
    }
    flock CONFIG, $UNLOCK;
    close(CONFIG);

}

sub select_dependent
{
    my $package = shift @_;

    if (not $packages_info{$package}{'rpm_exist'}) {
        for my $req ( @{ $packages_info{$package}{'ofa_req_build'} } ) {
            print "resolve_dependencies: $package requires $req for rpmbuild\n" if ($verbose2);
            if (not $packages_info{$req}{'selected'}) {
                select_dependent($req);
            }
        }
    }

    for my $req ( @{ $packages_info{$package}{'ofa_req_inst'} } ) {
        print "resolve_dependencies: $package requires $req for rpm install\n" if ($verbose2);
        if (not $packages_info{$req}{'selected'}) {
            select_dependent($req);
        }
    }

    if (not $packages_info{$package}{'selected'}) {
        $packages_info{$package}{'selected'} = 1;
        push (@selected_packages, $package);
        print "select_dependent: Selected package $package\n" if ($verbose2);
    }

}

sub resolve_dependencies
{
    for my $package ( @selected_by_user ) {
            # Get the list of dependencies
            select_dependent($package);
        }

    for my $module ( @selected_modules_by_user ) {
        for my $req ( @{ $kernel_modules_info{$module}{'requires'} } ) {
            print "resolve_dependencies: $module requires $req for rpmbuild\n" if ($verbose2);
            if (not $kernel_modules_info{$req}{'selected'}) {
                $kernel_modules_info{$req}{'selected'} = 1;
                push (@selected_kernel_modules, $req);
            }
        }
        push (@selected_kernel_modules, $module);
    }
}

# Print the list of selected packages
sub print_selected
{
    print "\nBelow is the list of ${PACKAGE} packages that you have chosen
    \r(some may have been added by the installer due to package dependencies):\n\n";
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

    $cmd = "rpmbuild --rebuild --define '_topdir $TOPDIR'";

    if ($name eq 'ofa_kernel') {
        for my $module ( @selected_kernel_modules ) {
            print "module $module\n";
            if ($module eq "core") {
                $kernel_configure_options .= " --with-core-mod --with-user_mad-mod --with-user_access-mod --with-addr_trans-mod";
            }
            elsif ($module eq "ipath") {
                $kernel_configure_options .= " --with-ipath_inf-mod";
            }
            else {
                $kernel_configure_options .= " --with-$module-mod";
            }
        }

        $cmd .= " --define 'configure_options $kernel_configure_options'";
        $cmd .= " --define 'build_kernel_ib 1'";
        $cmd .= " --define 'build_kernel_ib_devel 1'";
    }
    elsif ($name eq 'ib-bonding') {
        $cmd .= " --define 'KVERSION $kernel'";
        $cmd .= " --define '_release $kernel_rel'";
        $cmd .= " --define '_prefix $prefix'";
    }

    $cmd .= " $main_packages{$name}{'srpmpath'}";

    print "Running $cmd\n" if ($verbose);
    system("$cmd > $ofedlogs/$name.rpmbuild.log 2>&1");
    $res = $? >> 8;
    $sig = $? & 127;
    if ($sig or $res) {
        print RED "Failed to build $name RPM", RESET . "\n";
        print RED "See $ofedlogs/$name.rpmbuild.log", RESET . "\n";
        exit 1;
    }

    $TMPRPMS = "$TOPDIR/RPMS/$target_cpu";
    chomp $TMPRPMS;

    print "TMPRPMS $TMPRPMS\n" if ($verbose);

    for my $myrpm ( <$TMPRPMS/*.rpm> ) {
        print "Created $myrpm\n" if ($verbose2);
        my ($myrpm_name, $myrpm_arch) = (split ' ', get_rpm_name_arch($myrpm));
        move($myrpm, $RPMS);
        $packages_info{$myrpm_name}{'rpm_exist'} = 1;
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

    if (not $packages_info{$name}{'rpm_exist'}) {
        $cmd = "rpmbuild --rebuild --define '_topdir $TOPDIR'";
        $cmd .= " $main_packages{$name}{'srpmpath'}";

        print "Running $cmd\n" if ($verbose);
        system("$cmd > $ofedlogs/$name.rpmbuild.log 2>&1");
        $res = $? >> 8;
        $sig = $? & 127;
        if ($sig or $res) {
            print RED "Failed to build $name RPM", RESET . "\n";
            print RED "See $ofedlogs/$name.rpmbuild.log", RESET . "\n";
            exit 1;
        }

        $TMPRPMS = "$TOPDIR/RPMS/$target_cpu";
        chomp $TMPRPMS;

        print "TMPRPMS $TMPRPMS\n" if ($verbose);

        for my $myrpm ( <$TMPRPMS/*.rpm> ) {
            print "Created $myrpm\n" if ($verbose2);
            my ($myrpm_name, $myrpm_arch) = (split ' ', get_rpm_name_arch($myrpm));
            move($myrpm, $RPMS);
            $packages_info{$myrpm_name}{'rpm_exist'} = 1;
        }
    }

    if ($build32 and $packages_info{$name}{'install32'} and 
        not $packages_info{$name}{'rpm_exist32'}) {
        $cmd = "rpmbuild --rebuild --define '_topdir $TOPDIR'";
        $cmd .= " --define '_target_cpu $target_cpu32'";
        $cmd .= " --define '_target $target_cpu32-linux'";
        $cmd .= " --define '_prefix $prefix'";
        $cmd .= " --define '_lib lib'";
        $cmd .= " --define '__arch_install_post %{nil}'";
        $cmd .= " --define 'optflags -O2 -g -m32'";
        $cmd .= " $main_packages{$name}{'srpmpath'}";

        print "Running $cmd\n" if ($verbose);
        system("$cmd > $ofedlogs/$name.rpmbuild.log 2>&1");
        $res = $? >> 8;
        $sig = $? & 127;
        if ($sig or $res) {
            print RED "Failed to build $name RPM", RESET . "\n";
            print RED "See $ofedlogs/$name.rpmbuild.log", RESET . "\n";
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
}

sub install_kernel_rpm
{
    my $name = shift @_;
    my $cmd;
    my $res = 0;
    my $sig = 0;

    my $version = $main_packages{$packages_info{$name}{'parent'}}{'version'};
    # my $release = $main_packages{$packages_info{$name}{'parent'}}{'release'};
    my $release = $kernel_rel;

    my $package = "$RPMS/$name-$version-$release.$target_cpu.rpm";

    if (not -f $package) {
        print RED "$package does not exist", RESET . "\n";
        exit 1;
    }

    $cmd = "rpm -iv";
    $cmd .= " $package";

    print "Running $cmd\n" if ($verbose);
    system("$cmd > $ofedlogs/$name.rpminstall.log 2>&1");
    $res = $? >> 8;
    $sig = $? & 127;
    if ($sig or $res) {
        print RED "Failed to install $name RPM", RESET . "\n";
        print RED "See $ofedlogs/$name.rpminstall.log", RESET . "\n";
        exit 1;
    }
}

# Install required RPM
sub install_rpm
{
    my $name = shift @_;
    my $cmd;
    my $res = 0;
    my $sig = 0;
    my $package;

    my $version = $main_packages{$packages_info{$name}{'parent'}}{'version'};
    my $release = $main_packages{$packages_info{$name}{'parent'}}{'release'};

    $package = "$RPMS/$name-$version-$release.$target_cpu.rpm";

    if (not -f $package) {
        print RED "$package does not exist", RESET . "\n";
        exit 1;
    }
    $cmd = "rpm -iv";
    $cmd .= " $package";

    print "Running $cmd\n" if ($verbose);
    system("$cmd > $ofedlogs/$name.rpminstall.log 2>&1");
    $res = $? >> 8;
    $sig = $? & 127;
    if ($sig or $res) {
        print RED "Failed to install $name RPM", RESET . "\n";
        print RED "See $ofedlogs/$name.rpminstall.log", RESET . "\n";
        exit 1;
    }

    if ($build32 and $packages_info{$name}{'install32'}) {
        $package = "$RPMS/$name-$version-$release.$target_cpu32.rpm";
        if (not -f $package) {
            print RED "$package does not exist", RESET . "\n";
            # exit 1;
        }
        $cmd = "rpm -iv";
        $cmd .= " $package";

        print "Running $cmd\n" if ($verbose);
        system("$cmd > $ofedlogs/$name.rpminstall.log 2>&1");
        $res = $? >> 8;
        $sig = $? & 127;
        if ($sig or $res) {
            print RED "Failed to install $name RPM", RESET . "\n";
            print RED "See $ofedlogs/$name.rpminstall.log", RESET . "\n";
            exit 1;
        }
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

sub is_installed
{
    my $res = 0;
    my $name = shift @_;
    
    system("rpm -q $name > /dev/null 2>&1");
    $res = $? >> 8;

    return not $res;
}

sub uninstall
{
    my $res = 0;
    my $sig = 0;
    my $cnt = 0;
    system("ofed_uninstall.sh > $ofedlogs/ofed_uninstall.log 2>&1");
    $res = $? >> 8;
    $sig = $? & 127;
    if ($sig or $res) {
        my $cmd = "rpm -e --allmatches";
        for my $package (@all_packages, @hidden_packages) {
            if (is_installed($packages_info{$package}{'name'})) {
                $cmd .= " $packages_info{$package}{'name'}";
                $cnt ++;
            }
        }
        if ($cnt) {
            print "Uninstalling the previous version of $PACKAGE\n";
            print "Running $cmd\n" if ($verbose);
            system("$cmd >> $ofedlogs/ofed_uninstall.log 2>&1");
            $res = $? >> 8;
            $sig = $? & 127;
            if ($sig or $res) {
                print RED "Failed to uninstall the previous installation", RESET . "\n";
                print RED "See $ofedlogs/ofed_uninstall.log", RESET . "\n";
                exit 1;
            }
        }
    }
}

### MAIN AREA ###
if ($print_available) {
    set_availability();
    for my $package ( @all_packages, @hidden_packages) {
        next if (not $packages_info{$package}{'available'});
        if ($package eq "kernel-ib") {
            print "Kernel modules: ";
            for my $module ( @kernel_modules ) {
                next if (not $kernel_modules_info{$module}{'available'});
                print $module . ' ';
            }
            print "\nOther packages: ";
        }
        print $package . ' ';
    }
    print "\n";
    exit 0;
}

print BLUE "Detected Linux Distribution: $distro", RESET . "\n" if ($verbose);
# Set RPMs info for available source RPMs
for my $srcrpm ( <$SRPMS*> ) {
    set_cfg ($srcrpm);
}

set_existing_rpms();
set_availability();
select_packages();
resolve_dependencies();
print_selected();

# Uninstall the previous installations
uninstall();

# Build and install selected RPMs
print "Build and install selected_packages: @selected_packages\n";
for my $package ( @selected_packages) {
    if ($packages_info{$package}{'mode'} eq "user") {
        if (not $packages_info{$package}{'exception'}) {
            if ( (not $packages_info{$package}{'rpm_exist'}) or 
                 ($build32 and $packages_info{$package}{'install32'} and 
                  not $packages_info{$package}{'rpm_exist32'}) ) {
                my $parent = $packages_info{$package}{'parent'};
                print "Build $parent RPM\n" if ($verbose);
                build_rpm($parent);
            }

            if ( (not $packages_info{$package}{'rpm_exist'}) or 
                 ($build32 and $packages_info{$package}{'install32'} and 
                  not $packages_info{$package}{'rpm_exist32'}) ) {
                print RED "$package was not created", RESET . "\n";
                exit 1;
            }
            print "Install $package RPM\n" if ($verbose);
            install_rpm($package);
        }
        else {
            if ($package eq "open-iscsi-generic") {
                my $real_name = $packages_info{$package}{'name'};
                print "open-iscsi-generic real name: $real_name rpm_exist: $packages_info{$real_name}{'rpm_exist'}\n";
                if (not $packages_info{$real_name}{'rpm_exist'}) {
                    my $parent = $packages_info{$real_name}{'parent'};
                    print "Build $parent RPM\n" if ($verbose);
                    build_rpm($parent);
                }
                if (not $packages_info{$real_name}{'rpm_exist'}) {
                    print RED "$real_name was not created", RESET . "\n";
                    exit 1;
                }
                print "Install $real_name RPM\n" if ($verbose);
                install_rpm($real_name);
            }
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
            print RED "$package was not created", RESET . "\n";
            exit 1;
        }
        print "Install $package RPM\n" if ($verbose);
        install_kernel_rpm($package);
    }
}
