Name:           openssl35
Version:        3.5.9
Release:        1%{?dist}
Summary:        OpenSSL 3.5 toolkit (side-install, coexists with system openssl 1.0.2)

# OpenSSL 3.x is Apache-2.0 (with the old OpenSSL/SSLeay license for legacy bits).
License:        Apache-2.0
URL:            https://www.openssl.org/
Source0:        openssl-%{version}.tar.gz

# Side-install: nothing lands outside /opt/openssl-3.5, so this package does NOT
# conflict with the el7 system `openssl` 1.0.2k (libcrypto.so.10 / libssl.so.10,
# /usr/bin/openssl, /usr/include/openssl). Different sonames (libcrypto.so.3 /
# libssl.so.3) and a private prefix keep both usable at the same time.
#
# NOTE: the debuginfo scanner chokes on the huge optimized objects; skip it.
%global debug_package %{nil}
%global _prefixdir /opt/openssl-3.5

# The convenience scripts under $prefix/ssl/misc/*.pl drag in non-core perl
# modules (notably perl(WWW::Curl::Easy) from tsget.pl). They are optional helpers,
# so drop the auto-generated perl(...) requires rather than force a hard dependency.
%global __requires_exclude ^perl\\(

# RPM on el7 is 4.11: no %make_build / %cmake macros — drive the Perl Configure by hand.
BuildRequires:  perl-core
BuildRequires:  gcc
BuildRequires:  make
BuildRequires:  diffutils
BuildRequires:  which

%description
OpenSSL 3.5.9 installed entirely under /opt/openssl-3.5. It is meant to coexist with
the base OS OpenSSL 1.0.2k: use /opt/openssl-3.5/bin/openssl for the CLI, and link
against -L/opt/openssl-3.5/lib64 -lssl -lcrypto for the 3.x API. The libraries carry
an RPATH of /opt/openssl-3.5/lib64, so no ldconfig or LD_LIBRARY_PATH is required.

%prep
%autosetup -n openssl-%{version}

%build
# no-tests: skip the (very long) test suite during packagerbuild; CI runs its own check.
# no-docs: skip manpages; RPATH keeps the side-install self-contained without ldconfig.
./Configure \
  --prefix=%{_prefixdir} \
  --openssldir=%{_prefixdir}/ssl \
  --libdir=lib64 \
  -Wl,-rpath,%{_prefixdir}/lib64 \
  shared no-tests no-docs
make %{?_smp_mflags}

%install
rm -rf %{buildroot}
make DESTDIR=%{buildroot} install_sw install_ssldirs

%files
%{_prefixdir}

%changelog
* Wed Sep 30 2026 Example Packager <packager@example.com> - 3.5.9-1
- Side-install of OpenSSL 3.5.9 under /opt/openssl-3.5 (coexists with system 1.0.2k)
