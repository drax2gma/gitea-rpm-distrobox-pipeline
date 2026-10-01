# gitea-rpm-distrobox-pipeline — Gitea Actions: build RPM → install into distrobox

Generic pipeline that builds `.rpm` packages from pinned upstream sources on a
clean **Oracle Linux 7** container (RHEL 7 ABI), then verifies them in a clean
**ubi7** container and installs them into the persistent **`ubi7` distrobox** on
a host-mode runner (`deploy-host` here is a placeholder label).

Currently packages OpenSSL 3.5.9 (`openssl35`, side-installed to `/opt/openssl-3.5`).

## Architecture

```
upstream tarball (SHA256-verified)
        │  job: build        runs-on: rhel7-ol7
        ▼
[build-host act_runner v0.6.1] ──► docker://oraclelinux:7  (RHEL 7 ABI, ol7_latest built in)
        │  EPEL7 archive (cmake3)
        │  perl Configure + make → rpmbuild -ba → openssl35-*.el7.rpm
        │  actions/upload-artifact v3 (name: rpm-package-openssl35)
        ▼
[Gitea artifact store]
        │  job: verify-ubi7  runs-on: deploy-host    needs: build
        │  podman run ubi7 → rpm -ivh --noscripts → rpm -q/-V + version check
        ▼
        │  job: deploy       runs-on: deploy-host    needs: build
        ▼
[deploy-host host-mode act_runner] ──► shell (runner)
        │  curl Gitea artifact API → unzip → *.rpm
        │  podman build ubi7-base → distrobox create ubi7
        │  distrobox enter ubi7 -- sudo yum install -y *.rpm
        ▼
   verify: rpm -q / rpm -V / <binary> version
```

## Repo layout

```
.gitea/workflows/build-rpm.yml    the pipeline (build → verify-ubi7 → deploy)
infra.env.example                 template for the local, gitignored infra overlay
packaging/pkgs/<name>.env         per-package source of truth: NAME/VERSION/TARBALL/SHA256/BINARY
packaging/<name>.spec             per-package spec (openssl35 = Perl Configure)
packaging/bin/build-rpm.sh        fetch + verify + rpmbuild -ba (PKG=<name>, RPMBUILD_EXTRA="--nodeps" on el7)
packaging/bin/install-in-distrobox.sh   bootstrap/fetch/install/verify into ubi7 (PKG=<name>)
packaging/bin/setup-build-runner.sh      one-time build-host runner setup (labels + registry login)
packaging/rhel7/epel7.repo        EPEL7 archive repo (cmake3)
packaging/rhel7/ol7.repo          Oracle Linux 7 repo (distrobox-init deps for the ubi7 base)
packaging/rhel7/Containerfile     ubi7 + OL7 repo → localhost/ubi7-base (ubi7 distrobox)
packaging/rhel7/macros.cmake-compat %cmake/%cmake_build/%cmake_install → cmake3
templates/spec.tmpl               generic CMake/C spec template
```

## Run it on your own infra

The committed workflow is generic: runner labels and the artifact staging dir are
read from **Gitea repository variables**, each with a portable default:

```yaml
runs-on: ${{ vars.BUILD_RUNNER  || 'rhel7-ol7' }}
runs-on: ${{ vars.DEPLOY_RUNNER || 'deploy-host' }}
path:    ${{ vars.ARTIFACT_BASE || '/home/runner/el7-artifacts' }}
```

Your real values never enter the repo. Copy the template to the gitignored
`infra.env`, edit, and push the CI variables to the repo:

```bash
cp infra.env.example infra.env
$EDITOR infra.env          # REPO, GITEA_URL, BUILD_HOST, remotes, runner labels, ARTIFACT_BASE
make vars-push             # POST/PUT the CI variables as Gitea repo variables
make vars-list             # show what Gitea has
```

`infra.env` is also included by the Makefile, so the local targets (`make push`,
`make status`, `make ci-build`, `make logs`) use your repo/URLs too.

### Requirements

- A Gitea instance with Actions enabled and two self-hosted runners:
  - a **docker-mode** runner with an `oraclelinux:7`-capable label (`rhel7-ol7`),
  - a **host-mode** runner with `podman` + `distrobox` on the deploy host.
  See [Runners](#runners) and `packaging/bin/setup-build-runner.sh`.
- The workflow uses Gitea-specific contexts (`gitea.repository`, `gitea.server_url`)
  and actions v3, so it is **Gitea Actions only** (not GitHub Actions).

## Packages

Each package lives in `packaging/pkgs/<name>.env` (source pin) + `packaging/<name>.spec`.
The workflow builds them in a matrix; add a package by adding those two files and a
`pkg:` entry to each job's `matrix.include`.

| pkg | source | installs to | notes |
|-----|--------|-------------|-------|
| `openssl35` | release tarball 3.5.9 | `/opt/openssl-3.5` | side-install; coexists with system OpenSSL 1.0.2k |

### openssl35 (OpenSSL 3.5.9, side-install)

OpenSSL 3 is built with Perl `Configure` (not CMake) and **side-installed** under
`/opt/openssl-3.5` so it does **not** collide with the el7 base `openssl` 1.0.2k
(`/usr/bin/openssl`, `/usr/include/openssl`, `libcrypto.so.10`/`libssl.so.10`). The 3.x
libs use different sonames (`libcrypto.so.3`/`libssl.so.3`) and both can be present at once.

- `BuildRequires: perl-core` — on RPM distros OpenSSL needs the core Perl modules
  (NOTES-PERL.md); plain `perl` is not enough.
- Built with `shared no-tests no-docs`, `--libdir=lib64`, and an RPATH of
  `/opt/openssl-3.5/lib64`, so **no `%post`/ldconfig** is needed (avoids the el7 rpm
  scriptlet-spin trap on build-host).
- `__requires_exclude ^perl\(` drops auto-requires from optional `ssl/misc/*.pl`
  helpers (e.g. `perl(WWW::Curl::Easy)` from `tsget.pl`).
- Verified upstream: it compiles under el7 **gcc 4.8.5 / glibc 2.17**.
- Use: `/opt/openssl-3.5/bin/openssl`, and `-L/opt/openssl-3.5/lib64 -lssl -lcrypto`
  (headers in `/opt/openssl-3.5/include`).

## el7 targets

| job | runner label | image | purpose |
|-----|--------------|-------|---------|
| `build` | `rhel7-ol7` | `oraclelinux:7` | **build** on binary-compatible OL7 (full toolchain via `ol7_latest`, no subscription) |
| `build` (alt) | `rhel7` | `registry.redhat.io/rhel7/rhel:7.9` | build on real RHEL 7 (needs login + entitlements) |
| `verify-ubi7` | `deploy-host` (host) | `registry.access.redhat.com/ubi7/ubi` | clean-room install check on a free RHEL 7 userland |
| `deploy` → `ubi7` box | `deploy-host` (host) | `localhost/ubi7-base` (ubi7 derived) | install into a persistent RHEL 7.9 distrobox |

The spec and `build-rpm.sh` are **unchanged across targets** — only the runner image
and repo config differ. `cmake3` comes from the EPEL7 archive
(`packaging/rhel7/epel7.repo`); the base el7 `cmake` is 2.8.

### Why Oracle Linux 7 (no subscription)

`registry.redhat.io/rhel7/rhel` requires a **Red Hat login to pull** (a free developer
account works), but `yum install …` inside it needs **subscription entitlements** for
`rhel-7-server-rpms`/`-optional`/`-extras`. On a **non-RHEL host** (build-host runs Debian +
Docker) those entitlements do **not** propagate into the container, and a plain
`docker login` only authorizes the pull — so the real-RHEL-7 job would fail at
`yum install`. RHEL 7 is also post-EOL, so servicing 7.9 channels needs a (usually
paid) ELS subscription.

The `rhel7-ol7` path sidesteps all of that: Oracle Linux 7 is a binary-compatible
RHEL 7 rebuild, `ol7_latest` is built into the image and carries the whole toolchain,
and the resulting `.el7` RPM is RHEL 7-installable. `verify-ubi7` then proves the
install on a free RHEL 7 userland (UBI 7).

To move to real RHEL 7 later: set `runs-on: rhel7`, create a RHEL 7 activation key,
add the `RHSM_ORG` / `RHSM_ACTIVATION_KEY` repo secrets, and add a register step
(`subscription-manager register --org … --activationkey …`) before the toolchain install.

### One-time build-host runner setup

```bash
scp packaging/bin/setup-build-runner.sh build-host:/tmp/
ssh build-host 'sudo bash /tmp/setup-build-runner.sh'          # interactive registry login
# or, if you also want the real-RHEL-7 image logged in:
ssh build-host 'sudo RHSM_USER=you@example.com RHSM_PASS=*** bash /tmp/setup-build-runner.sh'
```

It adds the `rhel7`, `rhel7-ol7` and `ubi7` labels to
`/var/lib/act_runner/config.yaml`, pre-pulls the images, restarts
`act_runner`, and (if credentials are given) runs `docker login registry.redhat.io`
into the runner's HOME (`…/.docker/config.json`, mode 600 — **never** in this repo).
Idempotent.


## Adding another package

1. Add `packaging/pkgs/<name>.env` (NAME, VERSION, TARBALL, SHA256, SRC_FILE, TOPLEVEL, BINARY).
2. Add `packaging/<name>.spec` (use `templates/spec.tmpl` as a base for CMake/C projects).
3. Add a `pkg: <name>` entry to the `matrix.include` of each job in the workflow, and a
   `verify` line for it in `verify-ubi7`.

Build/install a single package locally:

```bash
PKG=openssl35 bash packaging/bin/build-rpm.sh                       # inside an el7 container
PKG=openssl35 ARTIFACT_DIR=/tmp/art bash packaging/bin/install-in-distrobox.sh install
```

## Runners

| host  | runner name    | label          | mode   | purpose |
|-------|----------------|----------------|--------|---------|
| build-host | `build-runner` | `rhel7`        | docker | real RHEL 7 build (needs registry login + entitlements) |
| build-host | `build-runner` | `rhel7-ol7`    | docker | **active** Oracle Linux 7 build |
| build-host | `build-runner` | `ubi7`         | docker | clean-room RHEL 7 install verify |
| build-host | `build-runner` | `ubuntu-*`     | docker | other repos |
| build-host | `build-runner` | `almalinux9`   | docker | kept for other repos |
| deploy-host| `deploy-runner`| `deploy-host`       | host   | distrobox bootstrap + install (needs the host) |

- build-host runner: `/var/lib/act_runner/`, labels in `config.yaml`,
  `sudo systemctl restart act_runner` (the daemon logs `labels updated to: [...]`
  on startup, so editing `config.yaml` is enough — no re-registration needed).
  **act_runner ignores labels not in `name:docker://image` form** (a bare `name:image`
  is silently dropped — see the journal `ignored invalid label ... unsupported schema`).
- deploy-host runner: `~/.config/act_runner/`, systemd **user** service
  (`systemctl --user status act_runner`), linger enabled.

## Distrobox

The deploy job installs the ol7-built `.el7` RPM into the persistent `ubi7` box on
`deploy-host` (its derived base image is built on first deploy):

| box | base image | userland | package mgr |
|-----|-----------|----------|-------------|
| `ubi7` | `localhost/ubi7-base` (from `packaging/rhel7`, `ubi7/ubi` + OL7 repo) | RHEL 7.9 | `yum` |

```bash
make box-ubi7       # create ubi7 (builds ubi7-base if missing)
make boxes          # list distroboxes
make install-ubi7   # install the built RPM (ARTIFACT_DIR under ~/el7-artifacts)
```

`install-in-distrobox.sh` is box-agnostic: it builds the base only when
`CICD_BASE_CONTEXT` is set (otherwise it pulls `CICD_IMAGE`).

### Why `ubi7` uses a ubi7 *derived* base, not the bare image

`registry.access.redhat.com/ubi7/ubi` is a minimal runtime image: its only repo
(`ubi-7`) is missing base packages that `distrobox-init` installs on first enter
(`fipscheck-lib`, `libedit`, `openssh-clients`, …), and EPEL7 does not carry them
either — the first `distrobox enter` dies in "Installing basic packages". Adding the
**Oracle Linux 7** repo (`yum.oracle.com`, same el7 ABI) resolves them. The resulting
box still reports `Red Hat Enterprise Linux Server release 7.9 (Maipo)`; it is a free,
unsubscribed RHEL 7 userland. It is **not** entitlement-backed: `yum` can install from
OL7/EPEL, but not from `rhel-7-server-*` (see the el7 targets section above).

## Local dev (Makefile)

```bash
make help          # list targets
make vars-push     # push CI variables from infra.env to Gitea
make vars-list     # list the Gitea repo variables
make status        # last Gitea workflow runs
make logs          # tail the build-host runner log
make logs-deploy   # tail the deploy-host runner log
make ci m='msg'    # commit + push (gitea + github); does NOT build
make ci-build      # trigger the build workflow (manual dispatch)
```

## Manual run

Pushing to `main` does **not** build; the workflow is `workflow_dispatch` only:

```bash
make ci-build           # trigger the build (API dispatch)
# or Gitea UI → Actions → build-rpm → Run workflow

# watch
ssh build-host "sudo journalctl -u act_runner -f"      # build job
journalctl --user -u act_runner -f               # verify + deploy jobs
```

## Open decisions

- **License**: openssl35 is `Apache-2.0`.
- **Version**: openssl35 pins the official signed release tarball 3.5.9 (SHA256-verified).
- **Artifact auth**: the deploy job uses `secrets.GITHUB_TOKEN` (Gitea-provided).
- **RHEL 7 is EOL** (2024-06-30): the packages deliberately target an EOL distro;
  repos are pinned archives with `gpgcheck=0`.
- **openssl35 packaging**: OpenSSL 3 uses Perl `Configure`, so `build-rpm.sh` fetches a
  `TARBALL` (per-package) rather than a commit archive. Side-installed to `/opt` to dodge
  the system 1.0.2k collision; see the openssl35 section above.
- **Artifact naming**: one artifact per package: `rpm-package-<pkg>`. The deploy job
  installs each package into the `ubi7` distrobox.
- **Remotes**: `make ci` / `make push` push to every remote in `REMOTES`
  (default `gitea github`). Neither push triggers a build: the workflow is manual
  (`make ci-build` / UI / API dispatch).
- **Infra binding**: the workflow reads runner labels and the artifact dir from
  Gitea repo variables (`make vars-push`); the local overlay `infra.env` is
  gitignored. The committed defaults are generic (`rhel7-ol7`, `deploy-host`,
  `/home/runner/el7-artifacts`).

## el7 traps found while building this

- **The base `cmake` on el7 is 2.8**, too old for `cmake_minimum_required(3.10)`;
  **`cmake3` (3.17.5) comes from EPEL7** (`archives.fedoraproject.org/pub/archive/epel/7`).
  `gcc 4.8.5` handles C11 and the build succeeds.
- **rpm 4.11 has no `%cmake_build` / `%cmake_install`** macros. Instead of forking
  the spec, `packaging/rhel7/macros.cmake-compat` maps `%cmake`, `%cmake_build` and
  `%cmake_install` to `cmake3`, so the **same `packaging/<name>.spec` builds on el7**.
- **`--nodeps` is required** on el7: `BuildRequires: cmake` would resolve to the
  2.8 package, which is not what we want installed. `build-rpm.sh` passes it via
  `RPMBUILD_EXTRA=--nodeps`; the container is controlled, so skipping the check is safe.
- **rpm scriptlets spin at 100% CPU on the build-host host**: every el7 package with a
  scriptlet took ~7 minutes to install there (`yum` *and* `rpm -ivh`), while
  `--noscripts` installs the same package in <1 s. The spin is rpm's scriptlet
  child (0 voluntary context switches, rpmdb FDs open); root cause not fully
  identified — the el9/dnf path is unaffected. Workaround: install the build
  toolchain with `--setopt=tsflags=noscripts`; inside the disposable build
  container the skipped `install-info`/`ldconfig` scriptlets don't matter
  (toolchain + node: seconds, rpmbuild: ~2 s on build-host).
- **No node20 on el7** (glibc 2.17; NodeSource 18+ requires 2.27) → `actions/checkout@v4`
  cannot run. The build job fetches the repo through the **Gitea archive API** instead.
  `upload-artifact@v3` declares **node16**, so NodeSource `setup_16.x` is enough to run it.
- The **host-runner checkout trap** still applies to the deploy job: `actions/checkout`
  builds its remote from `github.server_url`, which for subpath-hosted Gitea
  (`https://host/gitea`) omits the `/gitea` prefix → `repository not found`.
  Workaround: the archive API (no checkout at all).
- **`upload-artifact@v4` / `download-artifact@v4` do not work** on this Gitea
  (Gitea 1.26 runner lacks the `@actions/artifact` v2 protocol → `GHESNotSupportedError`).
  Use **v3** for both.
- `actions/download-artifact@v3` preserves the artifact's directory structure
  (here `x86_64/openssl35-*.rpm`), so locate the rpm recursively; `*.src.rpm` is
  filtered out before install.
- `act_runner register` v0.6.1 has **no `--replace`**, and it **ignores `--labels`**
  at registration time (labels come from `config.yaml`).
- **`upload-artifact@v3` runs `node` *inside the job container***, not on the runner
  host: a job image without node fails at the upload step with
  `exec: "node": executable file not found in $PATH`. The `oraclelinux:7` job must
  therefore install NodeSource `setup_16.x` too (the build itself doesn't need node).
- **act_runner silently drops labels not in `name:docker://image` form**: a bare
  `name:image` entry is ignored on startup
  (`ignored invalid label … unsupported schema`), so the label never appears.
- **The Gitea 1.26 REST `/actions/artifacts` list endpoint returns empty** (even
  right after a successful `upload-artifact@v3`). Do not fetch artifacts over the REST
  API — `actions/download-artifact@v3` uses a different internal mechanism and works.
- **`ubi7/ubi` cannot bootstrap distrobox on its own**: its only repo (`ubi-7`) lacks
  `fipscheck-lib` / `libedit` / `openssh-clients` that `distrobox-init` installs on
  first enter, and EPEL7 doesn't carry them either → first `distrobox enter` dies in
  "Installing basic packages". Fix: a derived base (`packaging/rhel7/Containerfile`)
  that adds the **Oracle Linux 7** repo (same el7 ABI, no subscription).
- **el7 `yum` is not idempotent**: re-installing an already-present same-version RPM
  fails — `yum` exits 1 with `does not update installed package` / `Error: Nothing to do`.
  Since a distrobox persists across runs, the deploy checks the package name first and
  uses `reinstall` when it is already installed.
