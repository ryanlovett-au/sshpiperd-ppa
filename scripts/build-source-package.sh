#!/usr/bin/env bash
# Build a signed Debian source package for ppa:ryanlovett/sshpiperd.
#
# Fetches the upstream sshpiper source at $UPSTREAM_TAG, vendors Go deps,
# bundles the Go toolchain upstream requires, overlays this repo's debian/
# tree, rewrites debian/changelog for the target $SERIES, and runs
# `dpkg-buildpackage -S` to produce the .dsc / .changes / .orig.tar.xz /
# .debian.tar.xz artifacts in $OUTDIR.
#
# The upstream source is packaged UNMODIFIED. Upstream tracks the newest Go
# release (go.mod `go` directive, new stdlib APIs) while every Ubuntu series
# is frozen on an older one, so building with the series' own Go broke on
# nearly every upstream release and needed a new workaround each time
# (dropping plugins, capping go directives, backporting stdlib calls). The
# source package now carries the Go toolchain itself — see "Bundling the Go
# toolchain" below — so nothing here depends on which Go a series ships.
#
# Required env:
#   UPSTREAM_TAG  e.g. v1.3.16
#   SERIES        e.g. noble  (Ubuntu release codename)
#   PPA_REV       e.g. 1      (appended as -0ppa${PPA_REV}~${SERIES}1)
#   DEBFULLNAME   e.g. "Ryan Lovett"
#   DEBEMAIL      e.g. ryan@pixelated.cloud
#   GPG_KEY_ID    fingerprint of the signing subkey (long form preferred)
#
# Optional env:
#   OUTDIR           default: $PWD/build
#   UPSTREAM_REPO    default: https://github.com/tg123/sshpiper.git
#   CHANGELOG_MSG    default: "Automated build for ${UPSTREAM_TAG} on ${SERIES}
#                    (bundled Go <version>)"
#   NO_SIGN          if set, pass -us -uc (unsigned; for local dry-runs only)
#   REBUILD          rebuild number (2, 3, …) for re-uploading a tag whose
#                    earlier upload for this series was rejected or failed to
#                    build. Launchpad never lets a version be reused, so a
#                    retry needs a new one: REBUILD=2 gives
#                    1.6.2+noble2-0ppa1~noble1, which sorts above the first
#                    attempt's 1.6.2+noble-0ppa1~noble1.
#   UPSTREAM_SUFFIX  full override of the upstream-version suffix. Defaults
#                    to "+${SERIES}${REBUILD}". Keep the series in it: each
#                    series must own its orig-tarball filename slot, because
#                    Launchpad stores one orig per <package>_<upstream-version>
#                    for the whole PPA and rejects a second upload whose
#                    bytes differ. Git clone still uses the raw UPSTREAM_TAG —
#                    only the version string moves.
#   GO_VERSION       Go toolchain to bundle, e.g. 1.27.4. Default: the latest
#                    patch release of the newest Go line upstream's go.mod
#                    files ask for.

set -euo pipefail

: "${UPSTREAM_TAG:?UPSTREAM_TAG is required (e.g. v1.3.16)}"
: "${SERIES:?SERIES is required (e.g. noble)}"
: "${PPA_REV:?PPA_REV is required (e.g. 1)}"
: "${DEBFULLNAME:?DEBFULLNAME is required}"
: "${DEBEMAIL:?DEBEMAIL is required}"

UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/tg123/sshpiper.git}"
OUTDIR="${OUTDIR:-$PWD/build}"

# Upstream version: strip leading 'v' if present, then append the suffix.
# The suffix always carries the series so each Ubuntu series owns its own
# orig filename slot on Launchpad (see UPSTREAM_SUFFIX above), plus the
# optional rebuild number. Git clone still uses raw UPSTREAM_TAG.
REBUILD="${REBUILD:-}"
if ! [[ "${REBUILD}" =~ ^[0-9]*$ ]]; then
    echo "error: REBUILD must be a number (e.g. 2), got '${REBUILD}'" >&2
    exit 1
fi
UPSTREAM_SUFFIX="${UPSTREAM_SUFFIX:-+${SERIES}${REBUILD}}"
UPSTREAM_VERSION="${UPSTREAM_TAG#v}${UPSTREAM_SUFFIX}"
DEB_VERSION="${UPSTREAM_VERSION}-0ppa${PPA_REV}~${SERIES}1"
echo "==> UPSTREAM_SUFFIX='${UPSTREAM_SUFFIX}' -> package version ${DEB_VERSION}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKDIR="$(mktemp -d -t sshpiperd-ppa.XXXXXX)"
# The Go module cache marks its directories read-only; make them writable
# again before removing or `rm -rf` fails and leaves the workdir behind.
trap 'chmod -R u+w "$WORKDIR" 2>/dev/null || true; rm -rf "$WORKDIR"' EXIT

echo "==> Cloning ${UPSTREAM_REPO} at ${UPSTREAM_TAG} (with submodules)"
# Upstream uses a `crypto` submodule (their fork of golang.org/x/crypto
# with SSH protocol patches). go.mod declares
#   replace golang.org/x/crypto => ./crypto
# so the submodule contents MUST be present at build time.
git clone --depth 1 --branch "${UPSTREAM_TAG}" \
          --recurse-submodules --shallow-submodules \
          "${UPSTREAM_REPO}" \
          "${WORKDIR}/sshpiperd-${UPSTREAM_VERSION}"

SRCDIR="${WORKDIR}/sshpiperd-${UPSTREAM_VERSION}"
cd "${SRCDIR}"

# Derive a deterministic timestamp from the upstream tag's commit, used for
# file mtimes in the orig tarball and by dpkg for the package's build date,
# so the output depends on the inputs rather than on when the job ran.
if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
    SOURCE_DATE_EPOCH="$(git log -1 --format=%ct HEAD)"
    export SOURCE_DATE_EPOCH
    echo "==> SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH} (from upstream commit)"
fi

echo "==> Removing upstream VCS state and .github (keep submodule contents)"
# `.git` in a submodule is a file pointing at the parent's .git/modules dir;
# removing it detaches the submodule but leaves its files in place, which is
# what we want in a source tarball.
find . -name .git -print0 | xargs -0 rm -rf
rm -f .gitmodules
rm -rf .github

# ---------------------------------------------------------------------------
# Go environment for this script. Pinned explicitly so nothing inherited from
# the runner (go.env, GOFLAGS, a GOPRIVATE/GONOSUMDB that would skip checksum
# verification) can change what gets downloaded or weaken how it is verified.
# Everything is fetched into a throwaway module cache under WORKDIR.
# ---------------------------------------------------------------------------
export GOMODCACHE="${WORKDIR}/gomodcache"
export GOFLAGS=-modcacherw
export GOPROXY=https://proxy.golang.org,direct
export GOSUMDB=sum.golang.org
unset GONOSUMDB GONOSUMCHECK GONOPROXY GOPRIVATE GOINSECURE GOROOT

# Any Go >= 1.21 on the runner will do: it is only a launcher that downloads
# and runs the toolchain version selected below.
if ! GOTOOLCHAIN=local go version >/dev/null 2>&1; then
    echo "error: no 'go' on PATH (any Go >= 1.21 works; it only bootstraps)" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# What do we build, and which Go modules does that involve?
#
# debian/rules builds cmd/sshpiperd plus every plugin/*/main.go, each from
# inside its own directory, so Go resolves whichever module encloses it.
# Upstream has already moved cmd/sshpiperd into a nested module once
# (v1.6.1); deriving the module list from the build targets means the next
# such restructuring needs no change here.
# ---------------------------------------------------------------------------
module_root() {
    local d="$1"
    while [ ! -f "${d}/go.mod" ]; do
        [ "${d}" = "." ] && return 1
        d="$(dirname "${d}")"
    done
    printf '%s\n' "${d}"
}

if [ ! -d cmd/sshpiperd ]; then
    echo "error: cmd/sshpiperd not found — upstream layout changed; update debian/rules and this script" >&2
    exit 1
fi
shopt -s nullglob
plugin_mains=( plugin/*/main.go )
shopt -u nullglob
if [ ${#plugin_mains[@]} -eq 0 ]; then
    echo "error: no plugin/*/main.go found — upstream layout changed; update debian/rules and this script" >&2
    exit 1
fi

MODULE_ROOTS=()
for target in cmd/sshpiperd "${plugin_mains[@]%/main.go}"; do
    if ! root="$(module_root "${target}")"; then
        echo "error: no go.mod found above ${target}" >&2
        exit 1
    fi
    seen=
    for m in "${MODULE_ROOTS[@]}"; do
        [ "${m}" = "${root}" ] && seen=1
    done
    [ -n "${seen}" ] || MODULE_ROOTS+=("${root}")
done
echo "==> Go modules to vendor: ${MODULE_ROOTS[*]}"

# ---------------------------------------------------------------------------
# Bundling the Go toolchain
#
# Launchpad builders have no network, and the Go in each Ubuntu series lags
# what upstream needs. So the toolchain goes in the source package: one
# official Go release per architecture we build for, as the module zips Go
# itself uses for toolchain switching (golang.org/toolchain@v0.0.1-goX.Y.Z.
# linux-ARCH). `go mod download` verifies each zip against the Go checksum
# database (sum.golang.org, a public transparency log) before we accept it,
# and the zips are stored byte-for-byte so anyone can re-verify them from
# the recorded h1: hashes in _gotoolchain/MANIFEST.
#
# debian/rules unpacks the zip for the build architecture and uses it for
# everything; the series' own Go is never involved.
# ---------------------------------------------------------------------------

# Newest Go version any of our modules asks for (`go` or `toolchain` line).
GO_REQUIRED=
for m in "${MODULE_ROOTS[@]}"; do
    while read -r v; do
        v="${v#go}"
        if ! [[ "${v}" =~ ^[0-9]+\.[0-9]+ ]]; then
            echo "error: cannot parse Go version '${v}' from ${m}/go.mod" >&2
            exit 1
        fi
        GO_REQUIRED="$(printf '%s\n%s\n' "${GO_REQUIRED}" "${v}" | sort -V | tail -n1)"
    done < <(awk '$1 == "go" || $1 == "toolchain" { print $2 }' "${m}/go.mod")
done
if [ -z "${GO_REQUIRED}" ]; then
    echo "error: no go directive found in: ${MODULE_ROOTS[*]}" >&2
    exit 1
fi
echo "==> Upstream requires Go >= ${GO_REQUIRED}"

# Queries about Go itself run from a scratch module, so the runner's own
# (older) Go is not asked to load upstream's go.mod.
SCRATCH_MOD="${WORKDIR}/scratchmod"
mkdir -p "${SCRATCH_MOD}"
printf 'module scratch\n\ngo 1.21\n' > "${SCRATCH_MOD}/go.mod"

if [ -z "${GO_VERSION:-}" ]; then
    # Latest patch release of the required line (1.27.0 -> 1.27.x), so the
    # binaries pick up Go's security fixes. Falls back to exactly what
    # upstream declared if the lookup fails or the line has no release yet
    # (e.g. upstream pinned a release candidate).
    GO_LINE="$(printf '%s' "${GO_REQUIRED}" | grep -oE '^[0-9]+\.[0-9]+')"
    GO_VERSION="$(cd "${SCRATCH_MOD}" \
                  && GOTOOLCHAIN=local go list -m -f '{{.Version}}' "go@${GO_LINE}" 2>/dev/null)" \
        || GO_VERSION=
    if [ -z "${GO_VERSION}" ] \
       || [ "$(printf '%s\n%s\n' "${GO_REQUIRED}" "${GO_VERSION}" | sort -V | tail -n1)" != "${GO_VERSION}" ]; then
        echo "    (could not resolve a newer ${GO_LINE}.x release — using ${GO_REQUIRED} as declared)"
        GO_VERSION="${GO_REQUIRED}"
    fi
fi
echo "==> Bundling Go ${GO_VERSION}"

# Debian architecture -> Go architecture. The list of architectures comes
# from debian/control, so the package can never be built somewhere it has no
# toolchain for: to add one, add it to Architecture: there and to this table.
go_arch_for() {
    case "$1" in
        amd64)   echo amd64 ;;
        arm64)   echo arm64 ;;
        armhf)   echo arm ;;
        i386)    echo 386 ;;
        ppc64el) echo ppc64le ;;
        riscv64) echo riscv64 ;;
        s390x)   echo s390x ;;
        *)       return 1 ;;
    esac
}

mapfile -t DEB_ARCHES < <(awk '/^Architecture:/ { for (i = 2; i <= NF; i++) print $i }' \
                              "${REPO_ROOT}/debian/control" | sort -u)
if [ ${#DEB_ARCHES[@]} -eq 0 ]; then
    echo "error: no Architecture: field found in debian/control" >&2
    exit 1
fi

mkdir -p _gotoolchain
: > _gotoolchain/MANIFEST
for deb_arch in "${DEB_ARCHES[@]}"; do
    if ! go_arch="$(go_arch_for "${deb_arch}")"; then
        echo "error: debian/control lists Architecture '${deb_arch}', which has no Go toolchain mapping in $0 (wildcards like 'any' are not supported — list architectures explicitly)" >&2
        exit 1
    fi
    mod_version="v0.0.1-go${GO_VERSION}.linux-${go_arch}"
    echo "    golang.org/toolchain@${mod_version} (for ${deb_arch})"
    info="$(cd "${SCRATCH_MOD}" \
            && GOTOOLCHAIN=local go mod download -json "golang.org/toolchain@${mod_version}")"
    zip="$(jq -r '.Zip // empty' <<< "${info}")"
    sum="$(jq -r '.Sum // empty' <<< "${info}")"
    if [ -z "${zip}" ] || [ ! -s "${zip}" ] || [ -z "${sum}" ]; then
        echo "error: failed to download Go ${GO_VERSION} for linux-${go_arch}:" >&2
        echo "${info}" >&2
        exit 1
    fi
    # Named by Debian architecture so debian/rules needs no mapping table.
    cp "${zip}" "_gotoolchain/${deb_arch}.zip"
    printf '%s %s golang.org/toolchain %s %s\n' \
        "${deb_arch}" "${go_arch}" "${mod_version}" "${sum}" >> _gotoolchain/MANIFEST
done
cat > _gotoolchain/README <<EOF
Go ${GO_VERSION} toolchains, added by the sshpiperd-ppa packaging (not part of
upstream sshpiper). debian/rules builds the package with the one matching
the build architecture, because the Go shipped by Ubuntu is older than
upstream sshpiper requires and Launchpad builders have no network access.

Each <arch>.zip is the unmodified Go toolchain module from proxy.golang.org.
MANIFEST lists, per Debian architecture: the Go architecture, module path,
module version and the h1: hash that was verified against the Go checksum
database (https://sum.golang.org) when this source package was assembled.
EOF

# From here on, every `go` invocation in this script runs as exactly the
# bundled version — the same one that will compile the binaries.
export GOTOOLCHAIN="go${GO_VERSION}"

echo "==> Vendoring Go dependencies (Launchpad builders have no network)"
for m in "${MODULE_ROOTS[@]}"; do
    echo "    go mod vendor in ${m}"
    (cd "${m}" && go mod vendor)
done

echo "==> Overlaying debian/ tree from ${REPO_ROOT}"
cp -a "${REPO_ROOT}/debian" ./debian
# Ensure executable bits on maintainer scripts + rules (tar preserves, but be safe).
chmod +x debian/rules
for f in debian/*.preinst debian/*.postinst debian/*.prerm debian/*.postrm; do
    [ -f "$f" ] && chmod +x "$f"
done

echo "==> Creating orig tarball"
mkdir -p "${OUTDIR}"
# dpkg-source 3.0 (quilt) looks for the orig tarball at ../<pkg>_<ver>.orig.*
# relative to the source directory, so stage it in WORKDIR (the parent of
# SRCDIR) first. We'll move it to OUTDIR with the rest of the artifacts.
ORIG_TARBALL="${WORKDIR}/sshpiperd_${UPSTREAM_VERSION}.orig.tar.xz"
# The toolchain zips are ~75 MB each and already compressed; -T0 lets xz use
# every core so this takes seconds rather than minutes.
tar --sort=name --owner=0 --group=0 --numeric-owner \
    --mtime="@${SOURCE_DATE_EPOCH:-$(date +%s)}" \
    -C "${WORKDIR}" -I 'xz -T0' -cf "${ORIG_TARBALL}" \
    --exclude='sshpiperd-*/debian' \
    "sshpiperd-${UPSTREAM_VERSION}"
echo "    -> ${ORIG_TARBALL}"

echo "==> Rewriting debian/changelog for ${DEB_VERSION} / ${SERIES}"
export DEBFULLNAME DEBEMAIL
CHANGELOG_MSG="${CHANGELOG_MSG:-Automated build for ${UPSTREAM_TAG} on ${SERIES} (bundled Go ${GO_VERSION})}"
# Replace the changelog entirely so re-runs are idempotent and the version
# string is always the one we computed (not whatever was committed).
rm -f debian/changelog
dch --create --package sshpiperd \
    --newversion "${DEB_VERSION}" \
    --distribution "${SERIES}" \
    --urgency medium \
    "${CHANGELOG_MSG}"

echo "==> Building source package"
BUILD_FLAGS=(-S -sa -d)
if [ -n "${NO_SIGN:-}" ]; then
    BUILD_FLAGS+=(-us -uc)
    echo "    (unsigned build — NO_SIGN set)"
else
    : "${GPG_KEY_ID:?GPG_KEY_ID is required unless NO_SIGN=1}"
    BUILD_FLAGS+=(-k"${GPG_KEY_ID}")
fi

dpkg-buildpackage "${BUILD_FLAGS[@]}"

echo "==> Collecting artifacts into ${OUTDIR}"
cd "${WORKDIR}"
# No `|| true`: a missing artifact must stop the run here, not surface later
# as a confusing dput or Launchpad failure.
mv -v \
    "sshpiperd_${UPSTREAM_VERSION}.orig.tar.xz" \
    "sshpiperd_${DEB_VERSION}.dsc" \
    "sshpiperd_${DEB_VERSION}.debian.tar."* \
    "sshpiperd_${DEB_VERSION}_source.changes" \
    "sshpiperd_${DEB_VERSION}_source.buildinfo" \
    "${OUTDIR}/"

echo "==> Done. Artifacts in ${OUTDIR}:"
ls -l "${OUTDIR}"

cat <<EOF

Next steps (automated by the ppa-release workflow):
  SERIES=${SERIES} scripts/test-binary-build.sh   # offline build test, needs Docker
  dput ppa:ryanlovett/sshpiperd ${OUTDIR}/sshpiperd_${DEB_VERSION}_source.changes
EOF
