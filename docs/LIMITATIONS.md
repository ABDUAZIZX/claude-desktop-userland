# Limitations and known gaps

Nothing here is hidden in a footnote. If one of these is a blocker for you, use
a distrobox container instead.

## Packaging

**No dependency resolution.** `dpkg` would refuse to install a package whose
`Depends:` are unmet. This script does not read `Depends:` at all. On a Bluefin,
Silverblue or Kinoite base image the Electron dependency set (glibc, GTK3,
`libnss3`, `libatk`, `libdrm`, Mesa, PipeWire/ALSA) is already present, so the
practical failure rate is near zero. On a stripped-down image or inside a
minimal container you will get a dynamic linker error at launch, not at install
time. `ldd ~/.local/share/claude-desktop/current/<binary>` will tell you which
library is missing.

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

**The Cowork tab needs `/dev/kvm`.** It runs its workspace inside a VM. If
virtualization is disabled in firmware, or your user is not in the `kvm` group,
that tab will not function. The rest of the application is unaffected. The
script reports the state of `/dev/kvm` at the end of an install.

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
