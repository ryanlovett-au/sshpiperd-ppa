#!/usr/bin/env bash
# Build a signed Debian source package for ppa:ryanlovett/sshpiperd.
#
# Fetches the upstream sshpiper source at $UPSTREAM_TAG, vendors Go deps,
# overlays this repo's debian/ tree, rewrites debian/changelog for the
# target $SERIES, and runs `dpkg-buildpackage -S` to produce the .dsc /
# .changes / .orig.tar.xz / .debian.tar.xz artifacts in $OUTDIR.
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
#   CHANGELOG_MSG    default: "Automated build for ${UPSTREAM_TAG} on ${SERIES}"
#   NO_SIGN          if set, pass -us -uc (unsigned; for local dry-runs only)
#   UPSTREAM_SUFFIX  appended to the upstream version. Defaults to "+${SERIES}"
#                    so every series gets its own orig-tarball filename slot on
#                    Launchpad — necessary because the per-series steps below
#                    (dropping plugin/kubernetes, capping go directives) make
#                    the orig content diverge across series, and Launchpad
#                    stores only one orig per <package>_<upstream-version>.
#                    Override to a fixed string (e.g. "+p1") to force a fresh
#                    slot when re-uploading after a mistake. Git clone still
#                    uses the raw UPSTREAM_TAG — only the version string moves.

set -euo pipefail

: "${UPSTREAM_TAG:?UPSTREAM_TAG is required (e.g. v1.3.16)}"
: "${SERIES:?SERIES is required (e.g. noble)}"
: "${PPA_REV:?PPA_REV is required (e.g. 1)}"
: "${DEBFULLNAME:?DEBFULLNAME is required}"
: "${DEBEMAIL:?DEBEMAIL is required}"

UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/tg123/sshpiper.git}"
OUTDIR="${OUTDIR:-$PWD/build}"
CHANGELOG_MSG="${CHANGELOG_MSG:-Automated build for ${UPSTREAM_TAG} on ${SERIES}}"

# Upstream version: strip leading 'v' if present, then append UPSTREAM_SUFFIX.
# Default suffix is "+${SERIES}" so each Ubuntu series owns its own orig
# filename slot on Launchpad — required because the per-series steps below
# make orig content diverge across series. Git clone still uses raw UPSTREAM_TAG.
UPSTREAM_SUFFIX="${UPSTREAM_SUFFIX:-+${SERIES}}"
UPSTREAM_VERSION="${UPSTREAM_TAG#v}${UPSTREAM_SUFFIX}"
DEB_VERSION="${UPSTREAM_VERSION}-0ppa${PPA_REV}~${SERIES}1"
echo "==> UPSTREAM_SUFFIX='${UPSTREAM_SUFFIX}' -> package version ${UPSTREAM_VERSION}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKDIR="$(mktemp -d -t sshpiperd-ppa.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

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

# Derive a deterministic timestamp from the upstream tag's commit so re-runs
# of the same series produce a byte-identical .orig.tar.xz. Launchpad stores
# one orig per <package>_<upstream-version> and rejects uploads that differ
# in content; each series has its own upstream-version now (see UPSTREAM_SUFFIX
# default above), so cross-series identity isn't required — but per-series
# reproducibility still is, so any re-upload after a partial failure matches.
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

# Drop plugin/kubernetes on series that lack Go 1.25 (currently anything
# < resolute). The Kubernetes client-go v0.35 set declares `go 1.25.0` in
# its own go.mod, and Go's vendor mode enforces every vendored module's
# `go` directive — not just the one we're building. No other direct dep
# of sshpiper v1.5.3 requires 1.25 (checked 2026-04-21), so dropping the
# kubernetes plugin + its direct k8s.io/* requires is sufficient.
#
# Revisit when noble-updates (or the target series) ships Go 1.25.
case "${SERIES}" in
    noble|jammy|focal)
        echo "==> ${SERIES} lacks Go 1.25 — dropping plugin/kubernetes and k8s.io/* deps"
        rm -rf plugin/kubernetes
        for pkg in $(go mod edit -json \
                     | grep -o '"Path":[[:space:]]*"k8s\.io/[^"]*"' \
                     | cut -d'"' -f4 | sort -u); do
            echo "    go mod edit -droprequire=${pkg}"
            go mod edit "-droprequire=${pkg}"
        done
        ;;
esac

echo "==> Vendoring Go dependencies (Launchpad builders have no network)"
# Vendor with upstream's go.mod intact (minus any drops above), so the
# runner's Go can auto-fetch whatever toolchain upstream declares. We
# lower the directive AFTER vendoring, below.
go mod vendor

echo "==> Stripping toolchain directive from go.mod"
# Launchpad builders have no network during build (GOPROXY=off), so a
# `toolchain` directive's auto-download would fail. Safe to strip on every
# series: the installed Go is already what we want to use.
sed -i '/^toolchain /d' go.mod

# Cap go directives to the newest Go available on each target series.
# Upstream's go.mod and some vendored deps' go.mod (recorded as
# `## explicit; go X.Y` in vendor/modules.txt) keep marching forward
# (1.25, 1.26, …); each series gets stuck on whatever Go landed in
# main+updates by release time. Go's vendor mode enforces *every*
# vendored module's directive, so both files must be capped together.
# If upstream ever uses a genuine language feature newer than the cap,
# the Launchpad build will surface it as a real compile error.
#
# Update this table when a new series is added or when one gets a Go
# point-release bump that lets us raise the cap. Leave the default arm
# empty for series newer than anything we've seen, on the assumption
# that they ship a Go new enough for upstream's current directive.
case "${SERIES}" in
    focal|jammy|noble) GO_CAP=1.24 ;;
    resolute)          GO_CAP=1.25 ;;
    *)                 GO_CAP=    ;;
esac

if [ -n "${GO_CAP}" ]; then
    echo "==> Capping go directives to ${GO_CAP} for ${SERIES}"
    sed -i -E "s/^go [0-9]+\\.[0-9]+(\\.[0-9]+)?\$/go ${GO_CAP}/" go.mod
    sed -i -E "s/^(## (.*; )?go )[0-9]+\\.[0-9]+(\\.[0-9]+)?\$/\\1${GO_CAP}/" \
        vendor/modules.txt
else
    echo "==> ${SERIES}: no cap configured — leaving go directives as upstream declares"
fi

# Upstream v1.6.1 calls *os.Root.MkdirAll (Go 1.25, added Aug 2025) at
# cmd/sshpiperd/daemon.go:476. Noble/jammy ship Go 1.24, whose stdlib
# doesn't have that method — the go-directive cap only caps language level,
# not stdlib surface. Rather than drop older series (Ryan wants all three
# LTS+STS supported), inject a small backport that walks the path with
# Mkdir + OpenRoot (both Go 1.24 stdlib when *os.Root was introduced), which
# preserves the exact symlink-containment guarantee upstream deliberately
# relies on. Shim is universal — works on Go 1.24 AND 1.25 — so applied
# unconditionally, no series-specific branching.
#
# When bumping to a new upstream tag, re-audit for new Go 1.25+ patterns:
#     grep -rnE '\.(MkdirAll|Chmod|Chown|Chtimes|Symlink|Readlink|Lchown|Chdir)\(' cmd/sshpiperd/
#     grep -rnE '(os\.CopyFS|slog\.DiscardHandler)' cmd/sshpiperd/
if [ -f cmd/sshpiperd/daemon.go ] && grep -q 'd\.recordRoot\.MkdirAll' cmd/sshpiperd/daemon.go; then
    echo "==> Injecting *os.Root.MkdirAll backport shim into cmd/sshpiperd/"
    cat >cmd/sshpiperd/os_root_backport.go <<'EOF'
// Injected by ryanlovett/sshpiperd-ppa build script.
// Backport of *os.Root.MkdirAll (added in Go 1.25). Walks path components
// with Mkdir + OpenRoot (both Go 1.24 stdlib when *os.Root was introduced),
// preserving the symlink-containment guarantee upstream relies on.
// Universal: works on Go 1.24 AND 1.25 — no build tag needed.
package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
)

func mkdirAllRoot(root *os.Root, path string, perm os.FileMode) error {
	cur := root
	for _, part := range strings.Split(filepath.ToSlash(path), "/") {
		if part == "" || part == "." {
			continue
		}
		if err := cur.Mkdir(part, perm); err != nil && !errors.Is(err, os.ErrExist) {
			if cur != root {
				_ = cur.Close()
			}
			return err
		}
		next, err := cur.OpenRoot(part)
		if err != nil {
			if cur != root {
				_ = cur.Close()
			}
			return err
		}
		if cur != root {
			_ = cur.Close()
		}
		cur = next
	}
	if cur != root {
		_ = cur.Close()
	}
	return nil
}
EOF
    sed -i 's|d\.recordRoot\.MkdirAll(subdir, 0o700)|mkdirAllRoot(d.recordRoot, subdir, 0o700)|' \
        cmd/sshpiperd/daemon.go
    # Fail fast if upstream changed the call site (different args/var name):
    # the grep guard above would still match but the sed wouldn't take, and
    # the build would only die later on Launchpad with the original
    # "MkdirAll undefined" error. Better to stop here in the runner.
    if grep -q 'recordRoot\.MkdirAll' cmd/sshpiperd/daemon.go; then
        echo "error: MkdirAll call site changed upstream — shim sed did not apply; update the shim" >&2
        exit 1
    fi
fi

# As of upstream v1.6.1, cmd/sshpiperd is its own nested Go module with a
# `replace golang.org/x/crypto => github.com/tg123/sshpiper.crypto ...` for the
# sshpiper-forked SSH library. It needs its own vendor tree, and its go.mod
# (and vendor/modules.txt) need the same toolchain-strip + go-directive cap
# treatment as the root module. Guarded so older tags (single-module layout)
# still build unchanged.
if [ -f cmd/sshpiperd/go.mod ]; then
    echo "==> cmd/sshpiperd is a nested module — vendoring it too"
    (cd cmd/sshpiperd && go mod vendor)

    echo "==> Stripping toolchain directive from cmd/sshpiperd/go.mod"
    sed -i '/^toolchain /d' cmd/sshpiperd/go.mod

    if [ -n "${GO_CAP}" ]; then
        echo "==> Capping cmd/sshpiperd go directives to ${GO_CAP}"
        sed -i -E "s/^go [0-9]+\\.[0-9]+(\\.[0-9]+)?\$/go ${GO_CAP}/" \
            cmd/sshpiperd/go.mod
        sed -i -E "s/^(## (.*; )?go )[0-9]+\\.[0-9]+(\\.[0-9]+)?\$/\\1${GO_CAP}/" \
            cmd/sshpiperd/vendor/modules.txt
    fi
fi

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
tar --sort=name --owner=0 --group=0 --numeric-owner \
    --mtime="@${SOURCE_DATE_EPOCH:-$(date +%s)}" \
    -C "${WORKDIR}" -cJf "${ORIG_TARBALL}" \
    --exclude='sshpiperd-*/debian' \
    "sshpiperd-${UPSTREAM_VERSION}"
echo "    -> ${ORIG_TARBALL}"

echo "==> Rewriting debian/changelog for ${DEB_VERSION} / ${SERIES}"
export DEBFULLNAME DEBEMAIL
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
mv -v \
    "sshpiperd_${UPSTREAM_VERSION}.orig.tar.xz" \
    "sshpiperd_${DEB_VERSION}.dsc" \
    "sshpiperd_${DEB_VERSION}.debian.tar."* \
    "sshpiperd_${DEB_VERSION}_source.changes" \
    "sshpiperd_${DEB_VERSION}_source.buildinfo" \
    "${OUTDIR}/" 2>/dev/null || true

echo "==> Done. Artifacts in ${OUTDIR}:"
ls -l "${OUTDIR}"

cat <<EOF

Next step (manual first time, automated via workflow after):
  dput ppa:ryanlovett/sshpiperd ${OUTDIR}/sshpiperd_${DEB_VERSION}_source.changes
EOF
