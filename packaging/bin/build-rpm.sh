#!/usr/bin/env bash
# Build an .rpm from a pinned source archive.
# Runs inside the el7 build container on the build-host runner.
#
# Select the package with PKG=<name> (default: openssl35); see packaging/pkgs/<name>.env.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PKG="${PKG:-openssl35}"
PKG_ENV="${REPO_ROOT}/packaging/pkgs/${PKG}.env"
[ -f "${PKG_ENV}" ] || { echo "ERROR: no such package env: ${PKG_ENV}" >&2; exit 1; }
# shellcheck source=/dev/null
source "${PKG_ENV}"

TOPDIR="${RPMBUILD_TOPDIR:-/tmp/rpmbuild}"
SPEC_SRC="${REPO_ROOT}/packaging/${NAME}.spec"
RPMBUILD_EXTRA="${RPMBUILD_EXTRA:-}"
SRC_FILE="${SRC_FILE:-${NAME}-${COMMIT}.tar.gz}"

echo "==> building ${NAME}-${VERSION}-${RELEASE} (pkg=${PKG})"

if ! rpm -q rpm-build rpmdevtools >/dev/null 2>&1; then
  echo "ERROR: rpm-build/rpmdevtools missing" >&2
  exit 1
fi

# Clean subdirs only (TOPDIR may be a mountpoint; rm -rf on it would be EBUSY).
rm -rf "${TOPDIR}"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
mkdir -p "${TOPDIR}"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

echo "==> fetching ${TARBALL}"
curl -fsSL -o "${TOPDIR}/SOURCES/${SRC_FILE}" "${TARBALL}"

echo "==> verifying sha256"
echo "${SHA256}  ${TOPDIR}/SOURCES/${SRC_FILE}" | sha256sum -c -

cp "${SPEC_SRC}" "${TOPDIR}/SPECS/"

echo "==> rpmbuild -ba"
rpmbuild -ba "${TOPDIR}/SPECS/${NAME}.spec" \
  --define "_topdir ${TOPDIR}" \
  --define "_sourcedir ${TOPDIR}/SOURCES" \
  ${RPMBUILD_EXTRA}

echo "==> artifacts:"
find "${TOPDIR}/RPMS" -name '*.rpm' -print
