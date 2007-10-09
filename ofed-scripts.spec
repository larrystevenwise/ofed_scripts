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
#  $Id: ofed-scripts.spec 8402 2006-07-06 06:35:57Z vlad $
#

Summary: OFED scripts
Name: ofed-scripts
Version: 1.3
Release: 0
License: GPL/BSD
Url: http://www.openfabrics.org
Group: System Environment/Base
Source: %{name}-%{version}.tar.gz
BuildRoot: %{?build_root:%{build_root}}%{!?build_root:/var/tmp/%{name}-%{version}-root}
Vendor: OpenFabrics
%description
OpenFabrics scripts

%prep
[ "${RPM_BUILD_ROOT}" != "/" -a -d ${RPM_BUILD_ROOT} ] && rm -rf $RPM_BUILD_ROOT
%setup -q -n %{name}-%{version}

%install
install -d $RPM_BUILD_ROOT%{_prefix}/bin
install -d $RPM_BUILD_ROOT%{_prefix}/sbin
install -m 0755 uninstall.sh $RPM_BUILD_ROOT%{_prefix}/sbin/ofed_uninstall.sh
install -m 0755 ofed_info $RPM_BUILD_ROOT%{_prefix}/bin

perl -ni -e "s@(STACK_PREFIX=).*@\$1%{_prefix}@; print" $RPM_BUILD_ROOT%{_prefix}/sbin/ofed_uninstall.sh

touch ofed-files

case %{_prefix} in
	/usr | /usr/)
	;;
	*)
install -d $RPM_BUILD_ROOT/etc/profile.d
cat > $RPM_BUILD_ROOT/etc/profile.d/ofed.sh << EOF
if ! echo \${PATH} | grep -q %{_prefix}/bin ; then
        PATH=\${PATH}:%{_prefix}/bin
fi
if ! echo \${PATH} | grep -q %{_prefix}/sbin ; then
        PATH=\${PATH}:%{_prefix}/sbin
fi
if ! echo \${MANPATH} | grep -q %{_mandir} ; then
        MANPATH=\${MANPATH}:%{_mandir}
fi
EOF
cat > $RPM_BUILD_ROOT/etc/profile.d/ofed.csh << EOF
if (\$?path) then
if ( "\${path}" !~ *%{_prefix}/bin* ) then
        set path = ( \$path %{_prefix}/bin )
endif
if ( "\${path}" !~ *%{_prefix}/sbin* ) then
        set path = ( \$path %{_prefix}/sbin )
endif
else
        set path = ( %{_prefix}/bin %{_prefix}/sbin )
endif
if (\$?MANPATH) then
if ( "\${MANPATH}" !~ *%{_mandir}* ) then
        setenv MANPATH \${MANPATH}:%{_mandir}
endif
else
        setenv MANPATH %{_mandir}:
endif
EOF

install -d $RPM_BUILD_ROOT/etc/ld.so.conf.d
echo %{_libdir} > $RPM_BUILD_ROOT/etc/ld.so.conf.d/ofed.conf
    %ifarch x86_64 ppc64
    echo "%{_prefix}/lib" >> $RPM_BUILD_ROOT/etc/ld.so.conf.d/ofed.conf
    %endif
	echo "/etc/profile.d/ofed.sh" >> ofed-files
	echo "/etc/profile.d/ofed.csh" >> ofed-files
	echo "/etc/ld.so.conf.d/ofed.conf" >> ofed-files
	;;
esac

%post
/sbin/ldconfig

%postun
/sbin/ldconfig

%clean
[ "${RPM_BUILD_ROOT}" != "/" -a -d ${RPM_BUILD_ROOT} ] && rm -rf $RPM_BUILD_ROOT

%files -f ofed-files
%defattr(-,root,root)
%{_prefix}/bin/ofed_info
%{_prefix}/sbin/ofed_uninstall.sh

%changelog
* Tue Oct  9 2007 Vladimir Sokolovsky <vlad@mellanox.co.il>
- Added ofed.[c]sh and ofed.conf if prefix is not /usr
* Tue Aug 21 2007 Vladimir Sokolovsky <vlad@mellanox.co.il>
- Changed version to 1.3
* Mon Apr  2  2007 Vladimir Sokolovsky <vlad@mellanox.co.il>
- uninstall.sh renamed to ofed_uninstall.sh and placed under %{_prefix}/sbin
* Tue Jun  13 2006 Vladimir Sokolovsky <vlad@mellanox.co.il>
- Initial packaging
