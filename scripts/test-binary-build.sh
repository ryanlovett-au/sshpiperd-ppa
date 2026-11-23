#!/usr/bin/env bash
# Build the binary packages from a source package the way Launchpad will,
# BEFORE it is uploaded.
#
# Launchpad never lets a version be re-uploaded, so a source package that
# fails on its builders burns that version for good and the fix has to go
# out under a new one. This script catches those failures on the CI runner
# instead, where a retry is free. It mirrors the builder's conditions:
#
#   * a clean ubuntu:<series> container holding only build-essential and
#     the package's declared Build-Depends — so a build-dependency that
#     does not exist on the series fails here;
#   * no network during the build (--network none);
#   * an unprivileged user whose HOME does not exist (sbuild uses
#     HOME=/sbuild-nonexistent);
#   * the source unpacked from the exact .dsc / orig tarball that will be
#     uploaded (mounted read-only — nothing in the container can alter it).
#
# After the native build it cross-compiles for the other architectures
# listed in debian/control, to catch code that only breaks there (e.g.
# integer constants overflowing on 32-bit ARM), and checks their bundled
# toolchain zips are intact.
#
# Required env:
#   SERIES       Ubuntu release codename (e.g. noble)
#
# Optional env:
#   OUTDIR       directory holding the source package (default: $PWD/build)
#   PLATFORM     docker --platform value (default: the host's own)
#   CROSS_CHECK  set to 0 to skip the cross-compile check
#   KEEP_IMAGE   set to 1 to keep the build-dependency image afterwards

set -euo pipefail

: "${SERIES:?SERIES is required (e.g. noble)}"
OUTDIR="${OUTDIR:-$PWD/build}"
CROSS_CHECK="${CROSS_CHECK:-1}"

shopt -s nullglob
dscs=( "${OUTDIR}"/sshpiperd_*.dsc )
shopt -u nullglob
if [ ${#dscs[@]} -ne 1 ]; then
    echo "error: expected exactly one sshpiperd_*.dsc in ${OUTDIR}, found ${#dscs[@]}" >&2
    exit 1
fi
DSC="${dscs[0]}"
OUTDIR="$(cd "${OUTDIR}" && pwd)"

PLATFORM_ARGS=()
if [ -n "${PLATFORM:-}" ]; then
    PLATFORM_ARGS=(--platform "${PLATFORM}")
fi

IMAGE="sshpiperd-ppa-buildtest:${SERIES}-$$"
CONTEXT="$(mktemp -d -t sshpiperd-buildtest.XXXXXX)"
cleanup() {
    rm -rf "${CONTEXT}"
    if [ -z "${KEEP_IMAGE:-}" ]; then
        docker image rm -f "${IMAGE}" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

# --- Stage 1 (network): clean series image + the declared Build-Depends ----
# Only the .dsc goes into the build context; apt reads Build-Depends from it.
cp "${DSC}" "${CONTEXT}/"
cat > "${CONTEXT}/Dockerfile" <<'DOCKERFILE'
ARG SERIES
FROM ubuntu:${SERIES}
ENV DEBIAN_FRONTEND=noninteractive
COPY *.dsc /tmp/dsc/
# build-essential + fakeroot are what every Launchpad build chroot starts
# with; everything else must come from the package's own Build-Depends.
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential fakeroot \
 && apt-get build-dep -y --no-install-recommends /tmp/dsc/*.dsc \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --no-create-home --home-dir /sbuild-nonexistent --shell /bin/bash buildd \
 && install -d -o buildd -g buildd /build
DOCKERFILE

echo "==> [${SERIES}] Preparing build environment (ubuntu:${SERIES} + Build-Depends)"
built=
for attempt in 1 2 3; do
    if docker build "${PLATFORM_ARGS[@]}" --pull --build-arg "SERIES=${SERIES}" \
           -t "${IMAGE}" "${CONTEXT}"; then
        built=1
        break
    fi
    echo "    docker build failed (attempt ${attempt}/3) — retrying in 20s" >&2
    sleep 20
done
if [ -z "${built}" ]; then
    echo "error: could not prepare the ubuntu:${SERIES} build environment" >&2
    exit 1
fi

# --- Stage 2 (no network): build exactly as a Launchpad builder would ------
echo "==> [${SERIES}] Building binary packages offline from $(basename "${DSC}")"
docker run --rm "${PLATFORM_ARGS[@]}" \
    --network none \
    --user buildd \
    --env HOME=/sbuild-nonexistent \
    --env "CROSS_CHECK=${CROSS_CHECK}" \
    --volume "${OUTDIR}:/in:ro" \
    --workdir /build \
    "${IMAGE}" bash -euo pipefail -c '
        dpkg-source -x /in/sshpiperd_*.dsc src
        cd src
        dpkg-buildpackage -b -us -uc

        echo "==> Checking the built packages"
        native="$(dpkg --print-architecture)"
        mkdir /build/unpacked
        ls -lh /build/*.deb
        for pkg in sshpiperd sshpiperd-plugins; do
            deb="$(ls /build/"${pkg}"_*_"${native}".deb)"
            dpkg-deb --info "${deb}" | sed -n "/^ Package:/p;/^ Version:/p;/^ Architecture:/p;/^ Depends:/p"
            dpkg-deb -x "${deb}" /build/unpacked
        done
        test -x /build/unpacked/usr/sbin/sshpiperd
        # Every upstream plugin with a main.go must have been shipped.
        for main in plugin/*/main.go; do
            p="$(basename "$(dirname "${main}")")"
            if [ ! -x "/build/unpacked/usr/lib/sshpiperd/plugins/${p}" ]; then
                echo "error: plugin ${p} is missing from sshpiperd-plugins" >&2
                exit 1
            fi
        done
        echo "    plugins: $(ls /build/unpacked/usr/lib/sshpiperd/plugins | tr "\n" " ")"
        # The binary must at least start on this series (dynamic loader,
        # glibc version). What --help prints or returns is upstream
        # business and not checked; a status of 126+ means it could not be
        # executed at all or was killed by a signal, which is ours.
        status=0
        out="$(/build/unpacked/usr/sbin/sshpiperd --help 2>&1)" || status=$?
        if [ "${status}" -ge 126 ]; then
            echo "error: sshpiperd does not run on this series (exit status ${status}):" >&2
            printf "%s\n" "${out}" | head -n 20 >&2
            exit 1
        fi
        echo "    sshpiperd runs (--help exit status ${status})"

        if [ "${CROSS_CHECK}" = 0 ]; then
            echo "==> Cross-compile check skipped (CROSS_CHECK=0)"
            exit 0
        fi

        # Same Go environment debian/rules uses, minus cgo (no cross C
        # compiler here; this is a compile check of the Go code only).
        go="$PWD/_build/goroot/bin/go"
        export GOFLAGS="-mod=vendor -trimpath -tags=full" GOPROXY=off GOTOOLCHAIN=local
        export GOCACHE="$PWD/_build/.gocache" GOTMPDIR="$PWD/_build/.gotmp" GOMODCACHE="$PWD/_build/.gomodcache"
        export CGO_ENABLED=0 GOOS=linux
        while read -r deb_arch go_arch _; do
            [ "${deb_arch}" = "${native}" ] && continue
            echo "==> Checking ${deb_arch}: toolchain zip + cross-compile (GOARCH=${go_arch})"
            unzip -tq "_gotoolchain/${deb_arch}.zip" >/dev/null
            # (no `| grep -q`: it closes the pipe early and pipefail turns
            # the resulting SIGPIPE into a failure)
            unzip -Z1 "_gotoolchain/${deb_arch}.zip" "*/bin/go" >/dev/null
            (
                export GOARCH="${go_arch}"
                [ "${deb_arch}" = armhf ] && export GOARM=7
                (cd cmd/sshpiperd && "${go}" build -o /dev/null .)
                for main in plugin/*/main.go; do
                    (cd "$(dirname "${main}")" && "${go}" build -o /dev/null .)
                done
            )
        done < _gotoolchain/MANIFEST
    '

echo "==> [${SERIES}] Binary build test passed"
