#!/usr/bin/env bash
# One-time (idempotent) setup of the build-host act_runner for the el7 RPM pipeline.
# Run ON the build-host host with sudo:
#
#   sudo bash setup-build-runner.sh
#
# It (1) adds the el7 runner labels to the runner config and (2) logs the runner
# into the Red Hat registry so the real-RHEL-7 job can pull its image. It does NOT
# store any secret in this repo: the registry credentials land in the runner's HOME
# (/var/lib/act_runner/.docker/config.json), file mode 600.
set -euo pipefail

RUNNER_DIR="${RUNNER_DIR:-/var/lib/act_runner}"
CONFIG="${RUNNER_DIR}/config.yaml"

# label=target pairs in act_runner's "<label>:docker://<image>" form.
#   rhel7      real RHEL 7 (needs Red Hat registry login + subscription entitlements)
#   rhel7-ol7  binary-compatible fallback (Oracle Linux 7), full toolchain built in
#   ubi7       free RHEL 7 userland, used by the clean-room verify job
LABELS=(
  "rhel7:docker://registry.redhat.io/rhel7/rhel:7.9"
  "rhel7-ol7:docker://oraclelinux:7"
  "ubi7:docker://registry.access.redhat.com/ubi7/ubi"
)

[ -f "${CONFIG}" ] || { echo "ERROR: ${CONFIG} not found" >&2; exit 1; }

echo "==> ensuring runner labels in ${CONFIG}"
python3 - "${CONFIG}" "${LABELS[@]}" <<'PY'
import sys, re
path, entries = sys.argv[1], sys.argv[2:]
# entry = "label:image" -> act_runner wants  - "label:image"
pairs = [(e.split(":", 1)[0], e) for e in entries]
text = open(path).read()
lines = text.splitlines()
out, in_labels, indent = [], False, "    "
existing = set()
for ln in lines:
    if re.match(r'^\s*labels:\s*$', ln):
        in_labels = True; out.append(ln); continue
    if in_labels:
        m = re.match(r'^\s*- "([^:"]+)(?::.*)?"\s*$', ln)
        if m:
            indent = re.match(r'^(\s*)', ln).group(1)
            existing.add(m.group(1)); out.append(ln); continue
        in_labels = False
    out.append(ln)
missing = [(n, e) for n, e in pairs if n not in existing]
if not missing:
    print("   all labels already present")
else:
    last = max(i for i, ln in enumerate(out) if re.match(r'^\s*- "', ln))
    for n, e in missing:
        out.insert(last + 1, f'{indent}- "{e}"'); last += 1
    print("   added: " + ", ".join(n for n, _ in missing))
open(path, "w").write("\n".join(out) + "\n")
PY

echo "==> pulling images (so the first CI run is fast)"
docker pull oraclelinux:7 || echo "   WARN: could not pull oraclelinux:7"
docker pull registry.access.redhat.com/ubi7/ubi || echo "   WARN: could not pull ubi7"

# The real-RHEL-7 image is optional; only the rhel7 (not rhel7-ol7) job needs it.
echo "==> registry.redhat.io login (optional; only for the real-RHEL-7 job)"
if [ -n "${RHSM_USER:-}" ] && [ -n "${RHSM_PASS:-}" ]; then
  echo "${RHSM_PASS}" | env HOME="${RUNNER_DIR}" docker login registry.redhat.io \
    -u "${RHSM_USER}" --password-stdin
  docker pull registry.redhat.io/rhel7/rhel:7.9 || echo "   WARN: could not pull rhel7"
else
  echo "   skipped: set RHSM_USER/RHSM_PASS to log in and pre-pull registry.redhat.io/rhel7/rhel:7.9"
  echo "   (not needed for the active rhel7-ol7 job)"
fi

echo "==> restarting act_runner"
systemctl restart act_runner
sleep 2
systemctl --no-pager --lines=0 status act_runner | head -4
echo "==> done. labels now:"
grep -A15 -E '^[[:space:]]*labels:' "${CONFIG}"
