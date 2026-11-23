# sshpiperd-ppa

Packaging-only repository that builds `sshpiperd` (upstream:
<https://github.com/tg123/sshpiper>) as a Debian source package and uploads
it to **`ppa:ryanlovett/sshpiperd`** on Launchpad.

This repo does **not** fork upstream. It tracks upstream releases, vendors
Go dependencies, bundles the Go toolchain upstream requires, overlays a
`debian/` tree, and pushes a signed source package to Launchpad's builders.

## Why a PPA instead of the snap

The official `sshpiperd` snap confines filesystem and network access in ways
that break gRPC plugins. A `.deb` from a PPA installs unconfined with
proper systemd integration, which is what we want on Ubuntu server hosts.

## Repo layout

    debian/                 Source-package metadata + maintainer scripts
      control               Source + binary package definitions
      rules                 Build recipe (bundled Go toolchain, vendored deps)
      changelog             Placeholder — rewritten by build script per release
      copyright             MIT (upstream) + MIT (packaging)
      source/format         3.0 (quilt)
      sshpiperd.service     Hardened systemd unit
      sshpiperd.default     /etc/default/sshpiperd env file
      sshpiperd.postinst    Creates system user + state/config dirs
      sshpiperd.install     Ships default file into /etc/default/
    scripts/
      build-source-package.sh   Clones upstream @tag, vendors, bundles Go,
                                overlays, signs
      test-binary-build.sh      Builds the .debs offline in a clean series
                                container — run before every upload
    .github/workflows/
      ppa-release.yml       Cron poll → build → offline build test → dput,
                            gated on Environment
      build-test.yml        Same build + offline test, unsigned, no upload —
                            runs on PRs that touch debian/ or scripts/

No `debian/compat` file — `debhelper-compat (= 13)` in `debian/control` is
the modern equivalent and the two are mutually exclusive.

## How the build stays independent of Ubuntu's Go

Upstream sshpiper tracks the newest Go release — its `go.mod` moves to each
new Go version and it uses new standard-library APIs as they appear. Every
Ubuntu series is frozen on an older Go, and Launchpad builders have no
network access to fetch a newer one. Building with the series' own Go
therefore broke on nearly every upstream release, each time in a new way:

| Upstream | What broke on Launchpad |
|---|---|
| v1.5.3 | `k8s.io/*` deps declared `go 1.25`; noble/jammy had 1.24 |
| v1.5.4 | a new vendored dep declared `go 1.25` |
| v1.5.4 | upstream `go.mod` declared `go 1.26`; resolute had 1.25 |
| v1.6.1 | `(*os.Root).MkdirAll` (Go 1.25 stdlib) missing on Go 1.24 |
| v1.6.2 | `uuid` package (Go 1.27 stdlib) missing on Go 1.25 — on every series |

Each was patched around (drop the plugin, rewrite the `go` directives,
inject a backport), and each patch only held until the next release.

**The source package now carries the Go toolchain itself.**
`scripts/build-source-package.sh` reads the Go version upstream's `go.mod`
files require, picks the latest patch release of that line, and bundles the
official toolchain for each architecture in `debian/control` under
`_gotoolchain/` in the orig tarball. `debian/rules` unpacks the one for the
build architecture and compiles with it. Consequences:

- Upstream's source is packaged **unmodified** — no dropped plugins, no
  edited `go.mod`, no injected shims.
- Every series ships **every upstream plugin** (including `kubernetes`,
  previously missing on jammy and noble).
- There is no Go build-dependency at all (`Build-Depends` is just
  `debhelper-compat` and `unzip`), so a series' Go version, or a new series
  with different `golang-*` package names, cannot break the build.
- When upstream moves to a newer Go, the next build simply bundles it.

Trust: the toolchains are the Go project's own release artifacts, fetched
as Go toolchain modules (`golang.org/toolchain@v0.0.1-goX.Y.Z.linux-ARCH`).
The `go` command verifies each against the Go checksum database
(`sum.golang.org`, a public transparency log) before the script accepts it,
and the script pins `GOSUMDB`/`GOPROXY` and clears the variables that could
disable that check. The zips go into the source package byte-for-byte, with
their `h1:` hashes recorded in `_gotoolchain/MANIFEST`, and the whole orig
tarball is covered by the signed `.dsc`.

Cost: each source package is about 220 MB (three ~75 MB toolchains). The
PPA quota is 8 GiB, and Launchpad removes superseded versions.

To build for another architecture, add it to both `Architecture:` fields in
`debian/control` (and to `go_arch_for()` in the build script if it is not
already listed there), and enable it in the PPA's settings on Launchpad.

### Pre-upload build test

Launchpad never lets a version be uploaded twice, so a source package that
fails on its builders burns that version. `scripts/test-binary-build.sh`
catches that before upload: it unpacks the exact `.dsc` that will be
uploaded inside a clean `ubuntu:<series>` container holding only the
declared build-dependencies, and builds it with **no network**, as an
unprivileged user with a nonexistent `$HOME` — the conditions on a
Launchpad builder. It then checks that every plugin was packaged and the
binary starts, and cross-compiles for the other architectures. The
workflow runs it between building the source package and `dput`; if it
fails, nothing is uploaded and no version is consumed.

---

## One-time bootstrap

Do these in order. Most take minutes; the GPG step wants care.

### 1. Launchpad account

1. Create/log in at <https://launchpad.net/>.
2. Create the PPA at <https://launchpad.net/~ryanlovett/+activate-ppa>,
   name it `sshpiperd`, enable the Ubuntu series you care about (start with
   `noble`).
3. Sign the Ubuntu Code of Conduct on your Launchpad profile — source
   uploads are rejected until this is done.

### 2. Generate the dedicated GPG identity

We use a **dedicated identity for this PPA**, not your personal GPG key.
Compromise of the signing key should not let an attacker impersonate you
for git commits, email, or other projects.

Keys produced here:

| Key      | Capability       | Where it lives              | Expiry |
| -------- | ---------------- | --------------------------- | ------ |
| Master   | Certify only [C] | **Offline** (hardware/USB)  | None   |
| Subkey 1 | Sign only    [S] | GitHub Environment secret   | 1 year |

**Identity**: `Ryan Lovett (sshpiperd PPA signing) <ryan@pixelated.cloud>`
— the comment field distinguishes it from your personal key in listings.

Generate on an offline or airgapped machine if practical. On a regular
workstation, at minimum do it in a scratch `GNUPGHOME`:

```bash
export GNUPGHOME="$HOME/.gnupg-sshpiperd-ppa"
mkdir -p "$GNUPGHOME" && chmod 700 "$GNUPGHOME"

# Master key: certify-only, no expiry.
gpg --quick-generate-key \
    "Ryan Lovett (sshpiperd PPA signing) <ryan@pixelated.cloud>" \
    ed25519 cert never

# Note the master fingerprint:
MASTER_FPR="$(gpg --list-secret-keys --with-colons \
              | awk -F: '$1=="fpr"{print $10; exit}')"
echo "Master: $MASTER_FPR"

# Signing subkey: 1 year.
gpg --quick-add-key "$MASTER_FPR" ed25519 sign 1y

# Get the subkey fingerprint (the second fpr line).
SUB_FPR="$(gpg --list-secret-keys --with-colons \
           | awk -F: '$1=="fpr"{print $10}' | sed -n '2p')"
echo "Subkey: $SUB_FPR"
```

### 3. Move the master key offline

```bash
# Export master (secret + public) to an encrypted file.
gpg --armor --export-secret-keys "$MASTER_FPR" \
    > sshpiperd-ppa-master.secret.asc
gpg --armor --export "$MASTER_FPR" \
    > sshpiperd-ppa-master.public.asc

# Encrypt and move to offline storage (hardware token, encrypted USB, etc.).
# Then delete the master from this machine, keeping only the subkey's
# secret material — the subkey can sign without the master present.
gpg --delete-secret-keys "$MASTER_FPR"       # choose "Delete master key only"
gpg --list-secret-keys                        # verify: master shows "sec#"
```

The `sec#` marker means the secret master is absent (stubbed); the signing
subkey's `ssb` secret remains. You can still sign `.changes` files.

### 4. Publish the public half to Launchpad

```bash
gpg --send-keys --keyserver keyserver.ubuntu.com "$MASTER_FPR"
```

Then on <https://launchpad.net/~ryanlovett/+editpgpkeys> paste the master
fingerprint and confirm the encrypted email Launchpad sends. Launchpad
accepts signatures from any subkey of a registered master.

### 5. Export the signing subkey for GitHub

GitHub gets **only the subkey secret**, not the master:

```bash
gpg --armor --export-secret-subkeys "$SUB_FPR!" \
    > sshpiperd-ppa-subkey.secret.asc    # note the trailing '!'
```

The `!` suffix tells gpg "only this specific subkey" — without it, all
subkeys get exported. Verify the export does not contain the master secret:

```bash
gpg --list-packets < sshpiperd-ppa-subkey.secret.asc \
    | grep -E 'secret key packet|secret sub key packet'
# Expect: one "secret key packet" with a stub, one "secret sub key packet".
```

### 6. Create the GitHub Environment

1. In this repo's settings: **Settings → Environments → New environment**.
2. Name: `ppa-release` (must match `environment:` in the workflow).
3. **Required reviewers**: add yourself. Every release run pauses for
   manual approval before secrets expand.
4. **Environment secrets** (not repo-level secrets):
   - `GPG_PRIVATE_KEY` — contents of `sshpiperd-ppa-subkey.secret.asc`.
   - `GPG_PASSPHRASE` — the subkey passphrase.
   - `GPG_KEY_ID` — the subkey fingerprint (40 hex chars, no spaces).
5. Delete the `.asc` file from disk once the secret is in GitHub.

### 7. Resolve SHA pins in the workflow

`.github/workflows/ppa-release.yml` currently contains placeholder strings
like `PIN_SHA_checkout_v4`. Replace each with a real commit SHA:

```bash
# Pick a version from https://github.com/actions/checkout/releases
gh api repos/actions/checkout/git/refs/tags/v4.2.2 --jq .object.sha
```

Paste the 40-char SHA into the workflow, leaving the `# v4.2.2` comment so
the next reader knows which version the SHA corresponds to. Never pin to
`@v4` or `@main` — tags are mutable, SHAs aren't.

### 8. First upload (do this manually)

Before trusting automation, run the pipeline by hand:

```bash
export GNUPGHOME="$HOME/.gnupg-sshpiperd-ppa"
export UPSTREAM_TAG=v1.3.16        # pick the current upstream release
export SERIES=noble
export PPA_REV=1
export DEBFULLNAME="Ryan Lovett"
export DEBEMAIL="ryan@pixelated.cloud"
export GPG_KEY_ID="$SUB_FPR"

./scripts/build-source-package.sh
./scripts/test-binary-build.sh     # offline build test; needs Docker
dput ppa:ryanlovett/sshpiperd build/sshpiperd_*_source.changes
```

Watch for the Launchpad acceptance email, then for the build result emails
per series. If the build succeeds and the `.deb` installs cleanly on a
test VM, tag this commit in the repo as `built/noble/<UPSTREAM_TAG>` so
the automation knows not to rebuild it:

```bash
git tag -a "built/noble/${UPSTREAM_TAG}" -m "First manual upload"
git push origin "built/noble/${UPSTREAM_TAG}"
```

---

## Normal operation

Once bootstrapped, releases run themselves:

1. Daily cron in `.github/workflows/ppa-release.yml` checks
   `api.github.com/repos/tg123/sshpiper/releases/latest`.
2. If the latest tag has no matching `built/<series>/<tag>` marker tag in
   this repo, the `build-and-upload` job queues — and **pauses for your
   approval** because of the `ppa-release` Environment.
3. On approval, it imports the signing subkey, builds and signs the source
   package, test-builds the binaries offline in a clean container of the
   target series, and only if that passes `dput`s to Launchpad and pushes
   the marker tag.
4. Launchpad emails build results to the address on your Launchpad account.

You can also trigger manually: **Actions → ppa-release → Run workflow**,
optionally overriding `upstream_tag` or `series`.

### Rebuilding a release

If an upload was accepted but then failed to build (or was rejected), that
version is spent — Launchpad never accepts the same version twice — and the
marker tag stops the cron from retrying. Re-run with a rebuild number:

```bash
gh workflow run ppa-release.yml \
    --repo ryanlovett-au/sshpiperd-ppa \
    --ref main \
    --field upstream_tag=v1.6.2 \
    --field rebuild=2
```

That uploads `1.6.2+noble2-0ppa1~noble1` (and likewise for the other
series), which sorts above the first attempt's `1.6.2+noble-0ppa1~noble1`.
Setting `rebuild` bypasses the marker check for every requested series;
narrow the `series` field to rebuild only some. Use the next unused number
each time (3, 4, …).

The series name is always part of the upstream version on purpose:
Launchpad keeps one orig tarball per `<package>_<upstream-version>` for the
whole PPA and rejects a second upload whose bytes differ, so each series
needs its own slot.

## Manual upload fallback

If Actions is down, Launchpad changes its incoming path, or you just want
to push a point release out of band — the same two commands from step 8
above are the whole fallback procedure. The automation is a convenience
layer over `build-source-package.sh + dput`; nothing lives only in the
workflow.

---

## Annual rotation

Rotate the signing subkey every year before its expiry. Overlap old + new
on Launchpad so in-flight builds keep verifying. These steps assume
day-to-day state (master secret offline, only subkey stub in
`$GNUPGHOME`) — we temporarily restore the master, rotate, then put it
back offline.

### 0. Prep

Paste the whole block:

```bash
# --- Current key fingerprints. Update these after each rotation. ---
export MASTER_FPR="F0F47345BB20C959ADE80A6BEBC9CDD7891B6F4B"
export OLD_SUB_FPR="94AF6A33B9F78505F0B3658E8A48FF9288F19EBC"
# ------------------------------------------------------------------

export GNUPGHOME="$HOME/.gnupg-sshpiperd-ppa"
export GPG_TTY="$(tty)"    # avoids "Inappropriate ioctl for device" from pinentry
```

Retrieve `master.secret.asc` and `master.public.asc` from your offline
storage and copy them into `$GNUPGHOME` (or a scratch dir; the commands
below assume `$GNUPGHOME`). Then import the master secret:

```bash
gpg --import "$GNUPGHOME/master.secret.asc"
gpg -K --with-subkey-fingerprints   # should now show `sec` (not `sec#`)
```

### 1. Generate a new signing subkey (1-year expiry)

```bash
gpg --quick-add-key "$MASTER_FPR" ed25519 sign 1y
NEW_SUB_FPR="$(gpg --list-secret-keys --with-colons "$MASTER_FPR" \
               | awk -F: '$1=="fpr"{print $10}' | tail -n1)"
echo "New subkey: $NEW_SUB_FPR"
```

gpg reuses the master's passphrase for the new subkey by default, so
you typically don't need to pick a new passphrase (and therefore don't
need to update `GPG_PASSPHRASE` in the GitHub Environment).

### 2. Publish the updated master to the keyserver

Note the `hkps://` prefix — the default HKP port (11371) is blocked on
many networks; HKP-over-TLS on 443 almost always gets through.
`$GNUPGHOME/dirmngr.conf` already has `disable-ipv6` from initial
bootstrap, which matters if your network has no working v6 route.

```bash
gpg --send-keys --keyserver hkps://keyserver.ubuntu.com "$MASTER_FPR"
```

Launchpad refreshes from the keyserver pool on its own cycle (usually
within minutes to an hour); the new subkey becomes acceptable
automatically — no Launchpad UI action needed.

### 3. Export the new subkey

```bash
gpg --armor --export-secret-subkeys "${NEW_SUB_FPR}!" \
    > "$GNUPGHOME/subkey.secret.asc"
# Verify the master entry is a stub, not real secret material:
gpg --list-packets "$GNUPGHOME/subkey.secret.asc" \
    | grep -E 'gnu-dummy|secret (sub )?key packet' | head
# Expect one "gnu-dummy" (the master stub) and one "secret sub key packet".
```

### 4. Rotate the GitHub Environment secrets

Only `GPG_KEY_ID` and `GPG_PRIVATE_KEY` change. `GPG_PASSPHRASE` stays
unless you deliberately set a new one in step 1.

```bash
printf '%s' "$NEW_SUB_FPR" \
  | gh secret set GPG_KEY_ID --env ppa-release --repo ryanlovett-au/sshpiperd-ppa

gh secret set GPG_PRIVATE_KEY --env ppa-release --repo ryanlovett-au/sshpiperd-ppa \
  < "$GNUPGHOME/subkey.secret.asc"
```

### 5. Verify end-to-end

Trigger a manual release against the current upstream tag to prove the
new key signs successfully and Launchpad accepts it. Give it a rebuild
number (the next one not yet used for this tag — see "Rebuilding a
release") so you get a fresh version that doesn't collide with an
already-published source for the same upstream version:

```bash
# Get the current upstream tag to target (or substitute a known one).
TAG=$(gh api /repos/tg123/sshpiper/releases/latest --jq .tag_name)

gh workflow run ppa-release.yml \
    --repo ryanlovett-au/sshpiperd-ppa \
    --ref main \
    --field upstream_tag="$TAG" \
    --field rebuild=2 \
    --field series=noble,resolute
```

The existing `built/<series>/$TAG` marker tags can stay: a rebuild number
bypasses the marker check.

A clean run — Launchpad accepts both uploads and builds succeed — means
the rotation is live.

### 6. Revoke the old subkey

Only after step 5 confirms the new key works:

```bash
gpg --edit-key "$MASTER_FPR"
# At the prompt:
#   key <N>    (select the old subkey — numbered from 1 in the listing)
#   revkey     (reason: "Key is no longer used")
#   save
gpg --send-keys --keyserver hkps://keyserver.ubuntu.com "$MASTER_FPR"
```

### 7. Re-offline the master

Restore day-to-day state: master secret removed locally, only the subkey
stub + new subkey secret in `$GNUPGHOME`.

```bash
# Re-export the new subkey fresh (so the stub reflects the revoked-old +
# live-new state post step 6).
gpg --armor --export-secret-subkeys "${NEW_SUB_FPR}!" \
    > "$GNUPGHOME/subkey.secret.asc"

# Wipe all secret material for the identity, then re-import only the
# subkey export. The public keyring is untouched.
gpg --delete-secret-keys "$MASTER_FPR"
gpg --import "$GNUPGHOME/subkey.secret.asc"
gpg -K --with-subkey-fingerprints   # master should show `sec#` again

# Scrub the restored master secret from disk. (Offline backup in your
# password manager / USB / safe is the canonical copy.)
rm -P "$GNUPGHOME/master.secret.asc"
rm -P "$GNUPGHOME/subkey.secret.asc"
```

### 8. Update `keys_sshpiperd_ppa.md`

Record the new subkey fingerprint + expiry date in the memory file so
next-year-you and any future Claude session picks up the new value.

### Calendar reminder

Set for **11 months** after each generation, not 12 — gives you a month
of slack if rotation day is busy.

## Incident response: suspected key compromise

If the GitHub subkey secret may have leaked (forked repo, logs, exfil):

1. **Revoke the subkey immediately** from the offline master (step 5 above,
   reason: "Key is compromised") and push to the keyserver.
2. **Rotate the GitHub secrets** to a fresh subkey per the rotation steps.
3. **Audit the PPA** for uploads that shouldn't be there. Launchpad keeps
   a per-upload log on the PPA page; any entry signed by the compromised
   key in the compromise window is suspect.
4. **If the master key is compromised** (offline storage lost/seized), the
   only recourse is: generate a new identity, upload its public half to
   Launchpad, delete the old identity from your Launchpad profile, and
   start a fresh rotation cycle. The PPA URL stays the same; consumers
   re-trust the new key by running `sudo add-apt-repository` again.

## Notifications to watch

Launchpad emails everything to the address on your Launchpad account.
Set up a filter to route `@bugs.launchpad.net` and
`noreply@launchpad.net` into a monitored folder — build failures are
easy to miss otherwise. Key-related mail (expiry warnings, new subkey
uploads) goes to the same address.
