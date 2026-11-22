# Changelog

## 1.1.0 (unreleased)

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
- glibc check before the download; `CLAUDE_SKIP_HOST_CHECK=1` overrides
- Launcher: warns about the AppArmor restriction, honours
  `CLAUDE_PASSWORD_STORE`
- Cowork report no longer claims `/dev/kvm` is sufficient
- `--uninstall` points at the AppArmor profile when one is installed
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
