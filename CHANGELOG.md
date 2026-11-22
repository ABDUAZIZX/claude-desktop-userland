# Changelog

## 1.1.0 (unreleased)

- `--inspect`: download and verify the latest package, print its
  `Depends`/`Recommends` and maintainer scripts (never executed), and diff them
  against the last version seen. A normal install/upgrade runs the same report
  automatically and keeps it under `~/.local/share/claude-desktop/package-meta/`
- Package metadata follows the same two-version retention as the app payload

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
