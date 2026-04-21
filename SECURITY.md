# Security policy

## Reporting a vulnerability

Email **ryan@pixelated.cloud** with `[sshpiperd-ppa]` in the subject line.
I aim to acknowledge within 7 days.

Please report here if the issue is with:

- This repository's packaging (`debian/*`, `scripts/*`, the GitHub
  workflow, or the signing setup).
- A signed `.deb` published to `ppa:ryanlovett/sshpiperd` that doesn't
  match what this repository's code would produce.
- Anything that would let an attacker upload malicious sources to the
  PPA under the project's signing identity.

For vulnerabilities in upstream **`sshpiperd` itself** (daemon logic,
plugin protocol, SSH handling), please report to the upstream project
at <https://github.com/tg123/sshpiper/security>. Those reach the
actual maintainers and get fixed for all downstreams, not just this PPA.

## Verifying PPA artifacts

Source packages uploaded to this PPA are signed by a dedicated OpenPGP
identity, distinct from the maintainer's personal PGP key:

- **UID**: `Ryan Lovett (sshpiperd PPA signing) <ryan@pixelated.cloud>`
- **Master fingerprint** (certify-only, offline):
  `F0F47345BB20C959ADE80A6BEBC9CDD7891B6F4B`
- **Signing subkey** (sign-only, rotated annually):
  see the current `git log` trailer on this file or Launchpad's PPA
  page. As of 2026-04-21: `94AF6A33B9F78505F0B3658E8A48FF9288F19EBC`,
  expires 2027-04-21.

The master public key is registered to the Launchpad account
`~ryanlovett` and mirrored on `keyserver.ubuntu.com`. Launchpad itself
re-signs the archive's `Release` file with its own archive key, which
is what end-user `apt` verifies — so the PPA signing key above
authenticates uploads into Launchpad, not downloads out of it.

If you see signatures on upload-chain artifacts (`.changes`, `.dsc`)
that don't match the fingerprints above, that's a reportable issue.

## Scope reminder

This is a packaging-only repository. No upstream source lives here; it
is fetched at build time from <https://github.com/tg123/sshpiper> at
the specific release tag listed in each `debian/changelog` entry.
