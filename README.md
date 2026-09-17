# Install Official Claude Desktop on Bluefin/Silverblue - Zero Layering, No Root, Pure Userland

A single Bash script that installs Anthropic's **official** Claude Desktop `.deb`
into your home directory on an rpm-ostree / bootc system, without `dpkg`,
without `rpm-ostree install`, and without ever asking for `sudo`.

Tested on Bluefin GDX. The approach applies to any immutable Fedora variant
(Silverblue, Kinoite, Bazzite, uBlue images, Fedora CoreOS) and works just as
well on a mutable distro where you simply do not want vendor packages in `/usr`.

```
curl -fsSLO https://raw.githubusercontent.com/ABDUAZIZX/claude-desktop-userland/main/claude-desktop-userland.sh
chmod +x claude-desktop-userland.sh
./claude-desktop-userland.sh
```

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
vendor's own signature, unpack it with Python instead of `dpkg`, and drop the
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
6. Parses the `.deb` `ar` container in pure Python, extracts `data.tar.*`,
   locates the Electron app root by finding `resources/app.asar`.
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
~/.local/share/claude-desktop/versions/<version>/   application payload
~/.local/share/claude-desktop/current               symlink to the active version
~/.local/bin/claude-desktop                         launcher wrapper
~/.local/share/applications/claude-desktop.desktop  menu entry
~/.local/share/icons/hicolor/...                    icons
~/.config/Claude/                                   created by the app itself
```

Nothing is written outside `$HOME`. Uninstalling is `rm -rf` of the paths above,
which is exactly what `--uninstall` does.

The two most recent versions are kept. If an update misbehaves, point the
symlink back:

```
ln -sfn ~/.local/share/claude-desktop/versions/<older> \
        ~/.local/share/claude-desktop/current
```

---

## Usage

| Command | Effect |
| --- | --- |
| `./claude-desktop-userland.sh` | Install, or upgrade if a newer version exists |
| `./claude-desktop-userland.sh --check` | Compare installed vs. available, change nothing |
| `./claude-desktop-userland.sh --force` | Reinstall the current version |
| `./claude-desktop-userland.sh --uninstall` | Remove the app, keep `~/.config/Claude` |
| `./claude-desktop-userland.sh --purge` | Remove the app and its configuration |
| `./claude-desktop-userland.sh --help` | Usage text |

The script is idempotent. Running it on a schedule (a user systemd timer, for
example) is a reasonable update strategy, since the app's own updater cannot
work here.

### Launcher environment variables

| Variable | Effect |
| --- | --- |
| `CLAUDE_NO_SANDBOX=1` | Pass `--no-sandbox` to Chromium. Only if user namespaces are unavailable, and understand what you are giving up |
| `CLAUDE_FORCE_X11=1` | Run under XWayland instead of the native Wayland backend |

Under a Wayland session the launcher adds `--ozone-platform-hint=auto` and
`--enable-features=WaylandWindowDecorations`, which fixes fractional scaling
and input method behaviour that are otherwise broken under XWayland.

---

## Requirements

- `curl`, `gpg`, `sha256sum`, `awk`, `tar`, `python3`, `find`, `sed`
  (all present in the Bluefin/Silverblue base image)
- `zstd` only if Anthropic ever switches the payload to `data.tar.zst`
- x86_64 or aarch64
- Unprivileged user namespaces enabled (`/proc/sys/user/max_user_namespaces >= 1`),
  which is the Fedora default
- The Electron runtime libraries, which the base image already provides:
  glibc, GTK3, `libnss3`, `libatk`, `libdrm`, Mesa, and an audio stack

The script prints an environment report at the end covering PATH, `/dev/kvm`
and user namespaces.

---

## Limitations

Read [docs/LIMITATIONS.md](docs/LIMITATIONS.md) before relying on this. The
short version:

- **No dependency resolution.** `dpkg` is not involved, so nothing checks that
  the shared libraries Electron needs are present. On a full desktop image they
  are. In a minimal container they are not.
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
- If you find a flaw in the verification chain, open an issue rather than a
  pull request first.

## License

MIT. See [LICENSE](LICENSE).

Claude and Claude Desktop are products of Anthropic. This project is not
affiliated with, endorsed by, or supported by Anthropic, and distributes none
of their software.
