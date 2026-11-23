# Unofficial Userland Installer for the Official Claude Desktop - Zero Layering, No Root

> **Unofficial.** This installer is not made, endorsed or supported by
> Anthropic. What it installs is Anthropic's official, signed Claude Desktop
> package, verified and unpacked without modification.

A single Bash script that installs Anthropic's **official** Claude Desktop `.deb`
into your home directory on an rpm-ostree / bootc system, without `dpkg`,
without `rpm-ostree install`, and without ever asking for `sudo`.

Tested on Bluefin LTS (see [Compatibility](#compatibility)). The approach is
meant for immutable systems and works just as well on a mutable distro where
you simply do not want vendor packages in `/usr`.

Install from the `v1.3.0` tag, not from `main`. Check the script's SHA256,
then the release signature, before running it:

```
curl -fsSLO https://raw.githubusercontent.com/ABDUAZIZX/claude-desktop-userland/v1.3.0/claude-desktop-userland.sh
echo "64372afe7e636888148bb58cbbe915ec03b1dc40ab2a4694f0e76c761944bef7  claude-desktop-userland.sh" | sha256sum -c -

# release signature: SHA256SUMS signed with the release key (from 1.2.0 on)
curl -fsSLO https://github.com/ABDUAZIZX/claude-desktop-userland/releases/download/v1.3.0/SHA256SUMS
curl -fsSLO https://github.com/ABDUAZIZX/claude-desktop-userland/releases/download/v1.3.0/SHA256SUMS.sig
curl -fsSL https://api.github.com/users/ABDUAZIZX/ssh_signing_keys \
  | grep -o '"key": *"[^"]*"' | cut -d'"' -f4 > signing_key.pub
ssh-keygen -lf signing_key.pub   # must be SHA256:DFqKPwKi7WOq6aOIBO9yx6LqjhgqC/n29X6v4u8oVsI
sed 's/^/release namespaces="file" /' signing_key.pub > allowed_signers
ssh-keygen -Y verify -f allowed_signers -I release -n file -s SHA256SUMS.sig < SHA256SUMS
sha256sum -c SHA256SUMS

chmod +x claude-desktop-userland.sh
./claude-desktop-userland.sh --doctor   # optional: host check, offline
./claude-desktop-userland.sh
```

Both `sha256sum -c` lines must print `claude-desktop-userland.sh: OK`, and
`ssh-keygen -Y verify` must print `Good "file" signature`; anything else
means the file is not the signed release, so do not run it. The first check
pins the hash written in this README; the second proves the release was
signed with the maintainer's key. Both trace back to the same GitHub account,
so neither protects against a takeover of that account (see
[Verify a release signature](#verify-a-release-signature)).

No pipe-to-shell one-liner is offered on purpose. Read the script first.

---

## Why this exists

Anthropic ships Claude Desktop for Linux as a `.deb` in a signed APT
repository. On an atomic Fedora system there are three usual options, and all
three are bad:

| Option | Problem |
| --- | --- |
| `rpm-ostree install` an rpm conversion | Nothing to convert; adds a layered package that must be rebased on every update |
| Distrobox / toolbox | Works, but a full container for one Electron app, plus display, portal and file-picker friction |
| Unofficial repackaging (AppImage/Flatpak from third parties) | You stop running Anthropic's signed binary |

This script takes a fourth route: verify the vendor's own artifact against the
vendor's own signature, unpack it without `dpkg`, and drop the
payload into `~/.local/share`. The base image stays untouched, so
`bootc upgrade` / `rpm-ostree upgrade` never has to reconcile anything.

---

## What it actually does

1. Downloads Anthropic's OpenPGP signing key and compares its fingerprint to a
   pinned value inside the script.
2. Imports that key into a throwaway keyring in `$TMPDIR`. Your `~/.gnupg` is
   never opened or modified.
3. Verifies the clear-signed `InRelease` file for `stable` against that keyring,
   which contains exactly one key.
4. Reads the SHA256 of the `Packages` index **from the verified `InRelease`**,
   downloads the index and checks it.
5. Reads the SHA256 of the `.deb` **from the verified index**, downloads the
   package and checks it.
6. Opens the `.deb` `ar` container with `bsdtar`, `ar` or `python3` (first
   found), extracts `data.tar.*`, and locates the Electron app root by finding
   `resources/app.asar`.
7. Copies the payload to `~/.local/share/claude-desktop/versions/<version>/`
   and flips the `current` symlink.
8. Writes a launcher wrapper, a `.desktop` entry, and the icon set.

Every step is fail-closed. A mismatch anywhere aborts before anything is
written outside `$TMPDIR`. See [docs/TRUST-CHAIN.md](docs/TRUST-CHAIN.md) for
the detailed threat model and for what each link does and does not protect
against.

---

## Layout on disk

```
~/.local/share/claude-desktop/versions/<version>/   application payload (two kept)
~/.local/share/claude-desktop/current               symlink to the active version
~/.local/share/claude-desktop/package-meta/<ver>/   control file, maintainer scripts (never run)
~/.local/share/claude-desktop/state/                newest verified index Date (rollback floor)
~/.local/share/claude-desktop/staged/<version>/     auto-update only: verified, not active
~/.local/share/claude-desktop/updater/              auto-update only: the script the timer runs
~/.config/systemd/user/claude-desktop-update.*      auto-update only: service and timer
~/.local/bin/claude-desktop                         launcher wrapper
~/.local/share/applications/claude-desktop.desktop  menu entry
~/.local/share/icons/hicolor/...                    icons
~/.config/Claude/                                   created by the app itself
```

`staged/` is deliberately separate from `versions/`: `--rollback` and the
two-version retention only look at `versions/`, so a staged version is never
switched to or counted until you run `--activate-staged`.

Nothing is written outside `$HOME`. Uninstalling is `rm -rf` of the paths above,
which is exactly what `--uninstall` does.

The two most recent versions are kept. If an update misbehaves, switch back
with `--rollback`: offline, it points `current` at the other kept version
(after checking that it is complete), then runs the host check. It pins
nothing; the next plain run installs the newest repository version again.

---

## Usage

Output of `./claude-desktop-userland.sh --help`, verbatim:

<!-- usage:begin -->
```
claude-desktop-userland.sh 1.3.0

Installs the official Claude Desktop .deb into $HOME on an rpm-ostree /
bootc system, without dpkg, without layering, without root.

  (no option)   install, or upgrade to the latest published version
  --check       report installed vs. available version, change nothing
  --inspect     download latest, show package relations and maintainer
                scripts, diff against the last seen version; no install
  --force       reinstall even if already up to date
  --rollback    switch back to the previous version kept on disk; offline,
                pins nothing (the next plain run installs the newest again)
  --enable-auto-update
                install a daily systemd user timer that downloads, verifies
                and STAGES new versions and notifies you; it never changes
                what is launched
  --disable-auto-update
                remove that timer
  --stage       what the timer runs: verify and stage the latest version
  --activate-staged
                switch to the staged version, offline
  --allow-downgrade
                modifier: accept a repository version older than the one
                installed, and an index Date older than the last one
                verified (with a warning). Never bypasses the signature or
                Valid-Until checks
  --skip-host-check
                modifier for install and --force: continue when glibc is
                older than 2.34 (the version floor only). It does NOT
                cover a host without glibc (musl is still refused), does not
                silence the NixOS warning, does not skip the post-install
                checks, and touches no signature, freshness or downgrade
                check
  --doctor      check this host can run the app (glibc, sandbox, shared
                libraries, keyring, portals); offline, changes nothing
  --print-apparmor-profile
                print an AppArmor profile for Ubuntu 24.04+ hosts that
                restrict user namespaces, with install instructions
  --uninstall   remove the application, keep ~/.config/Claude
  --purge       remove the application and its configuration/data
  --help        this text
  --version     print the script version
```
<!-- usage:end -->

The script is idempotent. Running it on a schedule (a user systemd timer, for
example) is a reasonable update strategy, since the app's own updater cannot
work here.

### Launcher environment variables

| Variable | Effect |
| --- | --- |
| `CLAUDE_NO_SANDBOX=1` | Last resort. Passes `--no-sandbox`, which disables the Chromium sandbox entirely. On Ubuntu 24.04+ try `--print-apparmor-profile` first |
| `CLAUDE_FORCE_X11=1` | Run under XWayland instead of the native Wayland backend |
| `CLAUDE_PASSWORD_STORE=basic` | Pass `--password-store=basic`. For sessions without a Secret Service (bare window managers), where the login would otherwise not persist. The token is then stored with weak obfuscation only |

The installer reads no environment variables that change its checks.
`--skip-host-check` (install and `--force` only) lets an install continue on a
glibc older than 2.34, and nothing else: a host without glibc (musl) is still
refused, the NixOS warning is still shown, the post-install checks still run,
and no signature, freshness or downgrade check is affected.

Under a Wayland session the launcher adds `--ozone-platform-hint=auto` and
`--enable-features=WaylandWindowDecorations`, which fixes fractional scaling
and input method behaviour that are otherwise broken under XWayland.

---

## Automatic update checks

```
./claude-desktop-userland.sh --enable-auto-update
```

installs a daily systemd user timer (`claude-desktop-update.timer`) that
runs the full trust chain, **stages** a newer verified version under
`~/.local/share/claude-desktop/staged/<ver>` and sends a desktop
notification with the version and whether its package relations or
maintainer scripts changed. It never changes what is launched. When you
are ready:

```
~/.local/share/claude-desktop/updater/claude-desktop-userland.sh --activate-staged
```

switches to the staged version offline (launcher, desktop entry and host
check as after an install); `--rollback` goes back. `--disable-auto-update`
removes the timer; `--uninstall` does too. The timer runs a copy of the
script you enabled it with, which is not updated automatically. See
[docs/LIMITATIONS.md](docs/LIMITATIONS.md) for what is and is not notified.

---

## Requirements

- `curl`, `gpg` (or `gpg2`), `sha256sum`, `awk`, `find`, `sed`, `diff`, `grep`
- One tool to open the `.deb` container, first found wins: `bsdtar`
  (libarchive), `ar` (binutils), or `python3`
- Unless `bsdtar` handles the codec itself: `tar` plus the decompressor for the
  payload, `xz` (`xz-utils` on Debian/Ubuntu), `zstd` or `gzip`. A missing
  one is reported with its package name before anything is extracted
- `readelf` or `objdump` (binutils) for the shared-library check; without them
  that one check is skipped
- x86_64 or aarch64
- glibc 2.34 or newer. musl systems (Alpine, Void-musl) and older releases
  (Debian 11, RHEL/Alma/Rocky 8) are refused before anything is downloaded
- Unprivileged user namespaces enabled (`/proc/sys/user/max_user_namespaces >= 1`),
  which is the Fedora default. On Ubuntu 24.04+ the AppArmor userns restriction
  also applies: see `--print-apparmor-profile` and
  [docs/LIMITATIONS.md](docs/LIMITATIONS.md#apparmor-on-ubuntu-2404)
- The Electron runtime libraries (GTK3, NSS, ATK/AT-SPI, Mesa GBM, X11 client
  libraries, ALSA). Desktop images ship them; minimal ones do not

After every install the script runs the same checks as `--doctor`. Shared
libraries are checked without running or loading the payload: `NEEDED` entries
are read with `readelf -d` (or `objdump -p`, both from binutils) and resolved
through the app's own `RUNPATH`/`$ORIGIN`, then `ldconfig -p`. Missing ones are
translated into an install command for apt, dnf, pacman or zypper; on apt
systems the package name (for example `libasound2t64` versus `libasound2`) is
the one `apt-cache` knows. Without binutils the library check is skipped with
a warning.

Each blocking problem is printed with a fixed marker, `[fail:<id>]`, so
scripts can tell problems apart without matching the wording, which may
change:

<!-- fail-ids:begin -->
| Marker | Meaning |
| --- | --- |
| `glibc-missing` | no glibc (musl); refused |
| `glibc-too-old` | glibc older than 2.34 |
| `glibc-check-skipped` | the installed version was installed with `--skip-host-check` |
| `userns-disabled` | `user.max_user_namespaces=0` |
| `userns-clone-disabled` | Debian's `kernel.unprivileged_userns_clone=0` |
| `apparmor-userns` | Ubuntu 24.04+ AppArmor userns restriction and no profile |
| `missing-libs` | shared libraries that do not resolve |
<!-- fail-ids:end -->

The IDs are stable. Renaming or removing one is a breaking change and is
recorded as such in [CHANGELOG.md](CHANGELOG.md); new IDs may be added.

---

## User namespaces and the Chromium sandbox

`chrome-sandbox` is never made setuid here (that needs root), so the renderer
sandbox depends on unprivileged user namespaces. Most distributions allow them.
**Ubuntu 24.04 and later restrict them through AppArmor**
(`kernel.apparmor_restrict_unprivileged_userns=1`): an unconfined program can
no longer create one, and the sandbox fails to start. `--doctor` and the
launcher detect this. The official package lifts the restriction with a
profile for `/usr/lib/claude-desktop/...`, which does not cover an install
under `$HOME`.

The options, in order:

1. **Load a userns profile for this install (preferred with this installer).**
   `--print-apparmor-profile` prints one in the form Ubuntu uses for browsers
   (`abi <abi/4.0>`, `flags=(unconfined)`, `userns,`), attached to your install
   path, plus the root commands to load and remove it.
   **Trade-off:** that path is inside `$HOME` and writable by you. Any code
   running with your privileges can place a binary there and will be allowed
   to create user namespaces, which weakens the restriction for your account.
2. **Use the official `.deb` through APT instead of this installer** (outside
   its scope; needs root and a mutable system). Its profile attaches to a
   root-owned path, so it does not have the weakness of option 1.
3. **Last resort: `CLAUDE_NO_SANDBOX=1`.** Disables the Chromium sandbox
   entirely; web content is then no longer isolated from your session.

Details: [docs/LIMITATIONS.md](docs/LIMITATIONS.md#apparmor-on-ubuntu-2404).

---

## Compatibility

| System | Status |
| --- | --- |
| Bluefin LTS (`bluefin-lts-nvidia`, CentOS Stream 10 base), GNOME on Wayland | **Works (daily use)** |
| Ubuntu 24.04 | **Launch + sandbox verified (CI)** |
| Ubuntu 22.04 | Libraries checked (CI) |
| Debian 12 / 13 | Libraries checked (CI) |
| Fedora 43 | Libraries checked (CI) |
| Arch Linux | Libraries checked (CI) |
| openSUSE Tumbleweed | Libraries checked (CI) |
| Fedora Silverblue / Kinoite, other uBlue images | Untested |
| AlmaLinux 8 (glibc 2.28), Alpine (musl) | Refused (CI) |

What each status means:

- **Works (daily use)**: installed, upgraded and used every day by the author.
- **Launch + sandbox verified (CI)**: the `sandbox` job of the
  [`distros` workflow](.github/workflows/distros.yml) launches the app on a
  GitHub Ubuntu 24.04 runner with the AppArmor userns restriction on, and
  confirms that the renderer runs in its own user namespace with the profile
  from `--print-apparmor-profile` and does not without it. A virtual display
  is used; nobody signed in or used the app there.
- **Libraries checked (CI)**: in a container of that distribution, the unit
  tests pass and every shared library resolves after installing the packages
  `--doctor` suggests. The app is not launched, so the sandbox, the display
  and the login are not covered.
- **Untested**: none of the above has run on that system.
- **Refused (CI)**: the installer stops before downloading anything, by design
  (see Requirements); CI checks that it still does. Other systems with glibc
  older than 2.34 or with musl are refused the same way.

The CI statuses come from the weekly and per-change runs of the `distros`
workflow; a failing run there means the table no longer holds for that row.

---

## Limitations

Read [docs/LIMITATIONS.md](docs/LIMITATIONS.md) before relying on this. The
short version:

- **No dependency resolution.** `dpkg` is not involved. `--doctor` reads the
  ELF `NEEDED` entries (nothing is executed) and prints the packages to
  install, but it installs nothing itself.
- **Maintainer scripts are not executed.** `postinst` never runs. In practice
  this only costs the setuid bit on `chrome-sandbox`, which is deliberate:
  the launcher relies on unprivileged user namespaces instead.
- **In-app updates do not work.** The app cannot rewrite an APT installation it
  did not create. Re-run the script.
- **The pinned fingerprint is a hard dependency.** If Anthropic rotates its
  signing key, the script fails closed and will not install anything until the
  fingerprint is updated here. That is the intended behaviour.
- **Upstream layout is not a contract.** The repository path, the package name
  and the internal directory structure of the `.deb` can change without notice
  and would break the parsing logic.
- **Single user, single machine.** No system-wide install, no multi-user share.
- **Not affiliated with Anthropic.** This is an unofficial installer for an
  official artifact. It ships no Anthropic code and redistributes nothing.

---

## Verify the pinned key fingerprint yourself

Do not take the constant in this repository on trust. Compare it against
Anthropic's published Linux installation instructions, and against what the
server actually serves:

```
curl -fsSL https://downloads.claude.ai/claude-desktop/key.asc \
  | gpg --with-colons --show-keys \
  | awk -F: '/^fpr:/{print $10; exit}'
```

If that value differs from `KEY_FPR` in the script, stop and find out why
before changing anything.

---

## Verify a release signature

From 1.2.0 on, every GitHub Release carries `SHA256SUMS` (the SHA256 of
`claude-desktop-userland.sh`) and `SHA256SUMS.sig`, a detached SSH signature
over it made with the same key that signs the release tags.

The public key is published on the maintainer's GitHub account at
[`api.github.com/users/ABDUAZIZX/ssh_signing_keys`](https://api.github.com/users/ABDUAZIZX/ssh_signing_keys).
Its fingerprint is
`SHA256:DFqKPwKi7WOq6aOIBO9yx6LqjhgqC/n29X6v4u8oVsI`.

**What this proves, and what it does not.** The only root of trust is that
GitHub account: the key, this fingerprint, the tags and the release files
are all published through it, and there is no independent second source.
The signature protects against tampering with the release files or the
repository by anyone without the private key, which is not stored on
GitHub. It does **not** protect against a compromise of the account: its
new owner can register a different key and publish a matching fingerprint
and signatures, and these commands would then succeed. Note the
fingerprint the first time you verify, and treat a change as a reason to
stop. Details: [docs/TRUST-CHAIN.md](docs/TRUST-CHAIN.md#the-installer-itself-one-root-of-trust).

```bash
V=vX.Y.Z   # the release to check
B=https://github.com/ABDUAZIZX/claude-desktop-userland/releases/download/$V
curl -fsSLO "$B/SHA256SUMS"
curl -fsSLO "$B/SHA256SUMS.sig"
curl -fsSLO "$B/claude-desktop-userland.sh"

# the key as published on the GitHub account; check its fingerprint
curl -fsSL https://api.github.com/users/ABDUAZIZX/ssh_signing_keys \
  | grep -o '"key": *"[^"]*"' | cut -d'"' -f4 > signing_key.pub
ssh-keygen -lf signing_key.pub    # must show the fingerprint above
sed 's/^/release namespaces="file" /' signing_key.pub > allowed_signers

ssh-keygen -Y verify -f allowed_signers -I release -n file \
  -s SHA256SUMS.sig < SHA256SUMS  # Good "file" signature ...
sha256sum -c SHA256SUMS           # claude-desktop-userland.sh: OK
```

The same key verifies the tags (`git tag -v vX.Y.Z` with that key in
`gpg.ssh.allowedSignersFile`). `tools/release-sums.sh verify DIR
allowed_signers` runs both checks in one step.

---

## Can the same method be used for other applications?

Yes, for a specific class of them. The technique is generic: verify a signed
APT repository, extract the `.deb` without `dpkg`, and relocate the payload
into `$HOME`. It works when the package is self-contained and relocatable, and
it fails when the package expects root.

Rule of thumb:

| Works well | Does not work |
| --- | --- |
| Electron and other bundled-runtime apps | Anything installing a systemd system unit |
| Statically laid out `/opt/<vendor>` payloads | Anything needing setuid, udev rules, or a kernel module |
| Apps whose only integration is a `.desktop` file and icons | Apps with hardcoded absolute paths compiled in |
| Signed vendor repositories | Unsigned or `[trusted=yes]` repositories |

[docs/ADAPTING.md](docs/ADAPTING.md) covers the parametrisation, the two APT
signature layouts you will meet (`InRelease` vs. detached `Release.gpg`),
compressed-only indices, flat repositories, and a compatibility table with
notes for several common vendors.

On an atomic system the ordering to prefer is still: Flatpak, then a container,
then this method, and layering last.

---

## Security notes

- The script never runs as root and never calls `sudo`.
- The isolated `GNUPGHOME` means a compromised or malicious key cannot end up
  in your personal keyring, and a signature made by any other key you happen to
  trust cannot validate the repository.
- All downloads land in a `mktemp -d` directory that is removed by an `EXIT`
  trap, including on failure.
- The payload is installed to a staging path and moved into place, so an
  interrupted extraction cannot leave a half-written version directory that the
  `current` symlink points at.
- **`Valid-Until` is enforced.** An expired repository index is refused, and
  so is one whose `Date` is more than 10 minutes in the future. Both fields
  are read only from the content gpg verified; `InRelease` must be a single
  clear-signed block with nothing outside it.
- **An index older than the last one verified is refused.** Once `InRelease`
  and the `Packages` index it pins have verified, the index `Date` is stored
  in `~/.local/share/claude-desktop/state/`, in every mode that fetches the
  index (install, `--force`, `--check`, `--inspect`, and when already up to
  date). A later index with an older `Date` is rejected as a possible
  rollback. The stored value never decreases.
- **Downgrades are refused.** If the newest version in the signed index is
  older than the installed one, the install stops.
- `--allow-downgrade` overrides the last two, with a warning. Nothing
  overrides the signature or `Valid-Until`.
- If you find a flaw in the verification chain, open an issue rather than a
  pull request first.

## License

MIT. See [LICENSE](LICENSE).

Claude and Claude Desktop are products of Anthropic. This project is not
affiliated with, endorsed by, or supported by Anthropic, and distributes none
of their software.
