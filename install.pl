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
my $verbose = 1;
my $verbose2 = 0;
my $verbose3 = 0;

my $print_available = 0;

my $clear_string = `clear`;
my $upgrade_open_iscsi = 0;

my $distro;

my $build32 = 0;
my $arch = `uname -m`;
chomp $arch;
my $kernel = `uname -r`;
chomp $kernel;
my $kernel_sources = "/lib/modules/$kernel/build";
chomp $kernel_sources;

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

sub usage
{
   print BLUE;
   print "\n Usage: $0 [-c <packages config_file>|--all|--hpc|--basic] [-n|--net <network config_file>]\n";
   print "\n           -c|--config <packages config_file>. Example of the config file can be found under docs.";
   print "\n           --all|--hpc|--basic Install all,hpc or basic packages correspondently";
   print "\n           [-p|--print-available <kernel version>]";
   print "\n           [-k|--kernel <kernel version>]. Default $kernel";
   print "\n           [-s|--kernel-sources <path to the kernel sources>]. Default $kernel_sources";
   print RESET "\n\n";
}

# List of all available packages sorted following dependencies
my @kernel_packages = ("kernel-ib", "kernel-ib-devel", "ib-bonding", "ib-bonding-debuginfo");
my @basic_kernel_modules = ("core", "mthca", "mlx4", "cxgb3", "ehca", "ipath", "ipoib");
my @ulp_modules = ("sdp", "srp", "rds", "vnic", "iser");
my @kernel_modules = (@basic_kernel_modules, @ulp_modules);

my $kernel_configure_options;
my $user_configure_options;

my @misc_packages = ("ofed-docs", "ofed-scripts");

my @mpitests_packages = (
                     "mpitests_mvapich_gcc", "mpitests_mvapich_pgi", "mpitests_mvapich_intel", "mpitests_mvapich_pathscale", 
                     "mpitests_mvapich2_gcc", "mpitests_mvapich2_pgi", "mpitests_mvapich2_intel", "mpitests_mvapich2_pathscale", 
                     "mpitests_openmpi_gcc", "mpitests_openmpi_pgi", "mpitests_openmpi_intel", "mpitests_openmpi_pathscale" 
                    );

my @mpi_packages = ( "mpi-selector",
                     "mvapich_gcc", "mvapich_pgi", "mvapich_intel", "mvapich_pathscale", 
                     "mvapich2_gcc", "mvapich2_pgi", "mvapich2_intel", "mvapich2_pathscale", 
                     "openmpi_gcc", "openmpi_pgi", "openmpi_intel", "openmpi_pathscale", 
                     @mpitests_packages
                    );

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
                     "librdmacm", "librdmacm-utils", "librdmacm-devel", "librdmacm-debuginfo",
                     "libsdp", "libsdp-devel", "libsdp-debuginfo",
                     "opensm", "opensm-libs", "opensm-devel", "opensm-debuginfo", "opensm-static",
                     "perftest", "mstflint", "tvflash",
                     "qlvnictools", "sdpnetstat", "srptools", "rds-tools",
                     "ibutils", "infiniband-diags",
                     "ofed-docs", "ofed-scripts", @mpi_packages
                     );

my @basic_kernel_packages = ("kernel-ib");
my @basic_user_packages = ("libibverbs", "libibverbs-utils", "libmthca", "libmlx4",
                            "libehca", "libcxgb3", @misc_packages);

my @hpc_kernel_packages = ("kernel-ib", "ib-bonding");
my @hpc_kernel_modules = (@basic_kernel_modules);
my @hpc_user_packages = (@basic_user_packages, "librdmacm",
                        "librdmacm-utils", "dapl", "dapl-utils",
                        "infiniband-diags", "ibutils", @mpi_packages);

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
            included_in_rpm => 0, requires => ["core", "ipoib"], ofa_req_inst => ["open-iscsi-generic"] },
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
            available => 0, mode => "kernel", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [], ofa_req_inst => [], },
        'ib-bonding-debuginfo' =>
            { name => "ib-bonding-debuginfo", parent => "ib-bonding",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "kernel", dist_req_build => [],
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
            dist_req_inst => [], ofa_req_build => ["libibverbs","libibverbs-devel"],
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
            dist_req_inst => [], ofa_req_build => ["libibverbs-devel"],
            ofa_req_inst => ["libibverbs"],
            install32 => 1, exception => 0 },
        'libehca-devel-static' =>
            { name => "libehca-devel-static", parent => "libehca",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs-devel"],
            ofa_req_inst => ["libibverbs", "libehca"],
            install32 => 1, exception => 0 },
        'libehca-debuginfo' =>
            { name => "libehca-debuginfo", parent => "libehca",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
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
        'librdmacm-utils' =>
            { name => "librdmacm-utils", parent => "librdmacm",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => ["librdmacm"],
            install32 => 0, exception => 0 },
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
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },
        'mvapich_gcc' =>
            { name => "mvapich_gcc", parent => "mvapich",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => ["mpi-selector", "libibverbs", "libibcommon", "libibumad"],
            install32 => 0, exception => 0 },
        'mvapich_pgi' =>
            { name => "mvapich_pgi", parent => "mvapich",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => ["mpi-selector", "libibverbs", "libibcommon", "libibumad"],
            install32 => 0, exception => 0 },
        'mvapich_intel' =>
            { name => "mvapich_intel", parent => "mvapich",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => ["mpi-selector", "libibverbs", "libibcommon", "libibumad"],
            install32 => 0, exception => 0 },
        'mvapich_pathscale' =>
            { name => "mvapich_pathscale", parent => "mvapich",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => ["mpi-selector", "libibverbs", "libibcommon", "libibumad"],
            install32 => 0, exception => 0 },

        'mvapich2' =>
            { name => "mvapich2", parent => "mvapich2",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },
        'mvapich2_gcc' =>
            { name => "mvapich2_gcc", parent => "mvapich2",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => ["mpi-selector", "librdmacm", "libibumad"],
            install32 => 0, exception => 0 },
        'mvapich2_pgi' =>
            { name => "mvapich2_pgi", parent => "mvapich2",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => ["mpi-selector", "librdmacm", "libibumad"],
            install32 => 0, exception => 0 },
        'mvapich2_intel' =>
            { name => "mvapich2_intel", parent => "mvapich2",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => ["mpi-selector", "librdmacm", "libibumad"],
            install32 => 0, exception => 0 },
        'mvapich2_pathscale' =>
            { name => "mvapich2_pathscale", parent => "mvapich2",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => ["mpi-selector", "librdmacm", "libibumad"],
            install32 => 0, exception => 0 },

        'openmpi' =>
            { name => "openmpi", parent => "openmpi",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },
        'openmpi_gcc' =>
            { name => "openmpi_gcc", parent => "openmpi",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => ["mpi-selector"],
            install32 => 0, exception => 0 },
        'openmpi_pgi' =>
            { name => "openmpi_pgi", parent => "openmpi",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => ["mpi-selector"],
            install32 => 0, exception => 0 },
        'openmpi_intel' =>
            { name => "openmpi_intel", parent => "openmpi",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => ["mpi-selector"],
            install32 => 0, exception => 0 },
        'openmpi_pathscale' =>
            { name => "openmpi_pathscale", parent => "openmpi",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => ["mpi-selector"],
            install32 => 0, exception => 0 },

        'mpitests' =>
            { name => "mpitests", parent => "mpitests",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => [],
            install32 => 0, exception => 0 },

        'mpitests_mvapich_gcc' =>
            { name => "mpitests_mvapich_gcc", parent => "mpitests",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["mvapich_gcc", "libibumad-devel", "librdmacm-devel"],
            ofa_req_inst => ["mvapich_gcc"],
            install32 => 0, exception => 0 },
        'mpitests_mvapich_pgi' =>
            { name => "mpitests_mvapich_pgi", parent => "mpitests",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["mvapich_pgi", "libibumad-devel", "librdmacm-devel"],
            ofa_req_inst => ["mvapich_pgi"],
            install32 => 0, exception => 0 },
        'mpitests_mvapich_pathscale' =>
            { name => "mpitests_mvapich_pathscale", parent => "mpitests",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["mvapich_pathscale", "libibumad-devel", "librdmacm-devel"],
            ofa_req_inst => ["mvapich_pathscale"],
            install32 => 0, exception => 0 },
        'mpitests_mvapich_intel' =>
            { name => "mpitests_mvapich_intel", parent => "mpitests",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["mvapich_intel", "libibumad-devel", "librdmacm-devel"],
            ofa_req_inst => ["mvapich_intel"],
            install32 => 0, exception => 0 },

        'mpitests_mvapich2_gcc' =>
            { name => "mpitests_mvapich2_gcc", parent => "mpitests",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["mvapich2_gcc", "libibumad-devel", "librdmacm-devel"],
            ofa_req_inst => ["mvapich2_gcc"],
            install32 => 0, exception => 0 },
        'mpitests_mvapich2_pgi' =>
            { name => "mpitests_mvapich2_pgi", parent => "mpitests",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["mvapich2_pgi", "libibumad-devel", "librdmacm-devel"],
            ofa_req_inst => ["mvapich2_pgi"],
            install32 => 0, exception => 0 },
        'mpitests_mvapich2_pathscale' =>
            { name => "mpitests_mvapich2_pathscale", parent => "mpitests",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["mvapich2_pathscale", "libibumad-devel", "librdmacm-devel"],
            ofa_req_inst => ["mvapich2_pathscale"],
            install32 => 0, exception => 0 },
        'mpitests_mvapich2_intel' =>
            { name => "mpitests_mvapich2_intel", parent => "mpitests",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["mvapich2_intel", "libibumad-devel", "librdmacm-devel"],
            ofa_req_inst => ["mvapich2_intel"],
            install32 => 0, exception => 0 },

        'mpitests_openmpi_gcc' =>
            { name => "mpitests_openmpi_gcc", parent => "mpitests",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["openmpi_gcc", "libibumad-devel", "librdmacm-devel"],
            ofa_req_inst => ["openmpi_gcc"],
            install32 => 0, exception => 0 },
        'mpitests_openmpi_pgi' =>
            { name => "mpitests_openmpi_pgi", parent => "mpitests",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["openmpi_pgi", "libibumad-devel", "librdmacm-devel"],
            ofa_req_inst => ["openmpi_pgi"],
            install32 => 0, exception => 0 },
        'mpitests_openmpi_pathscale' =>
            { name => "mpitests_openmpi_pathscale", parent => "mpitests",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["openmpi_pathscale", "libibumad-devel", "librdmacm-devel"],
            ofa_req_inst => ["openmpi_pathscale"],
            install32 => 0, exception => 0 },
        'mpitests_openmpi_intel' =>
            { name => "mpitests_openmpi_intel", parent => "mpitests",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 0, mode => "user", dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["openmpi_intel", "libibumad-devel", "librdmacm-devel"],
            ofa_req_inst => ["openmpi_intel"],
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

my %gcc = ('gcc' => 0, 'gfortran' => 0, 'g77' => 0, 'g++' => 0);
my %pathscale = ('pathcc' => 0, 'pathCC' => 0, 'pathf90' => 0);
my %pgi = ('pgf77' => 0, 'pgf90' => 0, 'pgCC' => 0); 
my %intel = ('icc' => 0, 'icpc' => 0, 'ifort' => 0); 

# mvapich2 environment
my $mvapich2_conf_impl = "ofa";
my $mvapich2_conf_romio = 1;
my $mvapich2_conf_shared_libs = 1;
my $mvapich2_conf_multithread = 0;
my $mvapich2_conf_ckpt = 0;
my $mvapich2_conf_blcr_home;
my $mvapich2_conf_vcluster = "small";
my $mvapich2_conf_io_bus;
my $mvapich2_conf_link_speed;
my $mvapich2_conf_dapl_provider = "ib0";
my $mvapich2_comp_env;
my $mvapich2_dat_lib;
my $mvapich2_dat_include;
my $mvapich2_conf_done = 0;

my $config_given = 0;
my $install_option;

while ( $#ARGV >= 0 ) {

   my $cmd_flag = shift(@ARGV);

    if ( $cmd_flag eq "-c" or $cmd_flag eq "--config" ) {
        $config = shift(@ARGV);
        $interactive = 0;
        $config_given = 1;
    } elsif ( $cmd_flag eq "-n" or $cmd_flag eq "--net" ) {
        $config_net = shift(@ARGV);
    } elsif ( $cmd_flag eq "-k" or $cmd_flag eq "--kernel" ) {
        $kernel = shift(@ARGV);
    } elsif ( $cmd_flag eq "-s" or $cmd_flag eq "--kernel-sources" ) {
        $kernel_sources = shift(@ARGV);
    } elsif ( $cmd_flag eq "-p" or $cmd_flag eq "--print-available" ) {
        $print_available = 1;
    } elsif ( $cmd_flag eq "--all" ) {
        $interactive = 0;
        $install_option = 'all';
    } elsif ( $cmd_flag eq "--hpc" ) {
        $interactive = 0;
        $install_option = 'hpc';
    } elsif ( $cmd_flag eq "--basic" ) {
        $interactive = 0;
        $install_option = 'basic';
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

if ($config_given and $install_option) {
    print RED "\nError: '-c' option can't be used with '--all|--hpc|--basic'", RESET "\n";
    exit 1;
}

my $kernel_rel = $kernel;
$kernel_rel =~ s/-/_/g;

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

# Check whether compiler $1 exist
sub set_compilers
{
    if (`which gcc 2> /dev/null`) {
        $gcc{'gcc'} = 1;
    }
    if (`which g77 2> /dev/null`) {
        $gcc{'g77'} = 1;
    }
    if (`which g++ 2> /dev/null`) {
        $gcc{'g++'} = 1;
    }
    if (`which gfortran 2> /dev/null`) {
        $gcc{'gfortran'} = 1;
    }

    if (`which pathcc 2> /dev/null`) {
        $pathscale{'pathcc'} = 1;
    }
    if (`which pathCC 2> /dev/null`) {
        $pathscale{'pathCC'} = 1;
    }
    if (`which pathf90 2> /dev/null`) {
        $pathscale{'pathf90'} = 1;
    }

    if (`which pgcc 2> /dev/null`) {
        $pgi{'pgcc'} = 1;
    }
    if (`which pgCC 2> /dev/null`) {
        $pgi{'pgCC'} = 1;
    }
    if (`which pgf77 2> /dev/null`) {
        $pgi{'pgf77'} = 1;
    }
    if (`which pgf90 2> /dev/null`) {
        $pgi{'pgf90'} = 1;
    }

    if (`which icc 2> /dev/null`) {
        $intel{'icc'} = 1;
    }
    if (`which icpc 2> /dev/null`) {
        $intel{'icpc'} = 1;
    }
    if (`which ifort 2> /dev/null`) {
        $intel{'ifort'} = 1;
    }
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
    set_compilers();

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

    # ib-bonding
    if ($kernel =~ m/2.6.9-34|2.6.9-42|2.6.9-55|2.6.16.[0-9.]*-[0-9.]*-[A-Za-z0-9.]*|el5|fc6/) {
            $packages_info{'ib-bonding'}{'available'} = 1;
            $packages_info{'ib-bonding-debuginfo'}{'available'} = 1;
    }

    # mvapich, mvapich2 and openmpi
    if ($gcc{'gcc'}) {
        if ($gcc{'g77'} or $gcc{'gfortran'}) {
            $packages_info{'mvapich_gcc'}{'available'} = 1;
            $packages_info{'mvapich2_gcc'}{'available'} = 1;
            $packages_info{'mpitests_mvapich_gcc'}{'available'} = 1;
            $packages_info{'mpitests_mvapich2_gcc'}{'available'} = 1;
        }
        $packages_info{'openmpi_gcc'}{'available'} = 1;
        $packages_info{'mpitests_openmpi_gcc'}{'available'} = 1;
    }
    if ($pathscale{'pathcc'}) {
        if ($pathscale{'pathCC'} and $pathscale{'pathf90'}) {
            $packages_info{'mvapich_pathscale'}{'available'} = 1;
            $packages_info{'mvapich2_pathscale'}{'available'} = 1;
            $packages_info{'mpitests_mvapich_pathscale'}{'available'} = 1;
            $packages_info{'mpitests_mvapich2_pathscale'}{'available'} = 1;
        }
        $packages_info{'openmpi_pathscale'}{'available'} = 1;
        $packages_info{'mpitests_openmpi_pathscale'}{'available'} = 1;
    }
    if ($pgi{'pgcc'}) {
        if ($pgi{'pgf77'} and $pgi{'pgf90'}) {
            $packages_info{'mvapich_pgi'}{'available'} = 1;
            $packages_info{'mvapich2_pgi'}{'available'} = 1;
            $packages_info{'mpitests_mvapich_pgi'}{'available'} = 1;
            $packages_info{'mpitests_mvapich2_pgi'}{'available'} = 1;
        }
        $packages_info{'openmpi_pgi'}{'available'} = 1;
        $packages_info{'mpitests_openmpi_pgi'}{'available'} = 1;
    }
    if ($intel{'icc'}) {
        if ($intel{'icpc'} and $intel{'ifort'}) {
            $packages_info{'mvapich_intel'}{'available'} = 1;
            $packages_info{'mvapich2_intel'}{'available'} = 1;
            $packages_info{'mpitests_mvapich_intel'}{'available'} = 1;
            $packages_info{'mpitests_mvapich2_intel'}{'available'} = 1;
        }
        $packages_info{'openmpi_intel'}{'available'} = 1;
        $packages_info{'mpitests_openmpi_intel'}{'available'} = 1;
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

sub mvapich2_config
{
    my $ans;
    my $done;

    if ($mvapich2_conf_done) {
        return;
    }

    if (not $interactive) {
        $mvapich2_conf_done = 1;
        return;
    }

    print "\nPlease choose an implementation of MVAPICH2:\n\n";
    print "1) OFA (IB and iWARP)\n";
    print "2) uDAPL\n";
    $done = 0;
    while (not $done) {
        print "Implementation [1]: ";
        $ans = getch();
        if (ord($ans) == $KEY_ENTER or $ans eq "1") {
            $mvapich2_conf_impl = "ofa";
            $done = 1;
        }
        elsif ($ans eq "2") {
            $mvapich2_conf_impl = "udapl";
            $done = 1;
        }
        else {
            $done = 0;
        }
    }

    print "\nEnable ROMIO support [Y/n]: ";
    $ans = getch();
    if ($ans =~ m/Nn/) {
        $mvapich2_conf_romio = 0;
    }
    else {
        $mvapich2_conf_romio = 1;
    }

    print "\nEnable shared library support [Y/n]: ";
    $ans = getch();
    if ($ans =~ m/Nn/) {
        $mvapich2_conf_shared_libs = 0;
    }
    else {
        $mvapich2_conf_shared_libs = 1;
    }

    print "\nMultithread support should only be enabled only if thread safety is required.";
    print "\nThere may be a slight performance penalty for single threaded only use.";

    print "\nEnable multithread support [y/N]: ";
    $ans = getch();
    if ($ans =~ m/Yy/) {
        $mvapich2_conf_multithread = 1;
    }
    else {
        $mvapich2_conf_multithread = 0;
    }

    # OFA specific options.
    if ($mvapich2_conf_impl eq "ofa" and not $mvapich2_conf_multithread) {
        $done = 0;
        while (not $done) {
            print "\nEnable Checkpoint-Restart support [y/N]: ";
            $ans = getch();
            if ($ans =~ m/[Yy]/) {
                $mvapich2_conf_ckpt = 1;
                print "\nBLCR installation directory [or nothing if not installed]: ";
                my $tmp = <STDIN>;
                if (-d "$tmp") {
                    $mvapich2_conf_blcr_home = $tmp;
                    $done = 1;
                }
                else {
                    print RED "\nBLCR installation directory not found.", RESET "\n";
                }
            }
            else {
                $mvapich2_conf_ckpt = 0;
                $done = 1;
            }
        }
    }
    else {
        $mvapich2_conf_ckpt = 0;
    }

    # uDAPL specific options.
    if ($mvapich2_conf_impl eq "udapl") {
        print "\nCluster size:\n\n1) Small\n2) Medium\n3) Large\n";
        $done = 0;
        while (not $done) {
            print "Cluster size [1]: ";
            $ans = getch();
            if (ord($ans) == $KEY_ENTER or $ans eq "1") {
                $mvapich2_conf_vcluster = "small";
                $done = 1;
            }
            elsif ($ans eq "2") {
                $mvapich2_conf_vcluster = "medium";
                $done = 1;
            }
            elsif ($ans eq "3") {
                $mvapich2_conf_vcluster = "large";
                $done = 1;
            }
        }

        print "\nI/O Bus:\n\n1) PCI-Express\n2) PCI-X\n";
        $done = 0;
        while (not $done) {
            print "I/O Bus [1]: ";
            $ans = getch();
            if (ord($ans) == $KEY_ENTER or $ans eq "1") {
                $mvapich2_conf_io_bus = "pci-ex";
                $done = 1;
            }
            elsif ($ans eq "2") {
                $mvapich2_conf_io_bus = "pci-x";
                $done = 1;
            }
        }

        if ($mvapich2_conf_io_bus eq "pci-ex") {
            print "\nLink Speed:\n\n1) SDR\n2) DDR\n";
            $done = 0;
            while (not $done) {
                print "Link Speed [1]: ";
                $ans = getch();
                if (ord($ans) == $KEY_ENTER or $ans eq "1") {
                    $mvapich2_conf_link_speed = "sdr";
                    $done = 1;
                }
                elsif ($ans eq "2") {
                    $mvapich2_conf_link_speed = "ddr";
                    $done = 1;
                }
            }
        }
        else {
            $mvapich2_conf_link_speed = "sdr";
        }

        print "\nDefault DAPL provider [ib0]: ";
        $ans = <STDIN>;
        if ($ans) {
            $mvapich2_conf_dapl_provider = $ans;
        }
    }
    $mvapich2_conf_done = 1;

    open(CONFIG, ">>$config") || die "Can't open $config: $!";;
    flock CONFIG, $LOCK_EXCLUSIVE;

    print CONFIG "mvapich2_conf_impl=$mvapich2_conf_impl\n";
    print CONFIG "mvapich2_conf_romio=$mvapich2_conf_romio\n";
    print CONFIG "mvapich2_conf_shared_libs=$mvapich2_conf_shared_libs\n";
    print CONFIG "mvapich2_conf_multithread=$mvapich2_conf_multithread\n";

    print CONFIG "mvapich2_conf_ckpt=$mvapich2_conf_ckpt\n";
    print CONFIG "mvapich2_conf_blcr_home=$mvapich2_conf_blcr_home\n" if ($mvapich2_conf_blcr_home);
    print CONFIG "mvapich2_conf_vcluster=$mvapich2_conf_vcluster\n";
    print CONFIG "mvapich2_conf_io_bus=$mvapich2_conf_io_bus\n" if ($mvapich2_conf_io_bus);
    print CONFIG "mvapich2_conf_link_speed=$mvapich2_conf_link_speed\n" if ($mvapich2_conf_link_speed);
    print CONFIG "mvapich2_conf_dapl_provider=$mvapich2_conf_dapl_provider\n" if ($mvapich2_conf_dapl_provider);

    flock CONFIG, $UNLOCK;
    close(CONFIG);
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
    my $cnt = 0;
    if ($interactive) {
        open(CONFIG, ">>$config") || die "Can't open $config: $!";;
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
        elsif ($inp == $HPC) {
            for my $package ( @hpc_user_packages, @hpc_kernel_packages ) {
                next if (not $packages_info{$package}{'available'});
                push (@selected_by_user, $package);
                print CONFIG "$package=y\n";
                $cnt ++;
            }
            for my $module ( @hpc_kernel_modules ) {
                next if (not $kernel_modules_info{$module}{'available'});
                push (@selected_modules_by_user, $module);
                print CONFIG "$module=y\n";
            }
        }
        elsif ($inp == $ALL) {
            for my $package ( @all_packages ) {
                next if (not $packages_info{$package}{'available'});
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
                print "Install $package? [y/N]:";
                $ans = getch();
                if ( $ans eq 'Y' or $ans eq 'y' ) {
                    print CONFIG "$package=y\n";
                    push (@selected_by_user, $package);
                    $cnt ++;

                    if ($package eq "kernel-ib") {
                        # Select kernel modules to be installed
                        for my $module ( @kernel_modules ) {
                            next if (not $kernel_modules_info{$module}{'available'});
                            if ($module eq "iser") {
                                print "Install $module module? (open-iscsi will also be installed) [y/N]:";
                                $ans = getch();
                                if ( $ans eq 'Y' or $ans eq 'y' ) {
                                    push (@selected_modules_by_user, $module);
                                    print CONFIG "$module=y\n";
                                    check_open_iscsi();
                                    if ($upgrade_open_iscsi) {
                                        print CONFIG "upgrade_open_iscsi=yes\n";
                                    }
                                }
                            }
                            else {
                                print "Install $module module? [y/N]:";
                                $ans = getch();
                                if ( $ans eq 'Y' or $ans eq 'y' ) {
                                    push (@selected_modules_by_user, $module);
                                    print CONFIG "$module=y\n";
                                }
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
    else {
        if ($config_given) {
            open(CONFIG, "$config") || die "Can't open $config: $!";;
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

                if ($package eq "upgrade_open_iscsi") {
                    if ($selected =~ m/[Yy]|[Yy][Ee][Ss]/) {
                        $upgrade_open_iscsi = 1;
                    }
                    next;
                }

                if ($package eq "kernel_configure_options") {
                    $kernel_configure_options = $selected;
                }

                if ($package eq "user_configure_options") {
                    $user_configure_options = $selected;
                }

                # mvapich2 configuration environment
                if ($package eq "mvapich2_conf_impl") {
                    $mvapich2_conf_impl = $selected;
                }
                elsif ($package eq "mvapich2_conf_romio") {
                    $mvapich2_conf_romio = $selected;
                }
                elsif ($package eq "mvapich2_conf_shared_libs") {
                    $mvapich2_conf_shared_libs = $selected;
                }
                elsif ($package eq "mvapich2_conf_multithread") {
                    $mvapich2_conf_multithread = $selected;
                }
                elsif ($package eq "mvapich2_conf_ckpt") {
                    $mvapich2_conf_ckpt = $selected;
                }
                elsif ($package eq "mvapich2_conf_blcr_home") {
                    $mvapich2_conf_blcr_home = $selected;
                }
                elsif ($package eq "mvapich2_conf_vcluster") {
                    $mvapich2_conf_vcluster = $selected;
                }
                elsif ($package eq "mvapich2_conf_io_bus") {
                    $mvapich2_conf_io_bus = $selected;
                }
                elsif ($package eq "mvapich2_conf_link_speed") {
                    $mvapich2_conf_link_speed = $selected;
                }
                elsif ($package eq "mvapich2_conf_dapl_provider") {
                    $mvapich2_conf_dapl_provider = $selected;
                }

                if (not $packages_info{$package}{'parent'}) {
                    my $modules = "@kernel_modules";
                    chomp $modules;
                    $modules =~ s/ /|/g;
                    if ($package =~ m/$modules/) {
                        if ( $selected eq 'y' ) {
                            push (@selected_modules_by_user, $package);
                            next;
                        }
                    }
                    else {
                       print "Unsupported package: $package\n";
                       next;
                    }
                }

                if (not $packages_info{$package}{'available'} and $selected eq 'y') {
                    print "$package is not available on this platform\n";
                    next;
                }

                if ( $selected eq 'y' ) {
                    push (@selected_by_user, $package);
                    print "select_package: selected $package\n" if ($verbose2);
                    $cnt ++;
                }
            }
        }
        else {
            if ($install_option eq 'all') {
                for my $package ( @all_packages ) {
                    next if (not $packages_info{$package}{'available'});
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
            elsif ($install_option eq 'hpc') {
                for my $package ( @hpc_user_packages, @hpc_kernel_packages ) {
                    next if (not $packages_info{$package}{'available'});
                    push (@selected_by_user, $package);
                    print CONFIG "$package=y\n";
                    $cnt ++;
                }
                for my $module ( @hpc_kernel_modules ) {
                    next if (not $kernel_modules_info{$module}{'available'});
                    push (@selected_modules_by_user, $module);
                    print CONFIG "$module=y\n";
                }
            }
            elsif ($install_option eq 'basic') {
                for my $package (@basic_user_packages, @basic_kernel_packages) {
                    next if (not $packages_info{$package}{'available'});
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
                print RED "\nUnsupported installation option: $install_option", RESET "\n";
                exit 1;
            }
        }

        # Check open-iscsi package if iser module selected for installation
        my $tmp = "@selected_modules_by_user";
        $tmp =~ s/ /|/g;
        chomp $tmp;
        if ("iser" =~ m/$tmp/) {
            check_open_iscsi();
        }
    }
    flock CONFIG, $UNLOCK;
    close(CONFIG);

    
    return $cnt;
}

sub module_in_rpm
{
    my $module = shift @_;
    my $ret = 1;

    my $name = 'kernel-ib';
    my $version = $main_packages{$packages_info{$name}{'parent'}}{'version'};
    my $release = $kernel_rel;

    my $package = "$RPMS/$name-$version-$release.$target_cpu.rpm";

    if (not -f $package) {
        print "is_module_in_rpm: $package not found\n";
        return 1;
    }

    print "is_module_in_rpm: rpm -qlp $package\n";
    open(LIST, "rpm -qlp $package |") or die "Can't run 'rpm -qlp $package': $!\n";
    while (<LIST>) {
        if (/$module[a-z_]*.ko/) {
            print "is_module_in_rpm: $module $_\n";
            $ret = 0;
            last;
        }
    }
    close LIST;

    print "$module not in $package\n" if ($ret);

    return $ret;
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

            if ($package =~ /mvapich2_*/) {
                    mvapich2_config();
            }
        }

    for my $module ( @selected_modules_by_user ) {
        if ($module eq "ehca" and not -d "$kernel_sources/include/asm-ppc") {
            print RED "\nTo install ib_ehca module please ensure that $kernel_sources/include/ contains directory asm-ppc.", RESET;
            print RED "\nPlease install the kernel.src.rpm from redhat and copy the directory and the files into $kernel_sources/include/", RESET;
            print "\nThen rerun this Script\n";
            exit 1;
        }
        select_dependent_module($module);
    }

    if ($packages_info{'kernel-ib'}{'rpm_exist'}) {
        for my $module (@selected_kernel_modules) {
            if (module_in_rpm($module)) {
                $packages_info{'kernel-ib'}{'rpm_exist'} = 0;
                last;
            }
        }
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

sub check_open_iscsi
{
    my $oiscsi_name = $packages_info{'open-iscsi-generic'}{'name'};
    if (is_installed($oiscsi_name)) {
        my $vendor = `rpm --queryformat "[%{VENDOR}]" -q $oiscsi_name`;
        print "open-iscsi name $oiscsi_name vendor: $vendor\n" if ($verbose3);
        if ($vendor !~ m/Voltaire/) {
            if ($interactive) {
                print BLUE "In order to install iSER $oiscsi_name package should be upgraded.\n";
                print BLUE "Do you want to upgrade $oiscsi_name? [y/N]: ", RESET;
                my $ans = getch();
                if ( $ans eq 'Y' or $ans eq 'y' ) {
                    $upgrade_open_iscsi = 1;
                }
                else {
                    print RED "Please uninstall $oiscsi_name before installing $PACKAGE with iSER support.", RESET "\n";
                    exit 1;
                }
            }
            else {
                if (not $upgrade_open_iscsi) {
                    print RED "Please uninstall $oiscsi_name before installing $PACKAGE with iSER support.", RESET "\n";
                    print RED "  Or put \"upgrade_open_iscsi=yes\" in the $config:", RESET "\n";
                    exit 1;
                }
            }
        }
    }
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
        $kernel_configure_options .= " --kernel-version=$kernel";
        $kernel_configure_options .= " --kernel-sources=$kernel_sources";

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
        print RED "Failed to build $name RPM", RESET "\n";
        print RED "See $ofedlogs/$name.rpmbuild.log", RESET "\n";
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

# Build RPM from source RPM
sub build_rpm
{
    my $name = shift @_;
    my $cmd;
    my $res = 0;
    my $sig = 0;
    my $TMPRPMS;

    my $parent = $packages_info{$name}{'parent'};
    print "Build $name RPM\n" if ($verbose);

    if (not $packages_info{$name}{'rpm_exist'}) {
        $cmd = "rpmbuild --rebuild --define '_topdir $TOPDIR'";

        if ( $parent eq "mvapich") {
            my $compiler = (split('_', $name))[1];
            $cmd .= " --define '_name $name'";
            $cmd .= " --define 'compiler $compiler'";
            $cmd .= " --define 'openib_prefix $prefix'";
            $cmd .= " --define 'mpi_selector $prefix/bin/mpi-selector'";
            $cmd .= " --define '_prefix $prefix/mpi/$compiler/$parent-$main_packages{$parent}{'version'}'";
        }
        elsif ($parent eq "mvapich2") {
            my $compiler = (split('_', $name))[1];
            $cmd .= " --define '_name $name'";
            $cmd .= " --define 'impl $mvapich2_conf_impl'";

            if ($compiler eq "gcc") {
                if ($gcc{'gfortran'}) {
                    if ($arch eq "ppc64") {
                        $mvapich2_comp_env = 'CC="gcc -m64" CXX="g++ -m64" F77="gfortran -m64" F90="gfortran -m64"';
                    }
                    else {
                        $mvapich2_comp_env = "CC=gcc CXX=g++ F77=gfortran F90=gfortran";
                    }
                }
                if ($gcc{'g77'}) {
                    if ($arch eq "ppc64") {
                        $mvapich2_comp_env = 'CC="gcc -m64" CXX="g++ -m64" F77="g77 -m64" F90=/bin/false';
                    }
                    else {
                        $mvapich2_comp_env = "CC=gcc CXX=g++ F77=g77 F90=/bin/false";
                    }
                }
            }
            elsif ($compiler eq "pathscale") {
                $mvapich2_comp_env = "CC=pathcc CXX=pathCC F77=pathf90 F90=pathf90";
                # On i686 the PathScale compiler requires -g optimization
                # for MVAPICH2 in the shared library configuration.
                if ($arch eq "i686" and $mvapich2_conf_shared_libs) {
                    $mvapich2_comp_env .= " OPT_FLAG=-g";
                }
            }
            elsif ($compiler eq "pgi") {
                $mvapich2_comp_env = "CC=pgcc CXX=pgCC F77=pgf77 F90=pgf90";
            }
            elsif ($compiler eq "intel") {
                if ($mvapich2_conf_shared_libs) {
                    # The -i-dynamic flag is required for MVAPICH2 in the shared
                    # library configuration.
                    $mvapich2_comp_env = 'CC="icc -i-dynamic" CXX="icpc -i-dynamic" F77="ifort -i-dynamic" F90="ifort -i-dynamic"';
                }
                else {
                    $mvapich2_comp_env = "CC=icc CXX=icpc F77=ifort F90=ifort";
                }
            }

            if ($mvapich2_conf_impl eq "ofa") {
                print BLUE "Building the MVAPICH2 RPM in the OFA configuration. Please wait...", RESET "\n" if ($verbose);
                if ($mvapich2_conf_ckpt) {
                    $cmd .= " --define 'multithread 0'";
                    $cmd .= " --define 'rdma_cm 0'";
                    $cmd .= " --define 'blcr_home $mvapich2_conf_blcr_home'";
                }
                else {
                    $cmd .= " --define 'multithread $mvapich2_conf_multithread'";
                    $cmd .= " --define 'rdma_cm 1'";
                }
                $cmd .= " --define 'ckpt $mvapich2_conf_ckpt'";
            }
            elsif ($mvapich2_conf_impl eq "udapl") {
                print BLUE "Building the MVAPICH2 RPM in the uDAPL configuration. Please wait...", RESET "\n" if ($verbose);
                if (-d "$prefix/lib64") {
                    $mvapich2_dat_lib = "$prefix/lib64";
                }
                if (-d "$prefix/lib") {
                    $mvapich2_dat_lib = "$prefix/lib";
                }
                else {
                    print RED "Could not find a proper uDAPL lib directory.", RESET "\n";
                    exit 1;
                }
                if (-d "$prefix/include") {
                    $mvapich2_dat_include = "$prefix/include";
                }
                else {
                    print RED "Could not find a proper uDAPL include directory.", RESET "\n";
                    exit 1;
                }
                $cmd .= " --define 'multithread $mvapich2_conf_multithread'";
                $cmd .= " --define 'vcluster $mvapich2_conf_vcluster'";
                $cmd .= " --define 'io_bus $mvapich2_conf_io_bus'";
                $cmd .= " --define 'link_speed $mvapich2_conf_link_speed'";
                $cmd .= " --define 'dapl_provider $mvapich2_conf_dapl_provider'";
                $cmd .= " --define 'dat_lib $mvapich2_dat_lib'";
                $cmd .= " --define 'dat_include $mvapich2_dat_include'";
            }

            $cmd .= " --define 'open_ib_home $prefix'";
            $cmd .= " --define 'shared_libs $mvapich2_conf_shared_libs'";
            $cmd .= " --define 'romio $mvapich2_conf_romio'";
            $cmd .= " --define 'comp_env $mvapich2_comp_env'";
            $cmd .= " --define 'auto_req 0'";
            $cmd .= " --define 'mpi_selector $prefix/bin/mpi-selector'";
            $cmd .= " --define '_prefix $prefix/mpi/$compiler/$parent-$main_packages{$parent}{'version'}'";
            $cmd .= " --define 'ofa_build 0'";
        }
        elsif ($parent eq "openmpi") {
            my $compiler = (split('_', $name))[1];
            my $openmpi_comp_env;
            my $use_default_rpm_opt_flags = 1;
            my $openmpi_ldflags;
            my $openmpi_wrapper_cxx_flags;
            my $openmpi_lib;
            
            if ($compiler eq "gcc") {
                $openmpi_comp_env = "CC=gcc";
                if ($gcc{'g++'}) {
                    $openmpi_comp_env .= " CXX=g++";
                }
                else {
                    $openmpi_comp_env .= " --disable-mpi-cxx";
                }
                if ($gcc{'gfortran'}) {
                    $openmpi_comp_env .= " F77=gfortran FC=gfortran";
                }
                elsif ($gcc{'g77'}) {
                    $openmpi_comp_env .= " F77=g77 --disable-mpi-f90";
                }
                else {
                    $openmpi_comp_env .= " --disable-mpi-f77 --disable-mpi-f90";
                }
            }
            elsif ($compiler eq "pathscale") {
                $openmpi_comp_env = "CC=pathcc";
                if ($pathscale{'pathCC'}) {
                    $openmpi_comp_env .= " CXX=pathCC";
                }
                else {
                    $openmpi_comp_env .= " --disable-mpi-cxx";
                }
                if ($pathscale{'pathf90'}) {
                    $openmpi_comp_env .= " F77=pathf90 FC=pathf90";
                }
                else {
                    $openmpi_comp_env .= " --disable-mpi-f77 --disable-mpi-f90";
                }
                # On fedora6 and redhat5 the pathscale compiler fails with default $RPM_OPT_FLAGS
                if ($distro eq "fedora6" or $distro eq "redhat5") {
                    $use_default_rpm_opt_flags = 0;
                }
            }
            elsif ($compiler eq "pgi") {
                $openmpi_comp_env = "CC=pgcc";
                $use_default_rpm_opt_flags = 0;
                if ($pgi{'pgCC'}) {
                    $openmpi_comp_env .= " CXX=pgCC";
                    # See http://www.pgroup.com/userforum/viewtopic.php?p=2371
                    $openmpi_wrapper_cxx_flags .= " -fpic";
                }
                else {
                    $openmpi_comp_env .= " --disable-mpi-cxx";
                }
                if ($pgi{'pgf77'}) {
                    $openmpi_comp_env .= " F77=pgf77";
                }
                else {
                    $openmpi_comp_env .= " --disable-mpi-f77";
                }
                if ($pgi{'pgf90'}) {
                    # *Must* put in FCFLAGS=-O2 so that -g doesn't get
                    # snuck in there (pgi 6.2-5 has a problem with
                    # modules and -g).
                    $openmpi_comp_env .= " FC=pgf90 FCFLAGS=-O2";
                }
                else {
                    $openmpi_comp_env .= " --disable-mpi-f90";
                }
            }
            elsif ($compiler eq "intel") {
                $openmpi_comp_env = "CC=icc";
                if ($intel{'icpc'}) {
                    $openmpi_comp_env .= " CXX=icpc";
                }
                else {
                    $openmpi_comp_env .= " --disable-mpi-cxx";
                }
                if ($intel{'ifort'}) {
                    $openmpi_comp_env .= "  F77=ifort FC=ifort";
                }
                else {
                    $openmpi_comp_env .= " --disable-mpi-f77 --disable-mpi-f90";
                }
            }

            if ($arch eq "ppc64") {
                # In the ppc64 case, add -m64 to all the relevant
                # flags because it's not the default.  Also
                # unconditionally add $OMPI_RPATH because even if
                # it's blank, it's ok because there are other
                # options added into the ldflags so the overall
                # string won't be blank.
                $openmpi_comp_env .= ' CFLAGS="-m64 -O2" CXXFLAGS="-m64 -O2" FCFLAGS="-m64 -O2" FFLAGS="-m64 -O2"';
                $openmpi_comp_env .= ' --with-wrapper-ldflags="-g -O2 -m64 -L/usr/lib64" --with-wrapper-cflags=-m64';
                $openmpi_comp_env .= ' --with-wrapper-cxxflags=-m64 --with-wrapper-fflags=-m64 --with-wrapper-fcflags=-m64';
                $openmpi_wrapper_cxx_flags .= " -m64";
            }

            $openmpi_comp_env .= " --enable-mpirun-prefix-by-default";
            if ($openmpi_wrapper_cxx_flags) {
                $openmpi_comp_env .= " --with-wrapper-cxxflags=$openmpi_wrapper_cxx_flags";
            }

            $cmd .= " --define '_name $name'";
            $cmd .= " --define 'mpi_selector $prefix/bin/mpi-selector'";
            $cmd .= " --define 'ofed 0'";
            $cmd .= " --define '_prefix $prefix/mpi/$compiler/$parent-$main_packages{$parent}{'version'}'";
            $cmd .= " --define '_defaultdocdir $prefix/mpi/$compiler/$parent-$main_packages{$parent}{'version'}'";
            $cmd .= " --define '_mandir %{_prefix}/share/man'";
            $cmd .= " --define 'mflags -j 4'";
            $cmd .= " --define 'configure_options $openmpi_ldflags --with-openib=$prefix --with-openib-libdir=$prefix/$openmpi_lib $openmpi_comp_env'";
            $cmd .= " --define 'use_default_rpm_opt_flags $use_default_rpm_opt_flags'";
        }
        elsif ($parent eq "mpitests") {
            my $mpi = (split('_', $name))[1];
            my $compiler = (split('_', $name))[2];

            $cmd .= " --define '_name $name'";
            $cmd .= " --define 'root_path /'";
            $cmd .= " --define 'path_to_mpihome $prefix/mpi/$compiler/$mpi-$main_packages{$mpi}{'version'}'";
        }
        else {
            $cmd .= " --define '_prefix $prefix'";
        }

        if ($user_configure_options) {
            $cmd .= " --define 'configure_options $user_configure_options'";
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
        $cmd = "rpmbuild --rebuild --define '_topdir $TOPDIR'";
        $cmd .= " --define '_target_cpu $target_cpu32'";
        $cmd .= " --define '_target $target_cpu32-linux'";
        $cmd .= " --define '_prefix $prefix'";
        $cmd .= " --define '_lib lib'";
        $cmd .= " --define '__arch_install_post %{nil}'";
        $cmd .= " --define 'optflags -O2 -g -m32'";
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
        print RED "$package does not exist", RESET "\n";
        exit 1;
    }

    $cmd = "rpm -iv";
    if ($distro eq "SuSE") {
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
        print RED "$package does not exist", RESET "\n";
        exit 1;
    }
    $cmd = "rpm -iv";
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
        $package = "$RPMS/$name-$version-$release.$target_cpu32.rpm";
        if (not -f $package) {
            print RED "$package does not exist", RESET "\n";
            # exit 1;
        }
        $cmd = "rpm -iv";
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
    system("yes | ofed_uninstall.sh > $ofedlogs/ofed_uninstall.log 2>&1");
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
            open (LOG, "+>$ofedlogs/ofed_uninstall.log");
            print LOG "Running $cmd\n";
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
}

sub install
{
    # Build and install selected RPMs
    for my $package ( @selected_packages) {
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
            else {
                if ($package eq "open-iscsi-generic") {
                    my $real_name = $packages_info{$package}{'name'};
                    if (not $packages_info{$real_name}{'rpm_exist'}) {
                        build_rpm($real_name);
                    }
                    if (not $packages_info{$real_name}{'rpm_exist'}) {
                        print RED "$real_name was not created", RESET "\n";
                        exit 1;
                    }
                    print "Install $real_name RPM:\n" if ($verbose);
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
                print RED "$package was not created", RESET "\n";
                exit 1;
            }
            print "Install $package RPM:\n" if ($verbose);
            install_kernel_rpm($package);
        }
    }
}

### MAIN AREA ###
sub main
{
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
    
    my $num_selected = 0;

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
            set_existing_rpms();
            set_availability();
            $num_selected = select_packages();
            resolve_dependencies();
            print_selected();
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
        set_existing_rpms();
        set_availability();
        $num_selected = select_packages();
        resolve_dependencies();
        print_selected();
    }
    
    if (not $num_selected) {
        print RED "$num_selected packages selected. Exiting...", RESET "\n";
        exit 1;
    }
    print BLUE "Detected Linux Distribution: $distro", RESET "\n" if ($verbose);
    
    # Uninstall the previous installations
    uninstall();
    install();
    print GREEN "\nInstallation finished successfully...", RESET;
    if ($interactive) {
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
