# Changelog

## 1.1.0 (unreleased)

- `--inspect`: download and verify the latest package, print its
  `Depends`/`Recommends` and maintainer scripts (never executed), and diff them
  against the last version seen. A normal install/upgrade runs the same report
  automatically and keeps it under `~/.local/share/claude-desktop/package-meta/`
- Package metadata follows the same two-version retention as the app payload
- `--doctor`: offline host check. glibc floor (2.34, refuses musl), user
  namespaces including Debian's `unprivileged_userns_clone` and the Ubuntu
  24.04+ AppArmor restriction, `ldd` over the payload with missing sonames
  mapped to apt/dnf/pacman/zypper package names (t64-aware), Secret Service and
  xdg-desktop-portal on the session bus. Runs automatically after install
- `--print-apparmor-profile`: userns profile for the install path, with load
  and removal instructions and the trade-off spelled out
- glibc check before the download; `CLAUDE_SKIP_HOST_CHECK=1` overrides
- Launcher: warns about the AppArmor restriction, honours
  `CLAUDE_PASSWORD_STORE`
- Cowork report no longer claims `/dev/kvm` is sufficient
- `--uninstall` points at the AppArmor profile when one is installed

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
