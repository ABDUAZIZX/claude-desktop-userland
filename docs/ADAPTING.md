# Adapting the method to other applications

The five-link verification chain is not specific to Claude Desktop. It is a
generic recipe for "install a vendor `.deb` into `$HOME` on an immutable
system". This document covers what has to change, and where the method stops
working.

## Is the target a candidate?

Answer these before writing any code. A single "no" in the left column usually
ends the exercise.

| Question | Why it matters |
| --- | --- |
| Is the repository cryptographically signed? | Without `InRelease` or `Release.gpg` there is no chain to build. An `[trusted=yes]` repository is out |
| Is the payload relocatable? | Binaries with paths compiled in (`/usr/lib/<app>/...`, `/etc/<app>/...`) break when moved to `$HOME` |
| Does it need setuid, capabilities, or udev rules? | These require root. Cannot be done from userland |
| Does it install a system service? | System units belong to root. A user unit rewrite is sometimes possible, often not worth it |
| Does it need a kernel module or a device node? | Out of scope entirely |
| Is a Flatpak available? | If yes, use it. Flatpak is the correct answer on an atomic system |

Bundled-runtime applications are the sweet spot: Electron, Tauri with static
assets, Go and Rust single binaries, JVM apps that ship their own runtime.
Anything installing into `/opt/<vendor>/` with no system integration beyond a
`.desktop` file and icons is usually a straight port.

## Parametrisation

Five constants at the top of the script carry all the app-specific knowledge:

```bash
KEY_URL="https://vendor.example/apt/key.asc"
REPO_BASE="https://vendor.example/apt"
KEY_FPR="0000000000000000000000000000000000000000"
PKG_NAME="vendor-app"
SUITE="stable"          # implicit in the current script
COMPONENT="main"        # implicit in the current script
```

Then three things must be checked against the target repository:

1. **Suite and component.** The script hardcodes `dists/stable` and
   `main/binary-<arch>/Packages`. Many vendors use `dists/stable/main`, some use
   the distribution codename (`dists/bookworm`, `dists/noble`), some publish
   several components.
2. **Payload compression.** `data.tar.xz` is the common case, `data.tar.zst` is
   increasingly used, `data.tar.gz` still appears. The script already handles
   all of them.
3. **The application root.** The `resources/app.asar` heuristic is
   Electron-specific. For anything else, replace step 7 with a direct path or a
   different marker file.

## Two APT signature layouts

The script assumes `InRelease` (inline clear-signature). Older or more
conservative repositories publish a detached signature instead:

```bash
curl -fsSLo Release     "$REPO_BASE/dists/$SUITE/Release"
curl -fsSLo Release.gpg "$REPO_BASE/dists/$SUITE/Release.gpg"
gpg --batch --quiet --verify Release.gpg Release \
  || die "Release signature verification FAILED"
cp Release Release.verified
```

This is slightly weaker in one respect: with `InRelease` you parse only what
gpg extracted from the envelope, whereas here you parse the same file the
signature refers to. It is equivalent as long as verification precedes parsing
and you never fall back to the unverified file on error.

Some repositories publish both. Prefer `InRelease`, fall back to
`Release`+`Release.gpg`.

## Compressed-only indices

Several repositories no longer ship an uncompressed `Packages`. The signed
metadata will list `main/binary-amd64/Packages.gz` or `.xz` instead. The
checksum applies to the **compressed** file, so verify first and decompress
second, never the other way round:

```bash
IDX_PATH="main/binary-${DEB_ARCH}/Packages.gz"
# ... pull IDX_SHA for that exact path from Release.verified ...
curl -fsSLo Packages.gz "$REPO_BASE/dists/$SUITE/$IDX_PATH"
echo "$IDX_SHA  Packages.gz" | sha256sum -c --quiet - || die "index checksum mismatch"
gunzip -c Packages.gz > Packages
```

## Flat repositories

A few vendors publish a flat repository (`deb https://vendor.example/apt ./`).
There is no `dists/` tree at all:

```
$REPO_BASE/InRelease
$REPO_BASE/Packages.gz
$REPO_BASE/pool/main/...
```

The chain is identical, only the paths shorten, and `Filename` in the index is
relative to `REPO_BASE`.

## Multi-package applications

If the vendor splits an application across several `.deb` files, the method
still works but you must resolve the set yourself, extract each payload into
the same scratch root, and confirm nothing expects an absolute path. At that
point a container is usually the better engineering decision.

## Compatibility notes for common targets

Verify every URL and fingerprint against the vendor's current documentation
before use. Endpoints and keys change, and a stale constant copied from a
README is exactly the failure mode the pinning is meant to prevent.

| Application | Verdict | Notes |
| --- | --- | --- |
| VS Code / VSCodium | Works | Self-contained Electron in `/usr/share/code`. Microsoft's repository uses the codename layout. VSCodium is on Flathub, prefer that |
| Signal Desktop | Works | Electron, `/opt/Signal`. Flatpak exists but is community-maintained, so this method is a reasonable alternative |
| Brave / Chrome / Edge | Partially | Payload relocates fine, but `chrome-sandbox` normally gets setuid from `postinst`. Same user-namespace workaround as here applies |
| Slack, Discord, Zoom | Works | Electron/Qt bundles in `/opt`. All three also have Flatpaks, which are the better choice |
| Obsidian, Cursor, Zed | Not applicable | Distributed as AppImage or tarball, no APT repository. Simpler: verify the published checksum and drop the file in `~/.local/bin` |
| 1Password | Does not work | Requires setuid helpers, a system group, and browser integration through a privileged socket |
| Docker, Tailscale, NVIDIA drivers | Does not work | System services, root daemons, kernel modules |
| Spotify | Works with caveats | Relocates, but widevine and media key integration can misbehave outside `/opt` |
| Steam, Wine | Does not work | Multi-arch dependency trees that only `dpkg`/`apt` can resolve sanely |

## A general rule for atomic systems

Order of preference, from best to worst:

1. Flatpak from Flathub, ideally verified by the vendor
2. Distrobox or toolbox container, exported with `distrobox-export`
3. This method: userland install of a verified vendor artifact
4. `rpm-ostree install` layering

Layering is last because it makes every future image update slower and gives
each upgrade a new way to fail. This method sits at three because it trades
`dpkg`'s dependency guarantees for keeping the base image pristine, which is a
good trade for bundled-runtime desktop applications and a bad one for anything
that touches the system.
