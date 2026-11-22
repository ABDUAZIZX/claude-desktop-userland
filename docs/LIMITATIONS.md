# Limitations and known gaps

Nothing here is hidden in a footnote. If one of these is a blocker for you, use
a distrobox container instead.

## Packaging

**No dependency resolution.** `dpkg` would refuse to install a package whose
`Depends:` are unmet. This script does not read `Depends:` at all. On a Bluefin,
Silverblue or Kinoite base image the Electron dependency set (glibc, GTK3,
`libnss3`, `libatk`, `libdrm`, Mesa, PipeWire/ALSA) is already present, so the
practical failure rate is near zero. On a stripped-down image or inside a
minimal container libraries will be missing. The installer runs `ldd` after
every install, and `--doctor` repeats the check at any time, mapping each
missing soname to a package name for apt, dnf, pacman or zypper. The mapping
covers the libraries Electron needs and is a hint, not a resolver. A glibc
older than 2.34, or no glibc at all, stops the install before the download.

**Maintainer scripts never run.** `preinst`, `postinst`, `prerm` and `postrm`
are not extracted and not executed. Consequences:

- `chrome-sandbox` does not get its setuid bit. Intentional. The launcher relies
  on unprivileged user namespaces, which is the modern and less dangerous path.
- MIME and URL scheme registration is limited to what the `.desktop` file
  declares. `x-scheme-handler/claude` deep links work only after
  `update-desktop-database` has run, which the script does call.
- No system-wide integration of any kind: no shared MIME database entry outside
  `$HOME`, no icon cache outside `$HOME`.

**No in-app updates.** Claude Desktop on Linux expects to be updated through
APT. It cannot rewrite `~/.local/share/claude-desktop`, and it would not know
how to verify a replacement even if it could. Re-run the script. A user timer is
the tidy way:

```
# ~/.config/systemd/user/claude-desktop-update.timer
[Unit]
Description=Check for Claude Desktop updates

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
```

with a matching `.service` running the script with no arguments.

## Verification

**`Valid-Until` is not enforced.** See the note in
[TRUST-CHAIN.md](TRUST-CHAIN.md). A signed but stale `InRelease` would be
accepted.

**No downgrade protection beyond version comparison.** The script installs the
highest version in the index. If a compromised index legitimately signed by
Anthropic listed an older vulnerable build as the only entry, the script would
install it.

**Fingerprint pinning is manual.** Key rotation requires a repository update.
Watch upstream announcements. A hard failure with `fingerprint mismatch!` is
either a rotation or an attack, and you cannot tell which from the script's
output alone.

## Runtime

**User namespaces are mandatory in practice.** If
`/proc/sys/user/max_user_namespaces` is `0`, the renderer sandbox cannot start.
`CLAUDE_NO_SANDBOX=1` exists as an escape hatch and should be treated as a last
resort, since it removes the process isolation between web content and your
session.

### AppArmor on Ubuntu 24.04+

Ubuntu 24.04 and later set `kernel.apparmor_restrict_unprivileged_userns=1`.
Unconfined processes can then no longer create user namespaces, and the
renderer sandbox fails to start. The official package solves this in its
`postinst` with an AppArmor profile attached to `/usr/lib/claude-desktop/...`,
and keeps a setuid `chrome-sandbox` as a fallback. Neither reaches an install
under `$HOME`.

`--print-apparmor-profile` prints the equivalent profile attached to your
install path, plus the two root commands that load it. `--doctor` and the
launcher both warn while it is missing. Loading it is a conscious trade-off:
the attachment path is writable by your user, so any process running as you can
place a binary there and get user namespaces. That re-opens, for your account
only, what the restriction closes. `CLAUDE_NO_SANDBOX=1` is the alternative,
and it is worse.

**Cowork needs more than `/dev/kvm`.** It runs its workspace inside a VM and
looks for QEMU (`/usr/bin/qemu-system-<arch>`) and OVMF firmware at fixed paths
under `/usr`. An atomic image without them cannot provide them from userland.
The rest of the application is unaffected. `--doctor` reports whether all three
are present.

**Secret Service.** The login token is stored through the Secret Service API
(gnome-keyring, KWallet, KeePassXC). Without one on the session bus, as is
common on bare window managers, you are asked to sign in on every launch.
`--doctor` checks for it. `CLAUDE_PASSWORD_STORE=basic` is the fallback, at the
cost of weak obfuscation on disk.

**SELinux.** Payloads under `~/.local/share` are labelled `data_home_t` and
Electron runs fine. If you relocate the install to a non-standard mount point,
relabel it or the Chromium sandbox may be denied. `ausearch -m AVC -ts recent`
is the first thing to check when a launch fails silently on an enforcing system.

**Symlink swap while running.** Updating replaces the `current` symlink target.
An already-running instance keeps its old inodes and continues normally, but
restart the application after an update to avoid loading mismatched resources.

## Scope

- Single user. There is no system-wide mode and adding one would require root,
  defeating the purpose.
- amd64 and arm64 only, because that is what Anthropic publishes.
- Linux only. Not portable to macOS or WSL in any meaningful way.
- GNU coreutils assumed (`head -n -2`, `sha256sum`). BusyBox will not do.
- The upstream repository layout is not a stable API. If Anthropic renames the
  package, moves the suite from `stable`, splits components, or ships the
  payload compressed differently, this script will fail loudly rather than
  install the wrong thing, but it will still fail.
