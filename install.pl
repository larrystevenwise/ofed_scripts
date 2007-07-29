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

# use Cwd;


sub usage
{
   print "\n Usage: $0 [-c <packages config_file>] [-net <network config_file>]\n";
   print "\n";
}

$| = 1;
my $LOCK_EXCLUSIVE = 2;
my $UNLOCK         = 8;

my $interactive = 1;
my $verbose = 0;
my $verbose2 = 0;

my %main_packages = ();
my @selected_packages = ();
my @selected_by_user = ();

# List of all available packages sorted following dependencies
my @basic_kernel_packages = ("ib_verbs", "ib_mthca", "mlx4", "ib_ipoib");
my @kernel_packages = (@basic_kernel_packages, "ib_sdp", "ib_srp");

my @user_packages = ("libibverbs", "libibverbs-devel", "libibverbs-devel-static", "libibverbs-utils", "libibverbs-debuginfo",
            "libmthca", "libmthca-devel-static", "libmthca-debuginfo");
# all_packages is required to save ordered (following dependencies) list of
# packages. Hash does not saves the order
my @all_packages = (@kernel_packages, @user_packages);

my %packages_info = (
        'libibverbs' =>
            { name => "libibverbs", parent => "libibverbs",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [], ofa_req_inst => [], },
        'libibverbs-devel' =>
            { name => "libibverbs", parent => "libibverbs",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => ["libibverbs"], },
        'libibverbs-devel-static' =>
            { name => "libibverbs", parent => "libibverbs",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => ["libibverbs"], },
        'libibverbs-utils' =>
            { name => "libibverbs", parent => "libibverbs",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => ["libibverbs"], },
        'libibverbs-debuginfo' =>
            { name => "libibverbs", parent => "libibverbs",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, dist_req_build => [],
            dist_req_inst => [], ofa_req_build => [],
            ofa_req_inst => ["libibverbs"], },
        'libmthca' =>
            { name => "libmthca", parent => "libmthca",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs"],
            ofa_req_inst => ["libibverbs"], },
        'libmthca-devel-static' =>
            { name => "libmthca-devel-static", parent => "libmthca",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs","libibverbs-devel"],
            ofa_req_inst => ["libibverbs", "libmthca"], },
        'libmthca-debuginfo' =>
            { name => "libmthca-debuginfo", parent => "libmthca",
            selected => 0, installed => 0, rpm_exist => 0, rpm_exist32 => 0,
            available => 1, dist_req_build => [],
            dist_req_inst => [], ofa_req_build => ["libibverbs","libibverbs-devel"],
            ofa_req_inst => ["libibverbs", "libmthca"], },
        );

my @hidden_packages = ("open-iscsi");
my $build32 = 0;
my $arch = `uname -m`;
chomp $arch;
my $kernel = `uname -r`;
chomp $kernel;

my $PACKAGE     = 'OFED';

my $WDIR    = dirname($0);
chdir $WDIR;
my $CWD     = $ENV{PWD};
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

my $TOPDIR = "/var/tmp/" . $PACKAGE . "_topdir";
chomp $TOPDIR;

rmtree ("$TOPDIR");
mkpath([$TOPDIR . '/BUILD' ,$TOPDIR . '/RPMS',$TOPDIR . '/SOURCES',$TOPDIR . '/SPECS',$TOPDIR . '/SRPMS']);
my $ofedlogs = "/tmp/$PACKAGE.$$.logs";
mkpath([$ofedlogs]);

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

my %MPI_SUPPORTED_COMPILERS = (gcc => 0, pgi => 0, intel => 0, pathscale => 0);

# for  my $key ( keys %MPI_SUPPORTED_COMPILERS ) {
#   print $key . ' = ' . $MPI_SUPPORTED_COMPILERS{$key} . "\n";
# }


my $config = $CWD . '/ofed.conf';
chomp $config;
my $config_net;

while ( $#ARGV >= 0 ) {

   my $cmd_flag = shift(@ARGV);

    if ( $cmd_flag eq "-c" ) {
        $config = shift(@ARGV);
        $interactive = 0;
    } elsif ( $cmd_flag eq "-net" ) {
        $config_net = shift(@ARGV);
    } elsif ( $cmd_flag eq "-v" ) {
        $verbose = 1;
    } elsif ( $cmd_flag eq "-vv" ) {
        $verbose = 1;
        $verbose2 = 1;
    } else {
        &usage();
        exit 1;
    }
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

}

# TBD Set packages availability depending OS/Kernel/arch
sub set_availability
{
}

# Set rpm_exist parameter for existing RPMs
sub set_existing_rpms
{
    for my $binrpm ( <$RPMS/*.rpm> ) {
        my ($rpm_name, $rpm_arch) = (split ' ', get_rpm_name_arch($binrpm));
        if ($rpm_arch eq $target_cpu) {
            $packages_info{$rpm_name}{'rpm_exist'} = 1;
        }
        else {
            $packages_info{$rpm_name}{'rpm_exist32'} = 1;
        }
        print "$rpm_name RPM exist\n" if ($verbose2);
    }
}

# Select package for installation
sub select_packages
{
    if ($interactive) {
        my $ans;
        open(CONFIG, "+>$config") || die "Can't open $config: $!";;
        flock CONFIG, $LOCK_EXCLUSIVE;
        for my $package ( @all_packages ) {
            next if (not $packages_info{$package}{'available'});
            print "Install $package? [y/N]:";
            $ans = getch();
            if ( $ans eq 'Y' or $ans eq 'y' ) {
                $packages_info{$package}{'selected'} = 1;
                print CONFIG "$package=y\n";
                push (@selected_by_user, $package);
            }
            else {
                $packages_info{$package}{'selected'} = 0;
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
    }
    else {
        open(CONFIG, "$config") || die "Can't open $config: $!";;
        flock CONFIG, $LOCK_EXCLUSIVE;
        while(<CONFIG>) {
            next if (m@^\s*#.*@);
            my ($package,$selected) = (split '=', $_);
            chomp $package;
            chomp $selected;
            if ($package eq "build32") {
                $build32 = 1 if ($selected);
                next;
            }

            if ( $selected eq 'y' ) {
                $packages_info{$package}{'selected'} = 1;
                push (@selected_by_user, $package);
                print "select_package: selected $package\n" if ($verbose);
            }
        }
    }
    flock CONFIG, $UNLOCK;
    close(CONFIG);

}

sub resolve_dependencies
{
    for my $package ( @selected_by_user ) {
            # Get the list of dependencies
            if (not $packages_info{$package}{'rpm_exist'}) {
                for my $req ( @{ $packages_info{$package}{'ofa_req_build'} } ) {
                    print "resolve_dependencies: $package requires $req for rpmbuild\n" if ($verbose);
                    if (not $packages_info{$req}{'selected'}) {
                        $packages_info{$req}{'selected'} = 1;
                        push (@selected_packages, $req);
                    }
                }
            }
            for my $req ( @{ $packages_info{$package}{'ofa_req_inst'} } ) {
                print "resolve_dependencies: $package requires $req for rpm install\n" if ($verbose);
                if (not $packages_info{$req}{'selected'}) {
                    $packages_info{$req}{'selected'} = 1;
                    push (@selected_packages, $req);
                }
            }
            push (@selected_packages, $package);
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

# Build RPM from source RPM
sub build_rpm
{
    my $name = shift @_;
    my $cmd;
    my $res = 0;
    my $sig = 0;
    my $TMPRPMS;


    $cmd .= " rpmbuild --rebuild --define '_topdir $TOPDIR'";
    if ($build32) {
        # $cmd .= " linux32";
        $cmd .= " --define '_target_cpu $target_cpu32'";
        $cmd .= " --define '_target $target_cpu32-linux'";
        $cmd .= " --define '_lib lib'";
        $cmd .= " --define '__arch_install_post %{nil}'";
        $cmd .= " --define 'optflags -O2 -g -m32'";
    }
    $cmd .= " $main_packages{$name}{'srpmpath'}";

    print "Running $cmd\n" if ($verbose);
    system("$cmd > $ofedlogs/$name.rpmbuild.log 2>&1");
    $res = $? >> 8;
    $sig = $? & 127;
    if ($sig or $res) {
        print "Failed to build $name RPM\n";
        print "See $ofedlogs/$name.rpmbuild.log\n";
        exit 1;
    }

    if ($build32) {
        $TMPRPMS = "$TOPDIR/RPMS/$target_cpu32";
    }
    else {
        $TMPRPMS = "$TOPDIR/RPMS/$target_cpu";
    }
    chomp $TMPRPMS;

    print "TMPRPMS $TMPRPMS\n";

    for my $myrpm ( <$TMPRPMS/*.rpm> ) {
        print "Created $myrpm\n" if ($verbose2);
        my ($myrpm_name, $myrpm_arch) = (split ' ', get_rpm_name_arch($myrpm));
        move($myrpm, $RPMS);
        if ($myrpm_arch eq $target_cpu) {
            $packages_info{$myrpm_name}{'rpm_exist'} = 1;
        }
        else {
            $packages_info{$myrpm_name}{'rpm_exist32'} = 1;
        }
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
    if ($build32) {
        $package = "$RPMS/$name-$version-$release.$target_cpu32.rpm";
    }
    else {
        $package = "$RPMS/$name-$version-$release.$target_cpu.rpm";
    }

    if (not -f $package) {
        print "$package does not exist\n";
        exit 1;
    }
    $cmd .= " rpm -i";
    $cmd .= " $package";

    print "Running $cmd\n" if ($verbose);
    system("$cmd > $ofedlogs/$name.rpminstall.log 2>&1");
    $res = $? >> 8;
    $sig = $? & 127;
    if ($sig or $res) {
        print "Failed to install $name RPM\n";
        print "See $ofedlogs/$name.rpminstall.log\n";
        exit 1;
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
        for my $package (@all_packages) {
            if (is_installed($package)) {
                $cmd .= " $package";
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
                print "Failed to uninstall the previous installation\n";
                print "See $ofedlogs/ofed_uninstall.log\n";
                exit 1;
            }
        }
    }
}

### MAIN AREA ###

# Set RPMs info for available source RPMs
for my $srcrpm ( <$SRPMS*> ) {
    set_cfg ($srcrpm);
}

set_existing_rpms();
select_packages();
resolve_dependencies();
print_selected();

# Uninstall the previous installations
uninstall();

# Build and install selected RPMs
for my $package ( @selected_packages) {
    if ( (not $build32 and not $packages_info{$package}{'rpm_exist'}) or 
         ($build32 and not $packages_info{$package}{'rpm_exist32'}) ) {
        my $parent = $packages_info{$package}{'parent'};
        build_rpm($parent);
    }

    if ( (not $build32 and not $packages_info{$package}{'rpm_exist'}) or 
         ($build32 and not $packages_info{$package}{'rpm_exist32'}) ) {
        print "$package was not created\n";
        exit 1;
    }
    install_rpm($package); 
}
