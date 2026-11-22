# Roadmap

Planned, not implemented. Each item lists the constraint that shapes it.

## `--enable-auto-update`

A systemd user timer plus service that **downloads, verifies and notifies
only**.

- The timer runs the full trust chain (fingerprint, `InRelease` signature,
  `Valid-Until`, `Date` floor, `Packages` and `.deb` checksums) and stages the
  verified version under `versions/<ver>` without touching `current`.
- It then sends a desktop notification (`notify-send`, or the journal when no
  session bus is present) naming the staged version and the result of the
  `--inspect` metadata diff.
- Switching `current` to the staged version stays a manual command run by the
  user. A timer never changes what is launched.
- `--disable-auto-update` removes the units.

## CI distribution matrix

Two kinds of job, because a container cannot test what matters most.

- **Containers** (Ubuntu 22.04 / 24.04, Debian 12 / 13, Fedora, Arch,
  openSUSE Tumbleweed, Alpine): host checks, library resolution and the
  `.deb` extraction chain only. Electron inside a container runs as root and
  needs `--no-sandbox` regardless, so a container says nothing about the
  sandbox.
- **Sandbox**: a direct run on a `ubuntu-24.04` runner, no container, as the
  runner's unprivileged user. This is the only job that exercises the AppArmor
  userns restriction and the profile from `--print-apparmor-profile`
  (load, launch headless, confirm the renderer sandbox started, unload).

## Signed release artifacts

Every release carries a signature that does not come from the same place as
the file it covers:

- **Signed tag** for every version (`git tag -s`), verifiable with
  `git tag -v` against a published signing key. Unsigned tags are never
  pushed.
- **Signed `SHA256SUMS`** attached to every GitHub Release: the checksum of
  `claude-desktop-userland.sh` (and of any future asset) plus a detached
  signature over that file, with a documented verification command
  (`ssh-keygen -Y verify` against an `allowed_signers` file, or `gpg --verify`,
  depending on the key type chosen).
- The README install snippet then gains a step that verifies `SHA256SUMS`
  before `sha256sum -c`. Today the README hash and the script come from the
  same repository, which protects against a corrupted download but is not an
  independent signature.

## README compatibility table

Generated from the CI results, with wording that matches what was actually
tested:

- **"Libraries checked"** when only the container job ran for that
  distribution.
- **"Works"** only when the application was actually launched and the sandbox
  confirmed on that distribution.

## Small follow-ups

- **Update the script header comment.** The block at the top of
  `claude-desktop-userland.sh` still describes an rpm-ostree / bootc-only
  installer and lists only the original options. It should match the current
  scope (any glibc >= 2.34 distribution, host checks) and point to `--help`
  for the option list instead of duplicating it.
