
eval '(exit $?0)' && eval 'exec perl -w -S $0 ${1+"$@"}'
    & eval 'exec perl -w -S $0 $argv:q'
    if 0;

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

my @basic_kernel_packages = ("ib_verbs", "ib_mthca", "mlx4", "ib_ipoib");
my @kernel_packages = (@basic_kernel_packages, "ib_sdp", "ib_srp");

my @all_packages = ("libibverbs", "libibverbs-devel", "libibverbs-devel-static", "libibverbs-utils", "libibverbs-debuginfo");

my %packages_info = (
		'libibverbs' => 
			{ name => "libibverbs", parent => "libibverbs",
			selected => 0, installed => 0, rpm_exist => 0,
			available => 1, dist_req_build => [],
			dist_req_inst => [], ofa_req_build => [], ofa_req_inst => [], },
		'libibverbs-devel' => 
			{ name => "libibverbs", parent => "libibverbs",
			selected => 0, installed => 0, rpm_exist => 0,
			available => 1, dist_req_build => [],
			dist_req_inst => [], ofa_req_build => [],
			ofa_req_inst => ["libibverbs"], },
		'libibverbs-devel-static' => 
			{ name => "libibverbs", parent => "libibverbs",
			selected => 0, installed => 0, rpm_exist => 0,
			available => 1, dist_req_build => [],
			dist_req_inst => [], ofa_req_build => [],
			ofa_req_inst => ["libibverbs"], },
		'libibverbs-utils' => 
			{ name => "libibverbs", parent => "libibverbs",
			selected => 0, installed => 0, rpm_exist => 0,
			available => 1, dist_req_build => [],
			dist_req_inst => [], ofa_req_build => [],
			ofa_req_inst => ["libibverbs"], },
		'libibverbs-debuginfo' => 
			{ name => "libibverbs", parent => "libibverbs",
			selected => 0, installed => 0, rpm_exist => 0,
			available => 1, dist_req_build => [],
			dist_req_inst => [], ofa_req_build => [],
			ofa_req_inst => ["libibverbs"], },
		);

my $build32 = 0;

my $PACKAGE 	= 'OFED';

my $WDIR  	= dirname($0);
chdir $WDIR;
my $CWD 	= $ENV{PWD};
my $TMPDIR 	= '/tmp';
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
my $RPMS  = $CWD . '/' . 'RPMS' . '/' . $dist_rpm;
my $TOPDIR = "/var/tmp/" . $PACKAGE . "_topdir";

# system ("mkdir -p $TOPDIR/{BUILD,RPMS,SOURCES,SPECS,SRPMS}")
# rmtree ("$TOPDIR");
mkpath([$TOPDIR . '/BUILD' ,$TOPDIR . '/RPMS',$TOPDIR . '/SOURCES',$TOPDIR . '/SPECS',$TOPDIR . '/SRPMS']);

my $build_arch	= `rpm --eval '%{_target_cpu}'`;
my $mandir  	= `rpm --eval '%{_mandir}'`;
my $sysconfdir	= `rpm --eval '%{_sysconfdir}'`;

my %MPI_SUPPORTED_COMPILERS = (gcc => 0, pgi => 0, intel => 0, pathscale => 0);

# for  my $key ( keys %MPI_SUPPORTED_COMPILERS ) {
# 	print $key . ' = ' . $MPI_SUPPORTED_COMPILERS{$key} . "\n";
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

sub get_info
{
    return `rpm --queryformat "[%{NAME}] [%{VERSION}] [%{RELEASE}] [%{DESCRIPTION}]" -qp @_`;
}

sub set_cfg
{
    my $srpm_full_path = shift @_;

    my $info = get_info($srpm_full_path);
    my $name = (split(/ /,$info,4))[0];
    print "set_cfg: main_packages $name $info\n" if ( $verbose2 );

    ( $main_packages{$name}{'name'},
    $main_packages{$name}{'version'},
    $main_packages{$name}{'release'},
    $main_packages{$name}{'description'} ) = split(/ /,$info,4);
    $main_packages{$name}{'srpmpath'} 	= $srpm_full_path;

}

# Add subpackage $2 to package $1
sub add_subpackage
{
	my $name = shift @_;
	my $sub  = shift @_;

	push @{ $main_packages{$name}{'subpackage'} }, $sub;

}

# TBD Set packages availability depending OS/Kernel/arch
sub set_availability
{
}

# Select package for installation
sub select_package
{
	if ($interactive) {
		open(CONFIG, "+>$config") || die "Can't open $config: $!";;
		flock CONFIG, $LOCK_EXCLUSIVE;
		for my $package ( @all_packages ) {
			next if (not $packages_info{$package}{'available'});
			print "Install $package? [y/N]:";
			my $ans = getch();
			if ( $ans eq 'Y' or $ans eq 'y' ) {
				$packages_info{$package}{'selected'} = 1;
				print CONFIG "$package=y\n";
			}
			else {
				$packages_info{$package}{'selected'} = 0;
				print CONFIG "$package=n\n";
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

			if ( $selected eq 'y' ) {
				$packages_info{$package}{'selected'} = 1;
				print "Selected $package\n" if ($verbose);
			}
		}
	}
	flock CONFIG, $UNLOCK;
	close(CONFIG);

}

sub resolve_dependencies
{

	for my $package ( @all_packages ) {
		if ($packages_info{$package}{'selected'}) {
			# Get the list of dependencies
			my @arr = @{ $packages_info{$package}{'ofa_req_inst'} };
			for my $i ( 0 .. $#arr ) {
				print "$package requires $arr[$i]\n"
			}
		}
	}
}

# Build RPM from source RPM
sub build_rpm
{
	my $name = shift @_;
	my $cmd;

	if ($build32) {
		$cmd .= " linux32";
	}
	$cmd .= " rpmbuild --rebuild --define '_topdir $TOPDIR'";
	$cmd .= " $main_packages{$name}{'srpmpath'}";
	
	print "$cmd\n";
#	system("$cmd");
	my $TMPRPMS = "$TOPDIR/RPMS/$build_arch";
	chomp $TMPRPMS;

##	opendir(DIR, $TMPRPMS) || die "can't opendir $TMPRPMS: $!";
##	my @rpms = readdir(DIR);
	for my $myrpm ( <$TMPRPMS/*.rpm> ) {
		print "$myrpm\n";
	}
##	closedir(DIR);
##	print "@rpms\n";
}

sub print_package_info
{
    print "\n\nDate:" . localtime(time) . "\n";
    for my $key ( keys %main_packages ) {
        print "$key:\n";
        print "======================================\n";
	my %pack = %{$main_packages{$key}};
        for my $subkey ( keys %pack ) {
		if ( $subkey eq "subpackage" ) {
			print "$subkey: ";
			for my $i ( 0 .. $#{ $pack{$subkey} } ) {
				print $pack{$subkey}[$i] . ' ';
			}
			print "\n";
		}
		else {
            		print $subkey . ' = ' . $pack{$subkey} . "\n";
		}
        }
        print "\n";
    }
}

# Set RPMs info for available source RPMs
for my $srcrpm ( <$SRPMS*> ) {
	set_cfg ($srcrpm);
}

# add_subpackage('libibverbs', 'devel');
# add_subpackage('libibverbs', 'utils');
# print_package_info;

select_package();
build_rpm("libibverbs");

print "libibverbs-devel $packages_info{'libibverbs-devel'}->{'selected'}\n";
resolve_dependencies();
