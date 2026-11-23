# Changelog

## Unreleased

- `--rollback`: switch `current` back to the other kept version, offline.
  The Date floor and the downgrade check are not involved; a version that
  is not `N(.N)*` or lacks the binary the launcher runs is refused, changing
  nothing. The host check runs afterwards, as after an install, including a
  `host-check-skipped` record of the version switched to. Nothing is pinned:
  the next plain run installs the newest repository version again
- The `host-check-skipped` record is written only after the payload is
  installed, so a run that fails later leaves no record behind
- CI: a `distros` workflow. A real install against the live repository feeds
  one container per distribution (Ubuntu 22.04 / 24.04, Debian 12 / 13,
  Fedora 43, Arch, openSUSE Tumbleweed), each running the unit tests and a
  library round trip: the packages the installer suggests are installed and
  every library must then resolve. AlmaLinux 8 and Alpine must be refused
  before any download. A direct Ubuntu 24.04 job checks the AppArmor userns
  restriction: no sandboxed renderer without the generated profile, a
  renderer in its own user namespace with it
- Host-check failures carry a fixed marker, `[fail:<id>]` (for example
  `[fail:apparmor-userns]`, `[fail:missing-libs]`), listed in the README.
  Scripts and CI match the marker instead of the wording; tests keep the
  README list, the call sites and the CI verdict in step
- Releases carry `SHA256SUMS` and a detached SSH signature
  `SHA256SUMS.sig`, made with the key that signs the tags and checked against
  the key published on the maintainer's GitHub account.
  `tools/release-sums.sh` creates (refusing an unsigned tag or a key other
  than the tag's) and verifies them; RELEASING.md and the README document
  both sides
- CI: every action is pinned to a commit SHA, and both workflows run with a
  read-only token (`contents: read`)

## 1.1.0 (2026-11-22)

- `--inspect`: download and verify the latest package, print its
  `Depends`/`Recommends` and maintainer scripts (never executed), and diff them
  against the last version seen. A normal install/upgrade runs the same report
  automatically and keeps it under `~/.local/share/claude-desktop/package-meta/`
- Package metadata follows the same two-version retention as the app payload
- `--doctor`: offline host check. glibc floor (2.34, refuses musl), user
  namespaces including Debian's `unprivileged_userns_clone` and the Ubuntu
  24.04+ AppArmor restriction, the payload's shared libraries (see below),
  Secret Service and
  xdg-desktop-portal on the session bus. Runs automatically after install
- `--print-apparmor-profile`: userns profile for the install path, with load
  and removal instructions and the trade-off spelled out
- glibc check before the download; `--skip-host-check` (install and
  `--force` only) skips the version floor only, never the musl refusal
- `CLAUDE_SKIP_HOST_CHECK` has no effect; when set, a warning points to
  `--skip-host-check`
- An install made with `--skip-host-check` is recorded in
  `package-meta/<version>/host-check-skipped`; `--doctor` and the
  post-install check report it as a glibc failure until that version is
  reinstalled without the option
- Launcher: warns about the AppArmor restriction, honours
  `CLAUDE_PASSWORD_STORE`
- Cowork report no longer claims `/dev/kvm` is sufficient
- `--uninstall` points at the AppArmor profile when one is installed
- The repository version must match `^[0-9]+(\.[0-9]+)*$` before it is used
  in any path or comparison; anything else stops the install
- AppArmor: the restriction sysctl is optional (absent = unrestricted), the
  profile output carries an explicit writable-path warning, and every message
  lists the profile first and `CLAUDE_NO_SANDBOX=1` as the last resort
- Library check never runs the payload (`ldd` is not used): `NEEDED` entries are read with
  `readelf -d` / `objdump -p` and resolved via `RUNPATH`/`$ORIGIN` then
  `ldconfig -p` (ABI-filtered). Package table limited to Electron's direct
  `NEEDED` set; apt names chosen by `apt-cache`; unknown sonames get a
  per-family search command
- `.deb` container opened with `bsdtar`, then `ar`, then `python3`;
  decompression by `bsdtar` when libarchive has the codec, otherwise `tar`
  plus `xz`/`zstd`/`gzip`, all checked before extraction starts. Python's
  `tarfile` is never used. Member names validated before extraction.
  `python3` and `tar` are no longer unconditional requirements; `gpg2` is
  accepted when `gpg` is absent
- Secret Service: detection and warning only, `basic` is never selected
  automatically; documented as untested on bare window managers
- `Valid-Until` enforced, and a `Date` more than 10 minutes in the future is
  refused; both read from gpg's verified output only. `InRelease` must be a
  single clear-signed block with no text outside it
- Downgrade refused when the repository's newest version is older than the
  installed one; `--allow-downgrade` overrides with a warning (never the
  signature or `Valid-Until`). Options are parsed as one mode plus modifiers
- Index `Date` floor: the newest verified `Date` is saved once `InRelease`
  and `Packages` verify, in every mode that fetches the index (including
  `--check` and "already up to date"), and an older index is refused
  (`--allow-downgrade` overrides with a warning). The saved value never
  decreases

## 1.0.0

Initial public release.

- Fingerprint-pinned OpenPGP verification of the Anthropic signing key
- Isolated `GNUPGHOME`, personal keyring untouched
- `InRelease` clear-signature verification, then SHA256 chain through the
  `Packages` index to the `.deb`
- `dpkg`-free extraction of the `ar` container in Python, control scripts never
  extracted or executed
- Versioned install under `~/.local/share/claude-desktop`, atomic symlink swap,
  two versions retained for rollback
- Wayland-native launcher with user-namespace sandbox detection
- `--check`, `--force`, `--uninstall`, `--purge`, `--help`, `--version`
