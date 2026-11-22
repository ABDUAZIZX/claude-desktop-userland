# Limitations and known gaps

Nothing here is hidden in a footnote. If one of these is a blocker for you, use
a distrobox container instead.

## Packaging

**No dependency resolution.** `dpkg` would refuse to install a package whose
`Depends:` are unmet. This script does not read `Depends:` at all. On a Bluefin,
Silverblue or Kinoite base image the Electron dependency set (glibc, GTK3,
`libnss3`, `libatk`, `libdrm`, Mesa, PipeWire/ALSA) is already present, so the
practical failure rate is near zero. On a stripped-down image or inside a
minimal container libraries will be missing. After every install, and on
`--doctor`, the script reads the `NEEDED` entries of the binary and every
bundled `*.so` with `readelf -d` (fallback `objdump -p`) and resolves them the
way the loader would: `RUNPATH`/`RPATH` with `$ORIGIN` first, then the
`ldconfig -p` cache filtered to the machine's ABI. Nothing from the payload is
executed or loaded; `ldd` is deliberately not used, since it can run code from
the file it inspects. Without binutils the check is skipped with a warning.

Limits of this check: it covers direct dependencies only, not the
dependencies of system libraries (the system's own package manager owns
those), and it cannot see libraries the app opens later with `dlopen()`
(`libnotify`, `libsecret`, PipeWire and others in `Depends:`). Missing
sonames are mapped to package names for apt, dnf, pacman and zypper for
Electron's direct `NEEDED` set only; on apt systems the name is the one
`apt-cache` knows, which handles the `t64` renames of Ubuntu 24.04+ and
Debian 13. Anything else is printed with the family's search command
(`apt-file search`, `dnf provides`, `pacman -F`, `zypper se --provides`). A
glibc older than 2.34, or no glibc at all, stops the install before the
download.

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

The options, in order of preference:

1. **A userns profile for this install.** `--print-apparmor-profile` prints a
   profile of the same form as Ubuntu's browser profiles (`abi <abi/4.0>`,
   `flags=(unconfined)`, `userns,`), attached to your install path, plus the
   two root commands that load and remove it. `--doctor` and the launcher both
   warn while it is missing.
2. **Last resort: `CLAUDE_NO_SANDBOX=1`.** This disables the Chromium sandbox
   entirely. Web content rendered by the app is then no longer isolated from
   your session.

**The trade-off of option 1, stated plainly.** The attachment path is inside
`$HOME` and writable by your user. Any code running with your privileges can
place a binary at that path, and AppArmor will let it create user namespaces.
That weakens the restriction for your account, which is the attack surface
the restriction exists to reduce (unprivileged userns is a common
kernel-exploit entry point). The official package does not have this weakness
because it attaches to a root-owned path under `/usr`. Option 2 is still the
larger loss, which is why it comes second.

The restriction is detected through
`/proc/sys/kernel/apparmor_restrict_unprivileged_userns`, which only exists on
Ubuntu kernels. When the file is absent there is no restriction to handle.

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
