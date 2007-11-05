#!/bin/bash
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
#
#
#  $Id: uninstall.sh 9432 2006-09-12 09:06:46Z vlad $
#
# Description: OFED package uninstall script

RPM=/bin/rpm
RM=/bin/rm
NULL=/dev/null

PACKAGE="OFED"
# Default ${PACKAGE} stack prefix

STACK_PREFIX=/usr

ARCH=$(uname -m)

IB_ALL_PACKAGES="$IB_ALL_PACKAGES kernel-ib kernel-ib-devel ipoibtools "
IB_ALL_PACKAGES="$IB_ALL_PACKAGES libopensm libopensm-devel libosmcomp libosmcomp-devel libosmvendor libosmvendor-devel"
IB_ALL_PACKAGES="$IB_ALL_PACKAGES openib-diags ib-bonding ib-bonding-debuginfo"
IB_ALL_PACKAGES="$IB_ALL_PACKAGES libibverbs libibverbs-devel libibverbs-devel-static"
IB_ALL_PACKAGES="$IB_ALL_PACKAGES libibverbs-utils libibverbs-debuginfo"
IB_ALL_PACKAGES="$IB_ALL_PACKAGES libmthca libmthca-devel-static libmthca-debuginfo"
IB_ALL_PACKAGES="$IB_ALL_PACKAGES libmlx4 libmlx4-devel-static libmlx4-debuginfo"
IB_ALL_PACKAGES="$IB_ALL_PACKAGES libehca libehca-devel-static libehca-debuginfo"
IB_ALL_PACKAGES="$IB_ALL_PACKAGES libcxgb3 libcxgb3-devel libcxgb3-debuginfo"
IB_ALL_PACKAGES="$IB_ALL_PACKAGES libnes libnes-devel-static libnes-debuginfo"
IB_ALL_PACKAGES="$IB_ALL_PACKAGES libipathverbs libipathverbs-devel libipathverbs-debuginfo"
IB_ALL_PACKAGES="$IB_ALL_PACKAGES libibcm libibcm-devel libibcm-debuginfo"
IB_ALL_PACKAGES="$IB_ALL_PACKAGES libibcommon libibcommon-devel libibcommon-static libibcommon-debuginfo"
IB_ALL_PACKAGES="$IB_ALL_PACKAGES libibumad libibumad-devel libibumad-static libibumad-debuginfo"
IB_ALL_PACKAGES="$IB_ALL_PACKAGES libibmad libibmad-devel libibmad-static libibmad-debuginfo"
IB_ALL_PACKAGES="$IB_ALL_PACKAGES librdmacm librdmacm-utils librdmacm-devel librdmacm-debuginfo"
IB_ALL_PACKAGES="$IB_ALL_PACKAGES libsdp libsdp-devel libsdp-debuginfo"
IB_ALL_PACKAGES="$IB_ALL_PACKAGES opensm opensm-libs opensm-devel opensm-debuginfo opensm-static"
IB_ALL_PACKAGES="$IB_ALL_PACKAGES perftest mstflint tvflash"
IB_ALL_PACKAGES="$IB_ALL_PACKAGES dapl dapl-devel dapl-devel-static dapl-utils dapl-debuginfo"
IB_ALL_PACKAGES="$IB_ALL_PACKAGES qlvnictools ibvexdmtools sdpnetstat srptools rds-tools"
IB_ALL_PACKAGES="$IB_ALL_PACKAGES ibutils infiniband-diags qperf qperf-debuginfo"
IB_ALL_PACKAGES="$IB_ALL_PACKAGES ofed-docs ofed-scripts"

ALL_PACKAGES="${IB_ALL_PACKAGES} mpi-selector mvapich mvapich2 openmpi mpitests ibutils"

PREV_RELEASE_PACKAGES="mpich_mlx ibtsal openib opensm opensm-devel mpi_ncsa thca ib-osm osm diags ibadm ib-diags ibgdiag ibdiag ib-management"
PREV_RELEASE_PACKAGES="$PREV_RELEASE_PACKAGES ib-verbs ib-ipoib ib-cm ib-sdp ib-dapl udapl udapl-devel libdat libibat ib-kdapl ib-srp ib-srp_target oiscsi-iser-support"

MPI_SELECTOR_NAME="mpi-selector"
OPENMPI_NAME="openmpi"
MVAPICH2_NAME="mvapich2"
MVAPICH_NAME="mvapich"

if [ -f /etc/SuSE-release ]; then
    DISTRIBUTION="SuSE"
elif [ -f /etc/fedora-release ]; then
    DISTRIBUTION="fedora"
elif [ -f /etc/rocks-release ]; then
    DISTRIBUTION="Rocks"
elif [ -f /etc/redhat-release ]; then
    DISTRIBUTION="redhat"
elif [ -f /etc/debian_version ]; then
    DISTRIBUTION="debian"
else
    DISTRIBUTION=$(ls /etc/*-release | head -n 1 | xargs -iXXX basename XXX -release 2> $NULL)
    [ -z "${DISTRIBUTION}" ] && DISTRIBUTION="unsupported"
fi

OPEN_ISCSI_SUSE_NAME="open-iscsi"
OPEN_ISCSI_REDHAT_NAME="iscsi-initiator-utils"

# Execute the command $@ and check exit status
ex()
{
echo Running $@
eval "$@"
if [ $? -ne 0 ]; then
     echo
     echo Failed in execution \"$@\"
     echo
     exit 5
fi
}


# Uninstall Software
uninstall()
{
    local RC=0
    echo
    echo "Removing ${PACKAGE} Software installations"
    echo

    case ${DISTRIBUTION} in
        SuSE)
        if ( $RPM -q ${OPEN_ISCSI_SUSE_NAME} > $NULL 2>&1 ) && ( $RPM --queryformat "[%{VENDOR}]" -q ${OPEN_ISCSI_SUSE_NAME} | grep -i Voltaire > $NULL 2>&1 ); then
            ex "$RPM -e ${OPEN_ISCSI_SUSE_NAME}"
        fi
        ;;
        redhat)
        if ( $RPM -q ${OPEN_ISCSI_REDHAT_NAME} > $NULL 2>&1 ) && ( $RPM --queryformat "[%{VENDOR}]" -q ${OPEN_ISCSI_REDHAT_NAME} | grep -i Voltaire > $NULL 2>&1 ); then
            ex "$RPM -e ${OPEN_ISCSI_REDHAT_NAME}"
        fi
        ;;
        *)
        echo "Error: Distribution ${DISTRIBUTION} is not supported by open-iscsi over iSER. Cannot uninstall open-iscsi"
        ;;
    esac

    MPITESTS_LIST=$(rpm -qa | grep mpitests)

    if [ -n "$MPITESTS_LIST" ]; then
        for mpitest_name in $MPITESTS_LIST
        do 
            if ( $RPM -q ${mpitest_name} > $NULL 2>&1 ); then
                ex "$RPM -e ${mpitest_name}"
            fi
        done    
    fi

   MVAPICH_LIST=$(rpm -qa | grep ${MVAPICH_NAME})

    if [ -n "$MVAPICH_LIST" ]; then
        for mpi_name in $MVAPICH_LIST
        do 
            if ( $RPM -q ${mpi_name} > $NULL 2>&1 ); then
                ex "$RPM -e ${mpi_name}"
            fi
        done    
    fi

    MVAPICH2_LIST=$(rpm -qa |grep ${MVAPICH2_NAME})

    if [ -n "$MVAPICH2_LIST" ]; then
        for mpi_name in $MVAPICH2_LIST
        do
            if ( $RPM -q ${mpi_name} > $NULL 2>&1 ); then
                ex "$RPM -e ${mpi_name}"
            fi
        done
    fi

    OPENMPI_LIST=$(rpm -qa | grep ${OPENMPI_NAME})

    if [ -n "$OPENMPI_LIST" ]; then
        for mpi_name in $OPENMPI_LIST
        do 
            if ( $RPM -q ${mpi_name} > $NULL 2>&1 ); then
                ex "$RPM -e ${mpi_name}"
            fi
        done    
    fi

    MPI_SELECTOR_LIST=$(rpm -qa | grep ${MPI_SELECTOR_NAME})

    if [ -n "$MPI_SELECTOR_LIST" ]; then
        for mpitest_name in $MPI_SELECTOR_LIST
        do 
            if ( $RPM -q ${mpitest_name} > $NULL 2>&1 ); then
                ex "$RPM -e ${mpitest_name}"
            fi
        done    
    fi

    if [[ ! -z $MTHOME && -d $MTHOME ]]; then
        if [ -e $MTHOME/uninstall.sh ]; then
            echo
            echo "  An old version of the OPENIB driver was detected and will be removed now"
            ex "yes | env MTHOME=$MTHOME $MTHOME/uninstall.sh"
        else
            echo
            echo "Found an MTHOME variable pointing to $MTHOME. Probably some old InfiniBand Software ..."
            echo
        fi    
        let RC++
    elif [ -d /usr/mellanox ]; then
        if [ -e /usr/mellanox/uninstall.sh ]; then
            echo
            echo "  Removing MVAPI..."
            ex "yes | /usr/mellanox/uninstall.sh"
        else
            echo
            echo "Found a /usr/mellanox directory. Probably some old InfiniBand Software ..."
            echo
        fi  
    fi
    
    packs_to_remove=""
    for package in $ALL_PACKAGES $PREV_RELEASE_PACKAGES
    do
        if ( $RPM -q ${package} > $NULL 2>&1 ); then
            packs_to_remove="$packs_to_remove ${package}"
            let RC++
        fi
    done    

    if ( $RPM -q ib-verbs > $NULL 2>&1 ); then
        STACK_PREFIX=`$RPM -ql ib-verbs | grep "bin/ibv_devinfo" | sed -e 's/\/bin\/ibv_devinfo//'`
        let RC++
    fi    

    if ( $RPM -q libibverbs > $NULL 2>&1 ); then
        STACK_PREFIX=$($RPM -ql libibverbs | grep "libibverbs.so" | head -1 | sed -e 's@/lib.*/libibverbs.so.*@@')            
    fi

    if [ -n "${packs_to_remove}" ]; then
        ex "$RPM -e --allmatches $packs_to_remove"
    fi

    # Remove /usr/local/ofed* if exist
    # BUG: https://bugs.openfabrics.org/show_bug.cgi?id=563
    if [ -d ${STACK_PREFIX} ]; then
        case ${STACK_PREFIX} in
                    /usr/local/ofed* )
                    rm -rf ${STACK_PREFIX}
                    ;;
        esac
    fi

#    # Uninstall SilverStorm package
#    if [ -e /sbin/iba_config ]; then
#        ex /sbin/iba_config -u
#    fi

    # Uninstall Topspin package
    topspin_rpms=$($RPM -qa | grep "topspin-ib")
    if [ -n "${topspin_rpms}" ]; then
        ex $RPM -e ${topspin_rpms}
    fi

    # Uninstall Voltaire package
    voltaire_rpms=$($RPM -qa | grep -i "Voltaire" | grep "4.0.0_5")
    if [ -n "${voltaire_rpms}" ]; then
        ex $RPM -e ${voltaire_rpms}
    fi
}

echo
echo "This program will uninstall all ${PACKAGE} packages on your machine."
echo

read -p "Do you want to continue?[y/N]:" ans_r
if [[ "$ans_r" == "y" || "$ans_r" == "Y" || "$ans_r" == "yes" ]]; then
    uninstall
else    
    exit 1
fi
