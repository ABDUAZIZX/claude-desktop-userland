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

# Shell options are set in main(), so the file can be sourced by tests/ without
# changing the caller's shell.

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

# --- host compatibility checks ---------------------------------------------
# Everything dpkg + the maintainer scripts would have guaranteed, re-checked by
# hand: glibc floor, the namespace sandbox, shared libraries, session services.
# None of these checks modifies the system.

MIN_GLIBC="2.34"   # from the package's "Depends: libc6 (>= 2.34)"
AA_PROFILE_NAME="claude-desktop-userland"
AA_PROFILE_FILE="/etc/apparmor.d/$AA_PROFILE_NAME"
AA_SYSCTL="/proc/sys/kernel/apparmor_restrict_unprivileged_userns"

HOST_FAIL=0
h_fail() { c_err "$*"; HOST_FAIL=1; }

# deb | rpm | arch | suse | unknown -- only used to phrase install hints
os_family() {
  local ids=""
  # shellcheck disable=SC1091
  [ -r /etc/os-release ] && ids="$(. /etc/os-release; printf '%s %s' "${ID:-}" "${ID_LIKE:-}")"
  case " $ids " in
    *" debian "*|*" ubuntu "*)                     echo deb ;;
    *" suse "*|*" opensuse "*|*opensuse-*)         echo suse ;;
    *" fedora "*|*" rhel "*|*" centos "*)          echo rpm ;;
    *" arch "*)                                    echo arch ;;
    *)                                             echo unknown ;;
  esac
}

# Debian 13+ / Ubuntu 24.04+ renamed many library packages with a "t64"
# suffix (64-bit time_t transition). Older releases still use the plain name.
deb_uses_t64() {
  local id="" ver=""
  # shellcheck disable=SC1091
  [ -r /etc/os-release ] && { id="$(. /etc/os-release; echo "${ID:-}")"; ver="$(. /etc/os-release; echo "${VERSION_ID:-}")"; }
  case "$id" in
    ubuntu) [ "$(printf '%s\n24.04\n' "${ver:-0}" | sort -V | head -n1)" = "24.04" ] ;;
    debian) [ -z "$ver" ] || [ "${ver%%.*}" -ge 13 ] 2>/dev/null ;;   # empty VERSION_ID = testing/sid
    *)      return 0 ;;                                                # derivatives: assume current
  esac
}

# Name of the main executable inside an installed version directory.
installed_binname() {
  local cand
  for cand in claude-desktop claude Claude; do
    [ -f "$CURRENT/$cand" ] && { echo "$cand"; return 0; }
  done
  return 1
}

check_libc() {
  local v
  if [ -e /etc/NIXOS ]; then
    c_warn "NixOS detected: the upstream binary expects an FHS layout."
    c_warn "  enable programs.nix-ld (with the libraries reported below) or run it via steam-run"
  fi
  v="$(getconf GNU_LIBC_VERSION 2>/dev/null || true)"   # "glibc 2.39"
  v="${v##* }"
  if [ -z "$v" ]; then
    h_fail "glibc not found (musl-based system?); the upstream build needs glibc >= $MIN_GLIBC"
    c_info "  use a glibc distrobox/toolbox container instead"
    return 0
  fi
  if [ "$(printf '%s\n%s\n' "$MIN_GLIBC" "$v" | sort -V | head -n1)" = "$MIN_GLIBC" ]; then
    c_ok "glibc $v (>= $MIN_GLIBC)"
  else
    h_fail "glibc $v is older than the required $MIN_GLIBC (e.g. Debian 11, RHEL/Alma/Rocky 8)"
    c_info "  use a newer distribution, or a distrobox/toolbox container with glibc >= $MIN_GLIBC"
  fi
}

# aa_restricts_userns [sysctl-file]
# The sysctl only exists on Ubuntu kernels. A missing or unreadable file means
# "no restriction" and is not an error. Returns 0 only for the value 1.
aa_restricts_userns() {
  local f="${1:-$AA_SYSCTL}" v=""
  [ -r "$f" ] || return 1
  read -r v <"$f" 2>/dev/null || return 1
  [ "$v" = "1" ]
}

# aa_profile_present [profile-file]
# The profile file only proves intent; loading it needs root and cannot be
# verified from an unprivileged shell, so the messages say so.
aa_profile_present() {
  local f="${1:-$AA_PROFILE_FILE}"
  [ -f "$f" ] && grep -qF "$(aa_attach_path)" "$f" 2>/dev/null
}

# Shown wherever the sandbox cannot start because of the restriction.
# Order matters: the profile first, disabling the sandbox only as a last resort.
aa_remedies() {
  c_info "  options, in order of preference:"
  c_info "   1. load an AppArmor profile for this install:"
  c_info "      $0 --print-apparmor-profile   (prints it, the root commands, and its trade-off)"
  c_info "   2. last resort only: CLAUDE_NO_SANDBOX=1 claude-desktop"
  c_info "      this disables the Chromium sandbox entirely; web content is no longer isolated"
}

# Resolved path glob the profile attaches to. AppArmor matches the real path,
# so /home -> /var/home style symlinks must be resolved here.
aa_attach_path() {
  printf '%s/*/%s' "$(readlink -m "$VERSIONS")" "$(installed_binname || echo claude-desktop)"
}

print_apparmor_profile() {
  local attach
  attach="$(aa_attach_path)"
  case "$attach" in
    *'"'*|*'['*|*']'*|*'{'*|*'}'*|*'?'*)
      die "install path contains AppArmor glob characters; cannot write a safe profile: $attach" ;;
  esac
  [ -f /etc/apparmor.d/abi/4.0 ] || c_warn "/etc/apparmor.d/abi/4.0 not found: AppArmor < 4.0 does not restrict userns and needs no profile"
  cat >&2 <<WARN
WARNING: this profile weakens the user-namespace restriction for your account.
  It attaches to a path inside \$HOME that you can write to. Any code running
  with your privileges can place a binary at that path and will be allowed to
  create user namespaces, which is exactly what the restriction is meant to
  prevent. The official package attaches to a root-owned path under /usr and
  does not have this weakness.

WARN
  cat <<PROFILE
# Generated by claude-desktop-userland.sh $SELF_VERSION
# Allows the user-installed Claude Desktop to create user namespaces so the
# Chromium sandbox can start under kernel.apparmor_restrict_unprivileged_userns=1.
# Same form as Ubuntu's browser profiles and the official .deb's profile.
#
# WARNING: the attachment path below is writable by its owner. Any process
# running as that user can place a binary there and gain user namespaces,
# which weakens the restriction for that user.
abi <abi/4.0>,
include <tunables/global>

profile $AA_PROFILE_NAME "$attach" flags=(unconfined) {
  userns,

  include if exists <local/$AA_PROFILE_NAME>
}
PROFILE
  cat >&2 <<HOWTO

To install it (root required, review it first):
  $0 --print-apparmor-profile | sudo tee $AA_PROFILE_FILE >/dev/null
  sudo apparmor_parser -r $AA_PROFILE_FILE
To remove it:
  sudo apparmor_parser -R $AA_PROFILE_FILE && sudo rm $AA_PROFILE_FILE

If you will not load it, the only other option is the last resort:
  CLAUDE_NO_SANDBOX=1 claude-desktop
which disables the Chromium sandbox entirely, so web content is no longer
isolated from your session. That is a larger loss than the profile's.
HOWTO
}

# check_userns [apparmor-sysctl-file] [apparmor-profile-file]
check_userns() {
  local aa_sysctl="${1:-$AA_SYSCTL}" aa_profile="${2:-$AA_PROFILE_FILE}"
  if [ "$(cat /proc/sys/user/max_user_namespaces 2>/dev/null || echo 0)" -lt 1 ]; then
    h_fail "user namespaces disabled (user.max_user_namespaces=0): the renderer sandbox cannot start"
    return 0
  fi
  # Older Debian kernels carry their own switch
  if [ "$(cat /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null || echo 1)" = "0" ]; then
    h_fail "kernel.unprivileged_userns_clone=0: the renderer sandbox cannot start"
    c_info "  enable it with: sudo sysctl -w kernel.unprivileged_userns_clone=1 (persist in /etc/sysctl.d/)"
    return 0
  fi
  if aa_restricts_userns "$aa_sysctl"; then
    if aa_profile_present "$aa_profile"; then
      c_ok "AppArmor restricts user namespaces; profile $aa_profile present (load state needs root to verify)"
    else
      h_fail "AppArmor restricts unprivileged user namespaces (Ubuntu 24.04+): the renderer sandbox cannot start"
      aa_remedies
    fi
    return 0
  fi
  c_ok "unprivileged user namespaces available -> Chromium sandbox OK"
}

# Map a missing soname to package names: "deb|rpm|arch|suse".
lib_pkg() {
  case "$1" in
    libgtk-3.so.*)                       echo "libgtk-3-0t64|gtk3|gtk3|libgtk-3-0" ;;
    libgdk-3.so.*)                       echo "libgtk-3-0t64|gtk3|gtk3|libgtk-3-0" ;;
    libnss3.so|libnssutil3.so|libsmime3.so) echo "libnss3|nss|nss|mozilla-nss" ;;
    libnspr4.so|libplc4.so|libplds4.so)  echo "libnspr4|nspr|nspr|mozilla-nspr" ;;
    libnotify.so.*)                      echo "libnotify4|libnotify|libnotify|libnotify4" ;;
    libatspi.so.*)                       echo "libatspi2.0-0t64|at-spi2-core|at-spi2-core|libatspi0" ;;
    libatk-1.0.so.*)                     echo "libatk1.0-0t64|at-spi2-core|at-spi2-core|libatk-1_0-0" ;;
    libatk-bridge-2.0.so.*)              echo "libatk-bridge2.0-0t64|at-spi2-core|at-spi2-core|libatk-bridge-2_0-0" ;;
    libdrm.so.*)                         echo "libdrm2|libdrm|libdrm|libdrm2" ;;
    libgbm.so.*)                         echo "libgbm1|mesa-libgbm|mesa|libgbm1" ;;
    libxcb-dri3.so.*)                    echo "libxcb-dri3-0|libxcb|libxcb|libxcb-dri3-0" ;;
    libxkbcommon.so.*)                   echo "libxkbcommon0|libxkbcommon|libxkbcommon|libxkbcommon0" ;;
    libsecret-1.so.*)                    echo "libsecret-1-0|libsecret|libsecret|libsecret-1-0" ;;
    libXtst.so.*)                        echo "libxtst6|libXtst|libxtst|libXtst6" ;;
    libXcomposite.so.*)                  echo "libxcomposite1|libXcomposite|libxcomposite|libXcomposite1" ;;
    libXdamage.so.*)                     echo "libxdamage1|libXdamage|libxdamage|libXdamage1" ;;
    libXrandr.so.*)                      echo "libxrandr2|libXrandr|libxrandr|libXrandr2" ;;
    libXfixes.so.*)                      echo "libxfixes3|libXfixes|libxfixes|libXfixes3" ;;
    libX11.so.*|libxcb.so.*)             echo "libx11-6|libX11|libx11|libX11-6" ;;
    libXext.so.*)                        echo "libxext6|libXext|libxext|libXext6" ;;
    libuuid.so.*)                        echo "libuuid1|libuuid|util-linux-libs|libuuid1" ;;
    libasound.so.*)                      echo "libasound2t64|alsa-lib|alsa-lib|libasound2" ;;
    libcups.so.*)                        echo "libcups2t64|cups-libs|libcups|libcups2" ;;
    libpango-1.0.so.*)                   echo "libpango-1.0-0|pango|pango|libpango-1_0-0" ;;
    libcairo.so.*)                       echo "libcairo2|cairo|cairo|libcairo2" ;;
    libdbus-1.so.*)                      echo "libdbus-1-3|dbus-libs|dbus|libdbus-1-3" ;;
    libglib-2.0.so.*|libgio-2.0.so.*|libgobject-2.0.so.*|libgmodule-2.0.so.*)
                                         echo "libglib2.0-0t64|glib2|glib2|libglib-2_0-0" ;;
    libexpat.so.*)                       echo "libexpat1|expat|expat|libexpat1" ;;
    *)                                   echo "" ;;
  esac
}

check_libs() {
  local bin missing lib pkgs fam col list=""
  if ! bin="$(installed_binname)"; then
    c_info "application not installed yet; shared-library check skipped"
    return 0
  fi
  if [ -z "$(getconf GNU_LIBC_VERSION 2>/dev/null || true)" ]; then
    c_info "no glibc: shared-library check skipped (ldd output would be meaningless)"
    return 0
  fi
  if ! command -v ldd >/dev/null 2>&1; then
    c_warn "ldd not available; shared-library check skipped"
    return 0
  fi
  # The payload was verified before installation, so running ldd on it (which
  # invokes the dynamic loader) is not a trust problem here.
  missing="$(find "$CURRENT/" -maxdepth 1 -type f \
               \( -name "$bin" -o -name '*.so' -o -name '*.so.*' \) \
               -exec ldd {} \; 2>/dev/null \
             | awk '/=> not found/ {print $1}' | sort -u || true)"
  if [ -z "$missing" ]; then
    c_ok "all shared libraries resolve"
    return 0
  fi
  h_fail "missing shared libraries:"
  # shellcheck disable=SC2086  # sonames: no spaces or glob characters
  printf '    %s\n' $missing >&2
  fam="$(os_family)"
  case "$fam" in deb) col=1 ;; rpm) col=2 ;; arch) col=3 ;; suse) col=4 ;; *) col=0 ;; esac
  for lib in $missing; do
    pkgs="$(lib_pkg "$lib")"
    [ -n "$pkgs" ] && [ "$col" -gt 0 ] && list="$list $(printf '%s' "$pkgs" | cut -d'|' -f"$col")"
  done
  # shellcheck disable=SC2086
  list="$(printf '%s\n' $list | sort -u | tr '\n' ' ')"
  if [ "$fam" = deb ] && ! deb_uses_t64; then
    list="${list//t64/}"
  fi
  if [ -n "${list// /}" ]; then
    case "$fam" in
      deb)  c_info "  likely fix: sudo apt install $list" ;;
      rpm)  c_info "  likely fix: sudo dnf install $list" ;;
      arch) c_info "  likely fix: sudo pacman -S --needed $list" ;;
      suse) c_info "  likely fix: sudo zypper install $list" ;;
    esac
    c_info "  (on an atomic system, add them to your image or use a distrobox container)"
  else
    c_info "  install the packages that provide the libraries above"
  fi
}

# Name present on the session bus, running or D-Bus activatable.
# Returns 0 present, 1 absent, 2 cannot tell (no bus or no client tool).
bus_has_name() {
  local names
  if command -v busctl >/dev/null 2>&1; then
    names="$(busctl --user list --no-legend 2>/dev/null | awk '{print $1}')" || return 2
  elif command -v gdbus >/dev/null 2>&1; then
    names="$(
      for m in ListNames ListActivatableNames; do
        gdbus call --session --dest org.freedesktop.DBus \
          --object-path /org/freedesktop/DBus --method "org.freedesktop.DBus.$m" 2>/dev/null
      done | tr -s " ,[]()'" '\n')"
  else
    return 2
  fi
  [ -n "$names" ] || return 2
  grep -qxF "$1" <<<"$names"
}

check_session_services() {
  local rc=0
  bus_has_name org.freedesktop.secrets || rc=$?
  case "$rc" in
    0) c_ok "Secret Service available -> login is stored in the keyring" ;;
    1) c_warn "no Secret Service (gnome-keyring / KWallet / KeePassXC) on the session bus"
       c_info "  you will be asked to sign in on every launch; either install one, or"
       c_info "  set CLAUDE_PASSWORD_STORE=basic (token kept with weak obfuscation in ~/.config/Claude)" ;;
    *) c_info "session bus not reachable from here; Secret Service check skipped" ;;
  esac
  rc=0
  bus_has_name org.freedesktop.portal.Desktop || rc=$?
  case "$rc" in
    0) c_ok "xdg-desktop-portal available -> file pickers and screen sharing" ;;
    1) c_warn "xdg-desktop-portal not on the session bus: file dialogs and screen sharing may fail" ;;
    *) : ;;
  esac
}

check_misc() {
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) c_ok "$HOME/.local/bin is on PATH" ;;
    *) c_warn "$HOME/.local/bin is NOT on PATH; add it in your shell rc file" ;;
  esac
  # Cowork runs a VM and looks for QEMU/OVMF at fixed system paths; /dev/kvm alone is not enough.
  local qemu
  qemu="/usr/bin/qemu-system-$(uname -m)"
  if [ -r /dev/kvm ] && [ -w /dev/kvm ] && [ -x "$qemu" ] \
     && { [ -e /usr/share/OVMF/OVMF_CODE.fd ] || [ -e /usr/share/OVMF/OVMF_CODE_4M.fd ] || [ "$(uname -m)" != x86_64 ]; }; then
    c_ok "/dev/kvm and QEMU present -> the Cowork tab can start its VM"
  else
    c_info "Cowork tab unavailable: it needs /dev/kvm plus $qemu and OVMF under /usr (rest of the app unaffected)"
  fi
  [ "${XDG_SESSION_TYPE:-}" = "wayland" ] && c_info "Wayland session: the launcher uses the native Ozone backend"
  return 0
}

run_host_checks() {
  HOST_FAIL=0
  # A missing tool must stop the checks: an absent awk would otherwise turn
  # "libraries missing" into a silent "all resolve" (seen on openSUSE images).
  local t
  for t in getconf awk find sort grep cut readlink; do need "$t"; done
  check_libc
  check_userns
  check_libs
  check_session_services
  check_misc
}

# --- uninstall -------------------------------------------------------------
do_uninstall() {
  local purge="${1:-no}"
  rm -f  "$BIN" "$DESKTOP_FILE"
  find "$ICON_ROOT" -name 'claude-desktop.*' -delete 2>/dev/null || true
  rm -rf "$BASE"
  command -v update-desktop-database >/dev/null 2>&1 && \
    update-desktop-database "$(dirname "$DESKTOP_FILE")" 2>/dev/null || true
  c_ok "application removed"
  if [ -f "$AA_PROFILE_FILE" ]; then
    c_info "AppArmor profile left in place (root-owned); remove it with:"
    c_info "  sudo apparmor_parser -R $AA_PROFILE_FILE && sudo rm $AA_PROFILE_FILE"
  fi
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
  --doctor      check this host can run the app (glibc, sandbox, shared
                libraries, keyring, portals); offline, changes nothing
  --print-apparmor-profile
                print an AppArmor profile for Ubuntu 24.04+ hosts that
                restrict user namespaces, with install instructions
  --uninstall   remove the application, keep ~/.config/Claude
  --purge       remove the application and its configuration/data
  --help        this text
  --version     print the script version
USAGE
}

# --- argument parsing ------------------------------------------------------
parse_args() {
  MODE="install"
  case "${1:-}" in
    --uninstall)     MODE="uninstall" ;;
    --purge)         MODE="purge" ;;
    --check)         MODE="check" ;;
    --inspect)       MODE="inspect" ;;
    --force)         MODE="force" ;;
    --doctor)        MODE="doctor" ;;
    --print-apparmor-profile) MODE="apparmor" ;;
    -h|--help)       MODE="help" ;;
    -V|--version)    MODE="version" ;;
    "")              : ;;
    *)               usage >&2; die "unknown option: $1" ;;
  esac
}

run_doctor() {
  run_host_checks
  if [ "$HOST_FAIL" = 0 ]; then
    c_ok "host looks able to run Claude Desktop"
    return 0
  fi
  c_err "blocking problems found (see [fail] lines above)"
  return 1
}

step_preflight() {
# --- preflight -------------------------------------------------------------
for t in curl gpg sha256sum awk tar python3 find sed diff; do need "$t"; done

# Refuse before a 160 MB download on hosts that cannot load the binary at all.
# The remaining checks run after installation, when there is a binary to test.
if [ "$MODE" != "check" ] && [ "$MODE" != "inspect" ] && [ "${CLAUDE_SKIP_HOST_CHECK:-0}" != "1" ]; then
  check_libc
  [ "$HOST_FAIL" = 0 ] || die "this host cannot run the upstream build (override: CLAUDE_SKIP_HOST_CHECK=1)"
fi

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)  DEB_ARCH="amd64" ;;
  aarch64) DEB_ARCH="arm64" ;;
  *) die "unsupported architecture: $ARCH (Anthropic publishes amd64 and arm64 only)" ;;
esac

INSTALLED_VER=""
if [ -L "$CURRENT" ]; then
  INSTALLED_VER="$(basename "$(readlink -f "$CURRENT")")"
fi

}

step_fetch_verified_index() {
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
}

step_select_package() {
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

}

step_download_package() {
# --- 5. download + verify the .deb -----------------------------------------
c_info "downloading $VER (~160 MB)"
curl -fL --progress-bar -o pkg.deb "$REPO_BASE/$FILENAME" || die "download failed"
echo "$DEB_SHA  pkg.deb" | sha256sum -c --quiet - || die "package checksum mismatch"
c_ok "package checksum verified"
}

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

step_extract_package() {
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

CTRL="$TMP/control"; mkdir -p "$CTRL"
untar "$CONTROL_TAR" "$CTRL"
[ -f "$CTRL/control" ] || die "control file missing from package"
report_package_meta "$CTRL"
[ "$MODE" = "inspect" ] && return 0

ROOT="$TMP/root"; mkdir -p "$ROOT"
untar "$DATA_TAR" "$ROOT"
c_ok "payload extracted"
}

step_locate_app() {
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
}

step_install_payload() {
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
}

step_write_launcher() {
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
if [ "\${CLAUDE_NO_SANDBOX:-0}" != "1" ]; then
  if [ "\$(cat /proc/sys/user/max_user_namespaces 2>/dev/null || echo 0)" -lt 1 ] \\
     || [ "\$(cat /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null || echo 1)" = "0" ]; then
    echo "WARNING: unprivileged user namespaces are disabled; the renderer sandbox" >&2
    echo "         cannot start. Run: claude-desktop-userland.sh --doctor" >&2
  elif [ "\$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0)" = "1" ] \\
       && [ ! -f $AA_PROFILE_FILE ]; then
    echo "WARNING: AppArmor restricts user namespaces and no $AA_PROFILE_NAME profile" >&2
    echo "         is installed; the renderer sandbox will fail to start." >&2
    echo "         1. preferred: claude-desktop-userland.sh --print-apparmor-profile" >&2
    echo "         2. last resort: CLAUDE_NO_SANDBOX=1 (disables the sandbox entirely)" >&2
  fi
fi
[ "\${CLAUDE_NO_SANDBOX:-0}" = "1" ] && ARGS+=(--no-sandbox)

# Without a Secret Service (common on bare window managers) Chromium cannot
# persist the login. CLAUDE_PASSWORD_STORE=basic trades that for weak storage.
[ -n "\${CLAUDE_PASSWORD_STORE:-}" ] && ARGS+=("--password-store=\$CLAUDE_PASSWORD_STORE")

# Native Wayland unless X11 is forced. Improves fractional scaling and input.
if [ "\${CLAUDE_FORCE_X11:-0}" != "1" ] && [ "\${XDG_SESSION_TYPE:-}" = "wayland" ]; then
  ARGS+=(--ozone-platform-hint=auto --enable-features=WaylandWindowDecorations)
fi

exec "\$APP" "\${ARGS[@]}" "\$@"
WRAP
chmod +x "$BIN"
c_ok "launcher: $BIN"
}

step_write_desktop_entry() {
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
}

step_final_report() {
# --- 11. environment report ------------------------------------------------
echo
c_info "host check"
run_host_checks
echo
if [ "$HOST_FAIL" != 0 ]; then
  c_warn "Claude Desktop $VER installed, but the problems marked [fail] above will stop it from running"
  c_info "re-run with --doctor after fixing them"
  return 1
fi
c_ok "Claude Desktop $VER installed. Launch it from your app menu, or run: claude-desktop"
c_info "To update later, just run this script again (it is idempotent)."
}

# --- main ------------------------------------------------------------------
main() {
  set -euo pipefail
  umask 022
  parse_args "$@"
  case "$MODE" in
    uninstall) do_uninstall no ;;
    purge)     do_uninstall purge ;;
    doctor)    run_doctor; return ;;
    apparmor)  print_apparmor_profile; return 0 ;;
    help)      usage; return 0 ;;
    version)   printf '%s\n' "$SELF_VERSION"; return 0 ;;
  esac

  step_preflight
  TMP="$(mktemp -d -t claude-desktop.XXXXXXXX)"
  trap 'rm -rf "$TMP"' EXIT
  cd "$TMP"

  step_fetch_verified_index
  step_select_package
  if [ "$MODE" = "check" ]; then
    if [ "$INSTALLED_VER" = "$VER" ]; then c_ok "up to date"; else c_warn "update available"; fi
    return 0
  fi
  if [ "$INSTALLED_VER" = "$VER" ] && [ "$MODE" = "install" ]; then
    c_ok "already up to date, nothing to do (use --force to reinstall)"
    return 0
  fi

  step_download_package
  step_extract_package
  [ "$MODE" = "inspect" ] && return 0
  step_locate_app
  step_install_payload
  step_write_launcher
  step_write_desktop_entry
  step_final_report
}

# Run only when executed (directly, via bash, or piped); not when sourced.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
