# sshpiperd-ppa

Packaging-only repository that builds `sshpiperd` (upstream:
<https://github.com/tg123/sshpiper>) as a Debian source package and uploads
it to **`ppa:ryanlovett/sshpiperd`** on Launchpad.

This repo does **not** fork upstream. It tracks upstream releases, vendors
Go dependencies, overlays a `debian/` tree, and pushes a signed source
package to Launchpad's builders.

## Why a PPA instead of the snap

The official `sshpiperd` snap confines filesystem and network access in ways
that break gRPC plugins. A `.deb` from a PPA installs unconfined with
proper systemd integration, which is what we want on Ubuntu server hosts.

## Repo layout

    debian/                 Source-package metadata + maintainer scripts
      control               Source + binary package definitions
      rules                 Build recipe (dh-golang, vendored Go deps)
      changelog             Placeholder — rewritten by build script per release
      copyright             MIT (upstream) + MIT (packaging)
      source/format         3.0 (quilt)
      sshpiperd.service     Hardened systemd unit
      sshpiperd.default     /etc/default/sshpiperd env file
      sshpiperd.postinst    Creates system user + state/config dirs
      sshpiperd.install     Ships default file into /etc/default/
    scripts/
      build-source-package.sh   Clones upstream @tag, vendors, overlays, signs
    .github/workflows/
      ppa-release.yml       Cron poll → build → dput, gated on Environment

No `debian/compat` file — `debhelper-compat (= 13)` in `debian/control` is
the modern equivalent and the two are mutually exclusive.

## Per-series plugin coverage

sshpiper ships 10 plugins upstream: docker, failtoban, fixed, kubernetes,
lua, metrics, simplemath, username-router, workingdir, yaml. Whether each
plugin builds depends on the Go version available in the target Ubuntu
series.

| Series | Plugins shipped |
|---|---|
| resolute (26.04 LTS) | All 10 |
| noble (24.04 LTS)    | All **except `kubernetes`** |

The kubernetes plugin pulls in `k8s.io/{api,apimachinery,client-go,code-generator}` v0.35, which themselves declare `go 1.25.0` in their go.mod files. Go's vendor mode enforces every vendored module's `go` directive, so even building `sshpiperd` itself fails on a builder that has Go < 1.25. Noble currently tops out at Go 1.24 (in `noble-updates`).

`scripts/build-source-package.sh` drops `plugin/kubernetes/` and the `k8s.io/*` direct requires on series that predate Go 1.25. When Ubuntu SRUs Go 1.25 into `noble-updates`, remove `noble` from the `case` block in that script and re-dispatch to get kubernetes onto noble.

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
3. On approval, it imports the signing subkey, builds the source package,
   signs the `.changes`, `dput`s to Launchpad, and pushes the marker tag.
4. Launchpad emails build results to the address on your Launchpad account.

You can also trigger manually: **Actions → ppa-release → Run workflow**,
optionally overriding `upstream_tag` or `series`.

## Manual upload fallback

If Actions is down, Launchpad changes its incoming path, or you just want
to push a point release out of band — the same two commands from step 8
above are the whole fallback procedure. The automation is a convenience
layer over `build-source-package.sh + dput`; nothing lives only in the
workflow.

---

## Annual rotation

Rotate the signing subkey every year before its expiry. Overlap old + new
on Launchpad so in-flight builds keep verifying:

1. **Generate a new subkey** on the offline machine (master must be present):
   ```bash
   gpg --quick-add-key "$MASTER_FPR" ed25519 sign 1y
   NEW_SUB_FPR="$(gpg --list-secret-keys --with-colons \
                  | awk -F: '$1=="fpr"{print $10}' | tail -n1)"
   ```
2. **Publish the updated master** to the keyserver — Launchpad refreshes
   from the keyserver, so the new subkey becomes acceptable automatically:
   ```bash
   gpg --send-keys --keyserver keyserver.ubuntu.com "$MASTER_FPR"
   ```
3. **Verify acceptance** by signing a test file with the new subkey and
   uploading a no-op `.changes` or just watching Launchpad's key page
   refresh (can take an hour).
4. **Export the new subkey** (`--export-secret-subkeys "$NEW_SUB_FPR!"`)
   and rotate the three GitHub secrets (`GPG_PRIVATE_KEY`, `GPG_PASSPHRASE`,
   `GPG_KEY_ID`).
5. **Revoke the old subkey** once you've confirmed a real release built
   with the new one:
   ```bash
   gpg --edit-key "$MASTER_FPR"
   # key <N>   (select old subkey)
   # revkey    (reason: "Key is no longer used")
   # save
   gpg --send-keys --keyserver keyserver.ubuntu.com "$MASTER_FPR"
   ```

Calendar reminder: set for **11 months** after generation, not 12 — gives
a month of slack if rotation day is busy.

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
