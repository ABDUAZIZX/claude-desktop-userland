#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# claude-desktop-userland.sh
#
# Installs Anthropic's OFFICIAL Claude Desktop .deb into the user's home
# directory on an rpm-ostree / bootc system (Bluefin, Silverblue, CoreOS...)
# without dpkg, without layering, and without touching the base image.
#
# Trust chain (nothing is trusted on faith):
#   1. signing key downloaded, fingerprint compared to the documented one
#   2. key imported into an ISOLATED keyring (your ~/.gnupg is untouched)
#   3. InRelease clearsig verified against that keyring only
#   4. Packages index verified by SHA256 taken from the verified InRelease
#   5. .deb verified by SHA256 taken from the verified Packages index
#
# Everything lands under:
#   ~/.local/share/claude-desktop/versions/<version>/   app payload
#   ~/.local/share/claude-desktop/current               symlink (atomic swap)
#   ~/.local/bin/claude-desktop                         launcher
#   ~/.local/share/applications/claude-desktop.desktop  menu entry
#   ~/.local/share/icons/hicolor/...                    icons
#
# Usage:
#   ./claude-desktop-userland.sh              install or upgrade to latest
#   ./claude-desktop-userland.sh --check      report installed vs. available
#   ./claude-desktop-userland.sh --inspect    download latest, show package
#                                             relations and maintainer scripts,
#                                             diff against last seen; no install
#   ./claude-desktop-userland.sh --force      reinstall even if up to date
#   ./claude-desktop-userland.sh --uninstall  remove app (keeps ~/.config/Claude)
#   ./claude-desktop-userland.sh --purge      remove app AND config/data
# ---------------------------------------------------------------------------

set -euo pipefail
umask 022

# --- constants -------------------------------------------------------------
KEY_URL="https://downloads.claude.ai/claude-desktop/key.asc"
REPO_BASE="https://downloads.claude.ai/claude-desktop/apt/stable"
KEY_FPR="31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE"
PKG_NAME="claude-desktop"
SELF_VERSION="1.1.0"

BASE="${XDG_DATA_HOME:-$HOME/.local/share}/claude-desktop"
VERSIONS="$BASE/versions"
META_DIR="$BASE/package-meta"
CURRENT="$BASE/current"
BIN="$HOME/.local/bin/claude-desktop"
DESKTOP_FILE="${XDG_DATA_HOME:-$HOME/.local/share}/applications/claude-desktop.desktop"
ICON_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor"

# --- helpers ---------------------------------------------------------------
c_ok()   { printf '\033[32m[ ok ]\033[0m %s\n' "$*"; }
c_info() { printf '\033[36m[info]\033[0m %s\n' "$*"; }
c_warn() { printf '\033[33m[warn]\033[0m %s\n' "$*" >&2; }
c_err()  { printf '\033[31m[fail]\033[0m %s\n' "$*" >&2; }
die()    { c_err "$*"; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

# --- uninstall -------------------------------------------------------------
do_uninstall() {
  local purge="${1:-no}"
  rm -f  "$BIN" "$DESKTOP_FILE"
  find "$ICON_ROOT" -name 'claude-desktop.*' -delete 2>/dev/null || true
  rm -rf "$BASE"
  command -v update-desktop-database >/dev/null 2>&1 && \
    update-desktop-database "$(dirname "$DESKTOP_FILE")" 2>/dev/null || true
  c_ok "application removed"
  if [ "$purge" = "purge" ]; then
    rm -rf "$HOME/.config/Claude" "$HOME/.config/claude-desktop"
    c_ok "config and local data removed"
  else
    c_info "config kept at ~/.config/Claude (use --purge to delete)"
  fi
  exit 0
}

usage() {
  cat <<USAGE
claude-desktop-userland.sh $SELF_VERSION

Installs the official Claude Desktop .deb into \$HOME on an rpm-ostree /
bootc system, without dpkg, without layering, without root.

  (no option)   install, or upgrade to the latest published version
  --check       report installed vs. available version, change nothing
  --inspect     download latest, show package relations and maintainer
                scripts, diff against the last seen version; no install
  --force       reinstall even if already up to date
  --uninstall   remove the application, keep ~/.config/Claude
  --purge       remove the application and its configuration/data
  --help        this text
  --version     print the script version
USAGE
}

MODE="install"
case "${1:-}" in
  --uninstall)     do_uninstall no ;;
  --purge)         do_uninstall purge ;;
  --check)         MODE="check" ;;
  --inspect)       MODE="inspect" ;;
  --force)         MODE="force" ;;
  -h|--help)       usage; exit 0 ;;
  -V|--version)    printf '%s\n' "$SELF_VERSION"; exit 0 ;;
  "")              : ;;
  *)               usage >&2; die "unknown option: $1" ;;
esac

# --- preflight -------------------------------------------------------------
for t in curl gpg sha256sum awk tar python3 find sed diff; do need "$t"; done

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)  DEB_ARCH="amd64" ;;
  aarch64) DEB_ARCH="arm64" ;;
  *) die "unsupported architecture: $ARCH (Anthropic publishes amd64 and arm64 only)" ;;
esac

INSTALLED_VER=""
[ -L "$CURRENT" ] && INSTALLED_VER="$(basename "$(readlink -f "$CURRENT")")"

TMP="$(mktemp -d -t claude-desktop.XXXXXXXX)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"

# --- 1. signing key + fingerprint check ------------------------------------
c_info "fetching Anthropic signing key"
curl -fsSLo key.asc "$KEY_URL" || die "could not download signing key"

GOT_FPR="$(gpg --with-colons --show-keys key.asc 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')"
[ -n "$GOT_FPR" ] || die "file is not a valid OpenPGP key"
if [ "$GOT_FPR" != "$KEY_FPR" ]; then
  die "fingerprint mismatch!
     expected: $KEY_FPR
     received: $GOT_FPR
     Aborting. Do not continue."
fi
c_ok "key fingerprint verified ($KEY_FPR)"

export GNUPGHOME="$TMP/gnupg"
mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
gpg --batch --quiet --import key.asc
# isolated keyring holds ONLY this key -> a good signature can only be Anthropic's

# --- 2. verify InRelease ---------------------------------------------------
c_info "verifying repository index signature"
curl -fsSLo InRelease "$REPO_BASE/dists/stable/InRelease" || die "could not download InRelease"
gpg --batch --quiet --yes --output Release.verified --decrypt InRelease \
  || die "InRelease signature verification FAILED"
c_ok "InRelease signature valid"

# --- 3. verify Packages index ----------------------------------------------
IDX_PATH="main/binary-${DEB_ARCH}/Packages"
read -r IDX_SHA _ _ <<EOF
$(awk -v p="$IDX_PATH" '
    /^SHA256:/ {f=1; next}
    /^[^ ]/    {f=0}
    f && $3==p {print $1, $2, $3; exit}
  ' Release.verified)
EOF
[ -n "${IDX_SHA:-}" ] || die "index $IDX_PATH not listed in the signed InRelease"

curl -fsSLo Packages "$REPO_BASE/dists/stable/$IDX_PATH" || die "could not download Packages"
echo "$IDX_SHA  Packages" | sha256sum -c --quiet - || die "Packages checksum mismatch"
c_ok "package index verified"

# --- 4. pick newest package ------------------------------------------------
read -r VER FILENAME DEB_SHA <<EOF
$(awk -v RS='' -v pkg="$PKG_NAME" '
   {
     ver=""; fn=""; sha=""; name=""
     n=split($0, L, "\n")
     for (i=1;i<=n;i++) {
       if      (L[i] ~ /^Package: /)  { name=substr(L[i],10) }
       else if (L[i] ~ /^Version: /)  { ver =substr(L[i],10) }
       else if (L[i] ~ /^Filename: /) { fn  =substr(L[i],11) }
       else if (L[i] ~ /^SHA256: /)   { sha =substr(L[i],9)  }
     }
     if (name==pkg && ver!="" && fn!="" && sha!="") print ver"\t"fn"\t"sha
   }' Packages | sort -V | tail -n1)
EOF
[ -n "${VER:-}" ] || die "no $PKG_NAME package found for $DEB_ARCH"

c_info "installed: ${INSTALLED_VER:-none}   available: $VER"

if [ "$MODE" = "check" ]; then
  [ "$INSTALLED_VER" = "$VER" ] && c_ok "up to date" || c_warn "update available"
  exit 0
fi
if [ "$INSTALLED_VER" = "$VER" ] && [ "$MODE" = "install" ]; then
  c_ok "already up to date, nothing to do (use --force to reinstall)"
  exit 0
fi

# --- 5. download + verify the .deb -----------------------------------------
c_info "downloading $VER (~160 MB)"
curl -fL --progress-bar -o pkg.deb "$REPO_BASE/$FILENAME" || die "download failed"
echo "$DEB_SHA  pkg.deb" | sha256sum -c --quiet - || die "package checksum mismatch"
c_ok "package checksum verified"

# --- 6. extract .deb without dpkg ------------------------------------------
c_info "extracting"
TARS="$(python3 - "$TMP/pkg.deb" "$TMP" <<'PY'
import sys, os, re
deb, outdir = sys.argv[1], sys.argv[2]
data_path = control_path = None
with open(deb, 'rb') as f:
    if f.read(8) != b'!<arch>\n':
        sys.exit("not a valid .deb (ar) archive")
    while True:
        hdr = f.read(60)
        if len(hdr) < 60:
            break
        name = hdr[0:16].decode('ascii', 'replace').strip().rstrip('/')
        size = int(hdr[48:58].decode('ascii').strip())
        start = f.tell()
        if re.fullmatch(r'(data|control)\.tar(\.[a-z0-9]+)?', name):
            out = os.path.join(outdir, name)
            with open(out, 'wb') as o:
                left = size
                while left:
                    chunk = f.read(min(1 << 20, left))
                    if not chunk:
                        sys.exit("truncated archive")
                    o.write(chunk); left -= len(chunk)
            if name.startswith('data'):
                data_path = out
            else:
                control_path = out
        f.seek(start + size + (size % 2))
if not data_path or not control_path:
    sys.exit("data.tar or control.tar member not found in .deb")
print(data_path)
print(control_path)
PY
)" || die "could not unpack the .deb container"

DATA_TAR="${TARS%%$'\n'*}"
CONTROL_TAR="${TARS##*$'\n'}"

untar() {
  case "$1" in
    *.xz)  tar -xJf "$1" -C "$2" ;;
    *.gz)  tar -xzf "$1" -C "$2" ;;
    *.zst) need zstd; zstd -dc "$1" | tar -xf - -C "$2" ;;
    *.tar) tar -xf  "$1" -C "$2" ;;
    *) die "unknown compression: $1" ;;
  esac
}

# --- 6b. surface what dpkg would have done ---------------------------------
# Nothing here is ever executed. This install skips Depends resolution and the
# maintainer scripts, so changes to either need a human look at upgrade time.
report_package_meta() {
  local src="$1" dest="$META_DIR/$VER" prev="" f
  rm -rf "$dest"; mkdir -p "$dest"
  for f in control preinst postinst prerm postrm triggers conffiles; do
    if [ -f "$src/$f" ]; then
      cp "$src/$f" "$dest/$f"
      chmod 644 "$dest/$f"
    fi
  done
  awk '/^[A-Za-z-]+:/ { p = ($1 ~ /^(Pre-Depends|Depends|Recommends|Suggests|Conflicts|Breaks|Replaces|Provides):$/) } p' \
    "$dest/control" > "$dest/relations"

  c_info "package relations for $VER (not resolved by this installer):"
  sed 's/^/    /' "$dest/relations"
  c_info "maintainer scripts (never executed here):"
  for f in preinst postinst prerm postrm triggers; do
    [ -f "$dest/$f" ] && printf '    %s (%s lines)\n' "$f" "$(wc -l < "$dest/$f")"
  done
  c_info "saved to $dest"

  prev="$(find "$META_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
          | grep -vxF "$VER" | sort -V | tail -n1 || true)"
  if [ -z "$prev" ]; then
    c_warn "no earlier package metadata to compare; review the scripts in full:"
    for f in preinst postinst prerm postrm; do
      if [ -f "$dest/$f" ]; then
        printf -- '--- %s\n' "$f"
        cat "$dest/$f"
      fi
    done
  elif diff -ru --exclude=control "$META_DIR/$prev" "$dest"; then
    c_ok "relations and maintainer scripts unchanged since $prev"
  else
    c_warn "relations or maintainer scripts changed since $prev; review the diff above"
  fi
}

CTRL="$TMP/control"; mkdir -p "$CTRL"
untar "$CONTROL_TAR" "$CTRL"
[ -f "$CTRL/control" ] || die "control file missing from package"
report_package_meta "$CTRL"
[ "$MODE" = "inspect" ] && exit 0

ROOT="$TMP/root"; mkdir -p "$ROOT"
untar "$DATA_TAR" "$ROOT"
c_ok "payload extracted"

# --- 7. locate the Electron app root ---------------------------------------
ASAR="$(find "$ROOT" -type f -name 'app.asar' -path '*/resources/*' 2>/dev/null | head -n1 || true)"
if [ -n "$ASAR" ]; then
  APPDIR="$(dirname "$(dirname "$ASAR")")"
else
  APPDIR="$(find "$ROOT/usr/lib" "$ROOT/opt" -maxdepth 2 -type d -name '*laude*' 2>/dev/null | head -n1 || true)"
fi
[ -n "${APPDIR:-}" ] && [ -d "$APPDIR" ] || die "could not locate the application directory inside the package"

APPBIN=""
for cand in "$APPDIR"/claude-desktop "$APPDIR"/claude "$APPDIR"/Claude; do
  [ -f "$cand" ] && { APPBIN="$cand"; break; }
done
if [ -z "$APPBIN" ]; then
  APPBIN="$(find "$APPDIR" -maxdepth 1 -type f -perm -u+x \
            ! -name 'chrome-sandbox' ! -name '*.so*' ! -name '*.pak' ! -name '*.bin' \
            ! -name '*.json' ! -name '*.dat' 2>/dev/null | head -n1 || true)"
fi
[ -n "$APPBIN" ] || die "could not identify the main executable inside $APPDIR"
BINNAME="$(basename "$APPBIN")"
c_ok "app root: ${APPDIR#"$ROOT"}  (binary: $BINNAME)"

# --- 8. install into ~/.local ----------------------------------------------
mkdir -p "$VERSIONS" "$(dirname "$BIN")" "$(dirname "$DESKTOP_FILE")" "$ICON_ROOT"
TARGET="$VERSIONS/$VER"
rm -rf "$TARGET" "$TARGET.new"
cp -a "$APPDIR" "$TARGET.new"
chmod +x "$TARGET.new/$BINNAME" 2>/dev/null || true
mv "$TARGET.new" "$TARGET"
ln -sfn "$TARGET" "$CURRENT"
c_ok "installed to $TARGET"

# keep only the two most recent versions (rollback safety net)
# shellcheck disable=SC2012
ls -1 "$VERSIONS" | sort -V | head -n -2 | while read -r old; do
  [ "$old" = "$VER" ] || rm -rf "${VERSIONS:?}/$old"
done
# metadata follows the same retention as the versions it describes
for d in "$META_DIR"/*/; do
  [ -d "$d" ] || continue
  v="$(basename "$d")"
  [ -d "$VERSIONS/$v" ] || rm -rf "${META_DIR:?}/$v"
done

# --- 9. launcher wrapper ---------------------------------------------------
cat > "$BIN" <<WRAP
#!/usr/bin/env bash
# Generated by claude-desktop-userland.sh -- do not edit; it is overwritten.
set -euo pipefail
APP="\$HOME/.local/share/claude-desktop/current/$BINNAME"
[ -x "\$APP" ] || { echo "Claude Desktop is not installed correctly." >&2; exit 1; }

ARGS=()

# Namespace sandbox: chrome-sandbox is not setuid here (we never touch root),
# so Chromium must use unprivileged user namespaces instead.
if [ "\$(cat /proc/sys/user/max_user_namespaces 2>/dev/null || echo 0)" -lt 1 ]; then
  echo "WARNING: unprivileged user namespaces are disabled; the renderer sandbox" >&2
  echo "         cannot start. Set CLAUDE_NO_SANDBOX=1 to run unsandboxed (not advised)." >&2
fi
[ "\${CLAUDE_NO_SANDBOX:-0}" = "1" ] && ARGS+=(--no-sandbox)

# Native Wayland unless X11 is forced. Improves fractional scaling and input.
if [ "\${CLAUDE_FORCE_X11:-0}" != "1" ] && [ "\${XDG_SESSION_TYPE:-}" = "wayland" ]; then
  ARGS+=(--ozone-platform-hint=auto --enable-features=WaylandWindowDecorations)
fi

exec "\$APP" "\${ARGS[@]}" "\$@"
WRAP
chmod +x "$BIN"
c_ok "launcher: $BIN"

# --- 10. desktop entry + icons ---------------------------------------------
SRC_DESKTOP="$(find "$ROOT/usr/share/applications" -maxdepth 1 -name '*.desktop' 2>/dev/null | head -n1 || true)"
if [ -n "$SRC_DESKTOP" ]; then
  sed -E \
    -e "s|^Exec=[^ ]+|Exec=$BIN|" \
    -e "s|^TryExec=.*|TryExec=$BIN|" \
    "$SRC_DESKTOP" > "$DESKTOP_FILE"
else
  cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Name=Claude
Comment=Claude Desktop
Exec=$BIN %u
Icon=claude-desktop
Type=Application
Categories=Development;Utility;
StartupWMClass=Claude
MimeType=x-scheme-handler/claude;
EOF
  c_warn "package shipped no .desktop file; a minimal one was generated"
fi
grep -q '^TryExec=' "$DESKTOP_FILE" || printf 'TryExec=%s\n' "$BIN" >> "$DESKTOP_FILE"

if [ -d "$ROOT/usr/share/icons/hicolor" ]; then
  cp -a "$ROOT/usr/share/icons/hicolor/." "$ICON_ROOT/"
else
  find "$ROOT" -name '*.png' -path '*icon*' | head -n1 | while read -r i; do
    mkdir -p "$ICON_ROOT/256x256/apps"
    cp "$i" "$ICON_ROOT/256x256/apps/claude-desktop.png"
  done
fi

command -v update-desktop-database >/dev/null 2>&1 && \
  update-desktop-database "$(dirname "$DESKTOP_FILE")" 2>/dev/null || true
command -v gtk-update-icon-cache >/dev/null 2>&1 && \
  gtk-update-icon-cache -qtf "$ICON_ROOT" 2>/dev/null || true
c_ok "desktop entry and icons registered"

# --- 11. environment report ------------------------------------------------
echo
c_info "environment check"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) c_ok "$HOME/.local/bin is on PATH" ;;
  *) c_warn "$HOME/.local/bin is NOT on PATH; add it in your shell rc file" ;;
esac
if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
  c_ok "/dev/kvm accessible -> Cowork tab should work"
else
  c_warn "/dev/kvm not accessible -> the Cowork tab needs hardware virtualization"
fi
[ "$(cat /proc/sys/user/max_user_namespaces 2>/dev/null || echo 0)" -ge 1 ] \
  && c_ok "user namespaces enabled -> Chromium sandbox OK" \
  || c_warn "user namespaces disabled -> sandbox will fail"
[ "${XDG_SESSION_TYPE:-}" = "wayland" ] && c_info "Wayland session: launching with native Ozone backend"

echo
c_ok "Claude Desktop $VER installed. Launch it from GNOME, or run: claude-desktop"
c_info "To update later, just run this script again (it is idempotent)."
