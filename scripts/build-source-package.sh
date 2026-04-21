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
#   OUTDIR        default: $PWD/build
#   UPSTREAM_REPO default: https://github.com/tg123/sshpiper.git
#   CHANGELOG_MSG default: "Automated build for ${UPSTREAM_TAG} on ${SERIES}"
#   NO_SIGN       if set, pass -us -uc (unsigned; for local dry-runs only)

set -euo pipefail

: "${UPSTREAM_TAG:?UPSTREAM_TAG is required (e.g. v1.3.16)}"
: "${SERIES:?SERIES is required (e.g. noble)}"
: "${PPA_REV:?PPA_REV is required (e.g. 1)}"
: "${DEBFULLNAME:?DEBFULLNAME is required}"
: "${DEBEMAIL:?DEBEMAIL is required}"

UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/tg123/sshpiper.git}"
OUTDIR="${OUTDIR:-$PWD/build}"
CHANGELOG_MSG="${CHANGELOG_MSG:-Automated build for ${UPSTREAM_TAG} on ${SERIES}}"

# Upstream version: strip leading 'v' if present.
UPSTREAM_VERSION="${UPSTREAM_TAG#v}"
DEB_VERSION="${UPSTREAM_VERSION}-0ppa${PPA_REV}~${SERIES}1"

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

echo "==> Removing upstream VCS state and .github (keep submodule contents)"
# `.git` in a submodule is a file pointing at the parent's .git/modules dir;
# removing it detaches the submodule but leaves its files in place, which is
# what we want in a source tarball.
find . -name .git -print0 | xargs -0 rm -rf
rm -f .gitmodules
rm -rf .github

echo "==> Vendoring Go dependencies (Launchpad builders have no network)"
go mod vendor

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
