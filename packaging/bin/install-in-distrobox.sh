#!/usr/bin/env bash
# Manage an el7 distrobox and install a built .rpm into it.
# Runs in host mode on the deploy-host runner (the only box with distrobox).
#
# Select the package with PKG=<name> (default: openssl35); see packaging/pkgs/<name>.env.
#
# One box flavour is supported (via env):
#   ubi7  CICD_BOX=ubi7  CICD_IMAGE=localhost/ubi7-base:latest
#         CICD_BASE_CONTEXT=packaging/rhel7   -> built locally (ubi7 + OL7 repo)
#   Or pull any base as-is with CICD_BASE_CONTEXT empty.
#
# Usage:
#   install-in-distrobox.sh bootstrap # build/pull the base image + create the box if missing
#   install-in-distrobox.sh fetch     # download the CI artifact into ${ARTIFACT_DIR}
#   install-in-distrobox.sh install   # install the downloaded rpm(s) + verify
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PKG="${PKG:-openssl35}"
PKG_ENV="${REPO_ROOT}/packaging/pkgs/${PKG}.env"
[ -f "${PKG_ENV}" ] || { echo "ERROR: no such package env: ${PKG_ENV}" >&2; exit 1; }
# shellcheck source=/dev/null
source "${PKG_ENV}"

GITEA_URL="${GITEA_URL:-https://gitea.example.com}"
REPO="${REPO:-}"
TOKEN="${GITEA_TOKEN:-${GITHUB_TOKEN:-}}"
BOX="${CICD_BOX:-ubi7}"
IMAGE="${CICD_IMAGE:-localhost/ubi7-base:latest}"
# Use ${VAR-default} (not :-) so an explicitly empty value means "no local build".
BASE_CONTEXT="${CICD_BASE_CONTEXT-packaging/rhel7}"
ART_DIR="${ARTIFACT_DIR:-$HOME/el7-artifacts}"
# Artifact name defaults to the per-package convention (see the workflow).
ART_NAME="${ARTIFACT_NAME:-rpm-package-${NAME}}"
BIN_PATH="${BINARY:-${NAME}}"
RPM_PKG="${NAME}"

api() { curl -fsSL -H "Authorization: token ${TOKEN}" "$@"; }

find_rpms() { find "${ART_DIR}" -name '*.rpm' ! -name '*.src.rpm' 2>/dev/null | sort; }

# Verify inside the box: rpmdb record, on-disk integrity, and the binary/version.
verify() {
  local box="$1"
  echo "==> verifying ${RPM_PKG} in ${box}"
  distrobox enter "${box}" -- rpm -q "${RPM_PKG}"
  distrobox enter "${box}" -- rpm -V "${RPM_PKG}" && echo "rpm -V: OK"
  if [ "${BIN_PATH#/}" != "${BIN_PATH}" ]; then
    distrobox enter "${box}" -- test -x "${BIN_PATH}"          # absolute path (e.g. /opt/...)
  else
    distrobox enter "${box}" -- sh -c 'command -v "$1"' sh "${BIN_PATH}"
  fi
  if [ -n "${VERIFY_CMD:-}" ]; then
    distrobox enter "${box}" -- sh -c "${VERIFY_CMD}"
  fi
  echo "verify: OK"
}

cmd="${1:-install}"

case "${cmd}" in
bootstrap)
  if [ -n "${BASE_CONTEXT}" ]; then
    echo "==> building base image ${IMAGE} from ${BASE_CONTEXT}"
    podman build -t "${IMAGE}" "${REPO_ROOT}/${BASE_CONTEXT}"
  else
    echo "==> pulling base image ${IMAGE}"
    podman pull "${IMAGE}"
  fi

  if distrobox list | awk -F'|' '{print $2}' | grep -qx "[[:space:]]*${BOX}[[:space:]]*"; then
    echo "==> distrobox '${BOX}' already exists"
  else
    echo "==> creating distrobox '${BOX}' from ${IMAGE}"
    distrobox create --name "${BOX}" --image "${IMAGE}" --yes
  fi
  ;;

fetch)
  if [ -n "$(find_rpms)" ]; then
    echo "==> rpms already present in ${ART_DIR}, skipping download"
    find_rpms | xargs -r ls -l
    exit 0
  fi

  : "${REPO:?REPO env required (e.g. example-org/cicd)}"
  : "${TOKEN:?GITEA_TOKEN or GITHUB_TOKEN required}"
  mkdir -p "${ART_DIR}"

  echo "==> querying artifacts for ${REPO} (name: ${ART_NAME})"
  URL_TO_ZIP=$(api "${GITEA_URL}/api/v1/repos/${REPO}/actions/artifacts" \
    | jq -r --arg n "${ART_NAME}" '[.artifacts[] | select(.name==$n)] | sort_by(.created_at) | last | .archive_download_url')

  if [ -z "${URL_TO_ZIP}" ] || [ "${URL_TO_ZIP}" = "null" ]; then
    echo "ERROR: no ${ART_NAME} artifact found for ${REPO}" >&2
    exit 1
  fi

  echo "==> downloading ${URL_TO_ZIP}"
  api -L -o "${ART_DIR}/${ART_NAME}.zip" "${URL_TO_ZIP}"
  python3 -m zipfile -e "${ART_DIR}/${ART_NAME}.zip" "${ART_DIR}/"
  rm -f "${ART_DIR}/${ART_NAME}.zip"

  echo "==> rpm(s):"
  find_rpms | xargs -r ls -l
  ;;

install)
  mapfile -t rpms < <(find_rpms)
  if [ "${#rpms[@]}" -eq 0 ]; then
    echo "ERROR: no .rpm under ${ART_DIR}; run '$0 fetch' first" >&2
    exit 1
  fi

  echo "==> installing into distrobox '${BOX}'"
  # ubi7 has only yum (no dnf).
  # Idempotent: re-running with the same version fails with el7 yum ("does not update
  # installed package"), so reinstall when it is already present.
  distrobox enter "${BOX}" -- sh -c '
    set -e
    mgr=yum
    echo "    package manager: ${mgr}"
    for rpm in "$@"; do
      pkg=$(rpm -qp --qf "%{NAME}" "$rpm")
      if rpm -q "$pkg" >/dev/null 2>&1; then
        echo "    ${pkg} present -> ${mgr} reinstall"
        sudo "${mgr}" reinstall -y "$rpm"
      else
        sudo "${mgr}" install -y "$rpm"
      fi
    done
  ' sh "${rpms[@]}"

  verify "${BOX}"
  ;;

*)
  echo "usage: $0 {bootstrap|fetch|install}" >&2
  exit 2
  ;;
esac
