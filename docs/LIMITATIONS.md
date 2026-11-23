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

**Freshness depends on the local clock.** `Valid-Until` is enforced: an
expired index is refused, and so is one whose `Date` lies more than 10
minutes in the future. Both fields are read from gpg's verified output only,
and `InRelease` must be a single clear-signed block with nothing outside it.
A badly wrong system clock makes either check misfire, in the safe direction
(refusal). Missing `Date` or `Valid-Until` fields also cause a refusal.

**The `Date` floor is local and resettable.** The newest verified `Date` is
kept in `~/.local/share/claude-desktop/state/`. It is raised on every run
that verifies `InRelease` and the `Packages` index, `--check` and "already up
to date" included, so it tracks the newest index this machine has seen.
`--uninstall` removes it with the rest of the install, and
anything that can write to your home directory can edit it. A corrupt state
file stops the install until you delete it.

**Downgrade protection is by version comparison.** If the newest version in
the signed index is older than the installed one (`sort -V`), the install is
refused; `--check` reports it. `--allow-downgrade` accepts it with a warning,
for the case where upstream deliberately pulls a release. It never bypasses
the signature or `Valid-Until`. A first install has nothing to compare
against.

**This project's releases have one root of trust: the GitHub account.**
The release signing key, its fingerprint in the README, the tags and the
release files are all published through the maintainer's GitHub account;
there is no independent second source for the fingerprint. The signatures
protect against tampering with release files or the repository by anyone
who does not hold the private key. They do not protect against a takeover
of the account: its new owner can register another signing key and publish
matching fingerprints, tags and signatures. Recording the fingerprint the
first time and noticing when it changes is the only defence, and a partial
one. See [TRUST-CHAIN.md](TRUST-CHAIN.md#the-installer-itself-one-root-of-trust).

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

**Secret Service.** *Not yet tested on a bare window manager* (i3, sway,
Hyprland). What follows is the design, not a verified result.

The login token is stored through the Secret Service API (gnome-keyring,
KWallet, KeePassXC). Without one on the session bus, as is common on bare
window managers, the expectation is that you are asked to sign in on every
launch. The script only detects and warns: `--doctor` and the post-install
check look for `org.freedesktop.secrets` on the session bus (running or
D-Bus-activatable). Nothing is switched automatically. Setting
`CLAUDE_PASSWORD_STORE=basic` yourself makes the launcher pass
`--password-store=basic`, which keeps the token with weak obfuscation in
`~/.config/Claude` instead of a keyring.

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
