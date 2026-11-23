#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# claude-desktop-userland.sh -- unofficial installer for the OFFICIAL package
#
# Installs Anthropic's signed Claude Desktop .deb into the user's home
# directory without dpkg, without root and without touching /usr. Built for
# atomic systems (bootc / rpm-ostree), usable on any Linux with glibc >= 2.34
# where vendor packages are unwanted in /usr. Not affiliated with Anthropic.
#
# Trust chain (nothing is trusted on faith, every step fails closed):
#   1. signing key downloaded, fingerprint compared to the pinned one
#   2. key imported into an ISOLATED keyring (your ~/.gnupg is untouched)
#   3. InRelease must be one clear-signed block; signature verified against
#      that keyring only
#   4. Date / Valid-Until read from the verified content: expired or future
#      index refused, and an index older than the last one verified refused
#   5. Packages index verified by SHA256 from the verified InRelease
#   6. version must be N(.N)*; a downgrade is refused
#   7. .deb verified by SHA256 from the verified Packages index
# Maintainer scripts are never executed. --allow-downgrade relaxes the two
# rollback checks only, never the signature or Valid-Until.
#
# Host checks (--doctor, and after every install): glibc floor, user
# namespaces incl. the Ubuntu 24.04+ AppArmor restriction, shared libraries
# resolved from ELF NEEDED entries without running the payload, Secret
# Service and xdg-desktop-portal.
#
# Everything lands under:
#   ~/.local/share/claude-desktop/versions/<version>/   app payload
#   ~/.local/share/claude-desktop/current               symlink (atomic swap)
#   ~/.local/share/claude-desktop/package-meta/<ver>/   control data, records
#   ~/.local/share/claude-desktop/state/                last verified index Date
#   ~/.local/bin/claude-desktop                         launcher
#   ~/.local/share/applications/claude-desktop.desktop  menu entry
#   ~/.local/share/icons/hicolor/...                    icons
#
# Options: run with --help (the README Usage section is the same text).
# Tests: bash tests/run.sh
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
STATE_DIR="$BASE/state"
RELEASE_DATE_STATE="$STATE_DIR/last-release-date"   # epoch of the newest verified index Date
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
# h_fail ID MESSAGE -- a host-check failure. ID is a fixed marker printed as
# "[fail:ID]" so tools (CI, scripts) can tell failures apart without parsing
# the prose, which may be reworded. IDs are listed in the README; keep them
# stable and lower-case ([a-z0-9-]).
h_fail() {
  local id="$1"; shift
  printf '\033[31m[fail:%s]\033[0m %s\n' "$id" "$*" >&2
  HOST_FAIL=1
}

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

# Name of the main executable inside an installed version directory.
installed_binname() {
  local cand
  for cand in claude-desktop claude Claude; do
    [ -f "$CURRENT/$cand" ] && { echo "$cand"; return 0; }
  done
  return 1
}

# check_libc [skip-floor]
# With "skip-floor" (--skip-host-check) only the version floor becomes a
# warning; a host without glibc (musl) is refused regardless, and the NixOS
# warning is always shown.
check_libc() {
  local skip="${1:-}" v
  GLIBC_FLOOR_SKIPPED=0
  GLIBC_SEEN=""
  if [ -e /etc/NIXOS ]; then
    c_warn "NixOS detected: the upstream binary expects an FHS layout."
    c_warn "  enable programs.nix-ld (with the libraries reported below) or run it via steam-run"
  fi
  v="$(getconf GNU_LIBC_VERSION 2>/dev/null || true)"   # "glibc 2.39"
  v="${v##* }"
  GLIBC_SEEN="$v"
  if [ -z "$v" ]; then
    h_fail glibc-missing "glibc not found (musl-based system?); the upstream build needs glibc >= $MIN_GLIBC"
    c_info "  use a glibc distrobox/toolbox container instead"
    return 0
  fi
  if [ "$(printf '%s\n%s\n' "$MIN_GLIBC" "$v" | sort -V | head -n1)" = "$MIN_GLIBC" ]; then
    c_ok "glibc $v (>= $MIN_GLIBC)"
  else
    if [ "$skip" = skip-floor ]; then
      GLIBC_FLOOR_SKIPPED=1
      c_warn "glibc $v is older than the required $MIN_GLIBC; continuing because of --skip-host-check"
      c_warn "  the app will most likely fail to start on this host"
    else
      h_fail glibc-too-old "glibc $v is older than the required $MIN_GLIBC (e.g. Debian 11, RHEL/Alma/Rocky 8)"
      c_info "  use a newer distribution, or a distrobox/toolbox container with glibc >= $MIN_GLIBC"
    fi
  fi
}

# aa_restricts_userns [sysctl-file]
# The sysctl only exists on Ubuntu kernels. A missing or unreadable file means
# "no restriction" and is not an error. Returns 0 only for the value 1.
# --- record of a skipped host check -------------------------------------------
SKIP_RECORD_NAME="host-check-skipped"

# record_host_check_skip META-VERSION-DIR GLIBC FLOOR-VIOLATED(0|1)
record_host_check_skip() {
  mkdir -p "$1"
  {
    printf 'option=--skip-host-check\n'
    printf 'glibc=%s\n' "${2:-unknown}"
    printf 'required=%s\n' "$MIN_GLIBC"
    printf 'floor_violated=%s\n' "$3"
    printf 'recorded=%s\n' "$(date -u '+%F %T UTC')"
  } >"$1/$SKIP_RECORD_NAME"
  chmod 644 "$1/$SKIP_RECORD_NAME"
}

# check_host_check_record [meta-dir] [current-link]
# Part of the glibc section of --doctor and the post-install check: an install
# made with --skip-host-check is reported as a glibc failure until the version
# is reinstalled without the option. Not used by the pre-download check, so a
# normal upgrade can still clear the record.
check_host_check_record() {
  local meta="${1:-$META_DIR}" cur="${2:-$CURRENT}" ver rec glibc
  [ -L "$cur" ] || return 0
  ver="$(basename "$(readlink -f "$cur")")"
  rec="$meta/$ver/$SKIP_RECORD_NAME"
  [ -f "$rec" ] || return 0
  glibc="$(sed -n 's/^glibc=//p' "$rec")"
  h_fail glibc-check-skipped "glibc check: $ver was installed with --skip-host-check (glibc ${glibc:-unknown} at install time, required $MIN_GLIBC)"
  c_info "  record: $rec"
  if [ "$(sed -n 's/^floor_violated=//p' "$rec")" = 1 ]; then
    c_info "  once glibc >= $MIN_GLIBC, reinstall without the option (--force) to clear it"
  else
    c_info "  the floor was met at install time; reinstall without the option (--force) to clear it"
  fi
}

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
    h_fail userns-disabled "user namespaces disabled (user.max_user_namespaces=0): the renderer sandbox cannot start"
    return 0
  fi
  # Older Debian kernels carry their own switch
  if [ "$(cat /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null || echo 1)" = "0" ]; then
    h_fail userns-clone-disabled "kernel.unprivileged_userns_clone=0: the renderer sandbox cannot start"
    c_info "  enable it with: sudo sysctl -w kernel.unprivileged_userns_clone=1 (persist in /etc/sysctl.d/)"
    return 0
  fi
  if aa_restricts_userns "$aa_sysctl"; then
    if aa_profile_present "$aa_profile"; then
      c_ok "AppArmor restricts user namespaces; profile $aa_profile present (load state needs root to verify)"
    else
      h_fail apparmor-userns "AppArmor restricts unprivileged user namespaces (Ubuntu 24.04+): the renderer sandbox cannot start"
      aa_remedies
    fi
    return 0
  fi
  c_ok "unprivileged user namespaces available -> Chromium sandbox OK"
}

# --- shared libraries ---------------------------------------------------------
# The payload is never executed or loaded for this check: NEEDED entries are
# read from the ELF dynamic section and resolved the way the loader would,
# first through RUNPATH/RPATH ($ORIGIN = the file's own directory), then the
# system cache from ldconfig -p.

# Parse "readelf -d" output from stdin into "NEEDED x" / "RUNPATH y" lines.
parse_readelf_dynamic() {
  sed -nE 's/.*\((NEEDED|RUNPATH|RPATH)\)[^[]*\[(.*)\]$/\1 \2/p'
}

# Parse "objdump -p" output from stdin into the same form.
parse_objdump_dynamic() {
  awk '$1=="NEEDED" || $1=="RUNPATH" || $1=="RPATH" {print $1, $2}'
}

# elf_dynamic FILE -- prints NEEDED/RUNPATH/RPATH lines; returns 2 when neither
# readelf nor objdump is available.
elf_dynamic() {
  if command -v readelf >/dev/null 2>&1; then
    LC_ALL=C readelf -d -W "$1" 2>/dev/null | parse_readelf_dynamic
  elif command -v objdump >/dev/null 2>&1; then
    LC_ALL=C objdump -p "$1" 2>/dev/null | parse_objdump_dynamic
  else
    return 2
  fi
}

# ldconfig is often outside an unprivileged PATH.
find_ldconfig() {
  local c
  for c in "$(command -v ldconfig 2>/dev/null || true)" /sbin/ldconfig /usr/sbin/ldconfig; do
    [ -n "$c" ] && [ -x "$c" ] && { echo "$c"; return 0; }
  done
  return 1
}

# ld_cache_sonames LDCONFIG MACHINE -- sonames in the cache for this machine.
# Only entries tagged with the matching ABI count; a 32-bit copy of a library
# does not satisfy a 64-bit binary.
ld_cache_sonames() {
  local tag
  case "$2" in
    x86_64)  tag="x86-64" ;;
    aarch64) tag="AArch64" ;;
    *)       tag="$2" ;;
  esac
  # The parenthesised field is a comma list, e.g. "(libc6,x86-64)" or, on
  # glibc 2.35, "(libc6,x86-64, OS ABI: Linux 3.2.0)". Match one exact element.
  "$1" -p 2>/dev/null | awk -v tag="$tag" '
    match($0, /\([^)]*\)/) {
      n = split(substr($0, RSTART + 1, RLENGTH - 2), f, ",")
      for (i = 1; i <= n; i++) { gsub(/^ +| +$/, "", f[i]); if (f[i] == tag) { print $1; next } }
    }' | sort -u
}

# resolve_soname SONAME ORIGIN-DIR RUNPATHS CACHE
#   RUNPATHS: colon-separated, may contain $ORIGIN / ${ORIGIN}
#   CACHE:    newline-separated sonames from ld_cache_sonames
resolve_soname() {
  local so="$1" origin="$2" runpaths="$3" cache="$4" dir
  local IFS=':'
  for dir in $runpaths; do
    [ -n "$dir" ] || continue
    dir="${dir//\$\{ORIGIN\}/$origin}"
    dir="${dir//\$ORIGIN/$origin}"
    [ -e "$dir/$so" ] && return 0
  done
  grep -qxF -- "$so" <<<"$cache"
}

# Electron's direct NEEDED set -> "deb|rpm|arch|suse". Debian-family entries may
# list alternatives "new/old"; deb_pick_name chooses using apt-cache.
lib_pkg() {
  case "$1" in
    libglib-2.0.so.0)       echo "libglib2.0-0t64/libglib2.0-0|glib2|glib2|libglib-2_0-0" ;;
    libgobject-2.0.so.0)    echo "libglib2.0-0t64/libglib2.0-0|glib2|glib2|libgobject-2_0-0" ;;
    libgio-2.0.so.0)        echo "libglib2.0-0t64/libglib2.0-0|glib2|glib2|libgio-2_0-0" ;;
    libnspr4.so)            echo "libnspr4|nspr|nspr|mozilla-nspr" ;;
    libnss3.so|libnssutil3.so|libsmime3.so)
                            echo "libnss3|nss|nss|mozilla-nss" ;;
    libatk-1.0.so.0)        echo "libatk1.0-0t64/libatk1.0-0|at-spi2-core|at-spi2-core|libatk-1_0-0" ;;
    libatk-bridge-2.0.so.0) echo "libatk-bridge2.0-0t64/libatk-bridge2.0-0|at-spi2-core|at-spi2-core|libatk-bridge-2_0-0" ;;
    libatspi.so.0)          echo "libatspi2.0-0t64/libatspi2.0-0|at-spi2-core|at-spi2-core|libatspi0" ;;
    libcups.so.2)           echo "libcups2t64/libcups2|cups-libs|libcups|libcups2" ;;
    libdbus-1.so.3)         echo "libdbus-1-3|dbus-libs|dbus|libdbus-1-3" ;;
    libcairo.so.2)          echo "libcairo2|cairo|cairo|libcairo2" ;;
    libgtk-3.so.0)          echo "libgtk-3-0t64/libgtk-3-0|gtk3|gtk3|libgtk-3-0" ;;
    libpango-1.0.so.0)      echo "libpango-1.0-0|pango|pango|libpango-1_0-0" ;;
    libX11.so.6)            echo "libx11-6|libX11|libx11|libX11-6" ;;
    libxcb.so.1)            echo "libxcb1|libxcb|libxcb|libxcb1" ;;
    libXcomposite.so.1)     echo "libxcomposite1|libXcomposite|libxcomposite|libXcomposite1" ;;
    libXdamage.so.1)        echo "libxdamage1|libXdamage|libxdamage|libXdamage1" ;;
    libXext.so.6)           echo "libxext6|libXext|libxext|libXext6" ;;
    libXfixes.so.3)         echo "libxfixes3|libXfixes|libxfixes|libXfixes3" ;;
    libXrandr.so.2)         echo "libxrandr2|libXrandr|libxrandr|libXrandr2" ;;
    libgbm.so.1)            echo "libgbm1|mesa-libgbm|mesa|libgbm1" ;;
    libexpat.so.1)          echo "libexpat1|expat|expat|libexpat1" ;;
    libxkbcommon.so.0)      echo "libxkbcommon0|libxkbcommon|libxkbcommon|libxkbcommon0" ;;
    libudev.so.1)           echo "libudev1|systemd-libs|systemd-libs|libudev1" ;;
    libasound.so.2)         echo "libasound2t64/libasound2|alsa-lib|alsa-lib|libasound2" ;;
    libgcc_s.so.1)          echo "libgcc-s1|libgcc|gcc-libs|libgcc_s1" ;;
    *)                      return 1 ;;
  esac
}

# deb_pick_name "a/b/c" [apt-cache-command]
# First alternative apt-cache knows (the t64 rename differs between Ubuntu
# 24.04+/Debian 13 and older releases). Returns 1 with the last alternative
# when none could be confirmed (no apt-cache, or empty package lists).
deb_pick_name() {
  local alts="$1" cache_cmd="${2:-apt-cache}" a last=""
  local IFS='/'
  for a in $alts; do
    last="$a"
    if command -v "$cache_cmd" >/dev/null 2>&1 \
       && "$cache_cmd" show --no-all-versions "$a" >/dev/null 2>&1; then
      echo "$a"; return 0
    fi
  done
  echo "$last"
  return 1
}

# Command that finds the package owning a soname, per family.
lib_search_cmd() {
  case "$2" in
    deb)  echo "apt-file search $1" ;;
    rpm)  echo "dnf provides '*/$1'" ;;
    arch) echo "pacman -F $1" ;;
    suse) echo "zypper se --provides --match-exact '$1()(64bit)'" ;;
    *)    echo "search your distribution's package index for $1" ;;
  esac
}

# check_libs [app-dir] [machine] -- defaults: the installed version, uname -m
check_libs() {
  local dir="${1:-$CURRENT}" machine="${2:-$(uname -m)}"
  local bin f ldc cache dyn needed runpaths so missing="" fam col pkgs name list="" unconfirmed="" unmapped=""
  if ! bin="$(CURRENT="$dir" installed_binname)"; then
    c_info "application not installed yet; shared-library check skipped"
    return 0
  fi
  if [ -z "$(getconf GNU_LIBC_VERSION 2>/dev/null || true)" ]; then
    c_info "no glibc: shared-library check skipped"
    return 0
  fi
  if ! command -v readelf >/dev/null 2>&1 && ! command -v objdump >/dev/null 2>&1; then
    c_warn "neither readelf nor objdump found; shared-library check skipped (install binutils)"
    return 0
  fi
  if ! ldc="$(find_ldconfig)"; then
    c_warn "ldconfig not found (PATH, /sbin, /usr/sbin); shared-library check skipped"
    return 0
  fi
  cache="$(ld_cache_sonames "$ldc" "$machine")"

  for f in "$dir/$bin" "$dir"/*.so "$dir"/*.so.*; do
    [ -f "$f" ] || continue
    dyn="$(elf_dynamic "$f")" || true
    needed="$(awk '$1=="NEEDED" {print $2}' <<<"$dyn")"
    runpaths="$(awk '$1=="RUNPATH" || $1=="RPATH" {printf "%s:", $2}' <<<"$dyn")"
    for so in $needed; do
      resolve_soname "$so" "$(dirname "$f")" "$runpaths" "$cache" || missing="$missing $so"
    done
  done
  # shellcheck disable=SC2086  # sonames: no spaces or glob characters
  missing="$(printf '%s\n' $missing | sort -u | sed '/^$/d')"
  if [ -z "$missing" ]; then
    c_ok "all shared libraries resolve (readelf + ldconfig cache, nothing executed)"
    return 0
  fi

  h_fail missing-libs "missing shared libraries:"
  printf '    %s\n' $missing >&2
  fam="$(os_family)"
  case "$fam" in deb) col=1 ;; rpm) col=2 ;; arch) col=3 ;; suse) col=4 ;; *) col=0 ;; esac
  for so in $missing; do
    if [ "$col" -gt 0 ] && pkgs="$(lib_pkg "$so")"; then
      name="$(cut -d'|' -f"$col" <<<"$pkgs")"
      if [ "$fam" = deb ]; then
        name="$(deb_pick_name "$name")" || unconfirmed="$unconfirmed $name"
      fi
      list="$list $name"
    else
      unmapped="$unmapped $so"
    fi
  done
  # shellcheck disable=SC2086
  list="$(printf '%s\n' $list | sort -u | sed '/^$/d' | tr '\n' ' ')"
  if [ -n "${list// /}" ]; then
    case "$fam" in
      deb)  c_info "  likely fix: sudo apt install $list" ;;
      rpm)  c_info "  likely fix: sudo dnf install $list" ;;
      arch) c_info "  likely fix: sudo pacman -S --needed $list" ;;
      suse) c_info "  likely fix: sudo zypper install $list" ;;
    esac
    if [ -n "$unconfirmed" ]; then
      # shellcheck disable=SC2086  # package names: no spaces or glob characters
      unconfirmed="$(printf '%s\n' $unconfirmed | sort -u | tr '\n' ' ')"
      c_info "  apt-cache could not confirm: $unconfirmed(run 'sudo apt update' and re-check)"
    fi
    c_info "  (on an atomic system, add them to your image or use a distrobox container)"
  fi
  for so in $unmapped; do
    c_info "  $so: not in the known list; find its package with: $(lib_search_cmd "$so" "$fam")"
  done
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
  check_host_check_record
  check_userns
  check_libs
  check_session_services
  check_misc
}

# --- repository freshness ----------------------------------------------------
# Every field read here comes from gpg's output (Release.verified), never from
# the raw InRelease: text outside the signed block is not trusted.

RELEASE_MAX_FUTURE=600   # seconds a Date may lie ahead of the local clock

# inrelease_well_formed FILE -- exactly one clear-signed block and nothing
# outside it, so no unsigned text can sit next to the signed content.
inrelease_well_formed() {
  local f="$1" first last
  first="$(head -n1 "$f")"
  last="$(sed '/^[[:space:]]*$/d' "$f" | tail -n1)"
  [ "$first" = "-----BEGIN PGP SIGNED MESSAGE-----" ] \
    && [ "$last" = "-----END PGP SIGNATURE-----" ] \
    && [ "$(grep -c '^-----BEGIN PGP SIGNED MESSAGE-----$' "$f")" = 1 ] \
    && [ "$(grep -c '^-----BEGIN PGP SIGNATURE-----$' "$f")" = 1 ] \
    && [ "$(grep -c '^-----END PGP SIGNATURE-----$' "$f")" = 1 ]
}

# release_field FILE FIELD -- value from the first paragraph of a Release file
release_field() {
  awk -v f="$2" '
    /^[[:space:]]*$/ { exit }
    index($0, f ":") == 1 { v = substr($0, length(f) + 2); sub(/^[ \t]+/, "", v); print v; exit }
  ' "$1"
}

# to_epoch "Sat, 21 Nov 2026 21:15:46 +0000" -> seconds (GNU date)
to_epoch() {
  local e
  e="$(date -u -d "$1" +%s 2>/dev/null)" || return 1
  [[ "$e" =~ ^[0-9]+$ ]] || return 1
  echo "$e"
}

# check_release_validity DATE-EPOCH VALID-UNTIL-EPOCH NOW-EPOCH
check_release_validity() {
  local date_e="$1" valid_e="$2" now="$3"
  if [ "$now" -gt "$valid_e" ]; then
    c_err "repository index expired: Valid-Until is $(date -u -d "@$valid_e" '+%F %T UTC'), now $(date -u -d "@$now" '+%F %T UTC')"
    c_err "  a stale signed index can hide newer releases (replay); refusing"
    return 1
  fi
  if [ "$date_e" -gt $((now + RELEASE_MAX_FUTURE)) ]; then
    c_err "repository index Date $(date -u -d "@$date_e" '+%F %T UTC') is more than $((RELEASE_MAX_FUTURE / 60)) minutes in the future"
    c_err "  check the system clock; refusing"
    return 1
  fi
  return 0
}

# verify_release_freshness VERIFIED-RELEASE NOW-EPOCH
# Sets RELEASE_DATE_EPOCH for later steps. Missing fields fail closed.
verify_release_freshness() {
  local f="$1" now="$2" d v
  d="$(release_field "$f" Date)"
  v="$(release_field "$f" Valid-Until)"
  [ -n "$d" ] || { c_err "signed index has no Date field"; return 1; }
  [ -n "$v" ] || { c_err "signed index has no Valid-Until field"; return 1; }
  RELEASE_DATE_EPOCH="$(to_epoch "$d")" || { c_err "cannot parse Date: $d"; return 1; }
  local valid_e
  valid_e="$(to_epoch "$v")" || { c_err "cannot parse Valid-Until: $v"; return 1; }
  check_release_validity "$RELEASE_DATE_EPOCH" "$valid_e" "$now" || return 1
  c_ok "index fresh: Date $d, valid until $v"
}

# valid_version STRING -- digits separated by single dots, nothing else.
# The repository version becomes a path component (versions/<ver>, removed
# with rm -rf; package-meta/<ver>) and is ordered with sort -V, so anything
# else ("../x", "1.0~rc1", "1:2.0", empty) is refused rather than sanitised.
valid_version() {
  [[ "$1" =~ ^[0-9]+(\.[0-9]+)*$ ]]
}

# version_lt A B -- true when A sorts strictly before B (sort -V)
version_lt() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]
}

# check_version_order INSTALLED AVAILABLE ALLOW-DOWNGRADE(0|1)
# Refuses an available version older than the installed one unless allowed.
# --allow-downgrade never bypasses the signature or Valid-Until checks.
check_version_order() {
  local inst="$1" avail="$2" allow="$3"
  [ -n "$inst" ] || return 0
  version_lt "$avail" "$inst" || return 0
  if [ "$allow" = 1 ]; then
    c_warn "DOWNGRADE: installing $avail over $inst (--allow-downgrade)"
    return 0
  fi
  c_err "the repository offers $avail, older than the installed $inst"
  c_err "  a signed but older index can be a rollback attack; refusing"
  c_info "  if this is intended (e.g. upstream pulled a release), re-run with --allow-downgrade"
  return 1
}

# read_saved_release_date STATE-FILE -- prints the saved epoch, empty if none.
# A corrupt file fails closed rather than silently resetting the floor.
read_saved_release_date() {
  local f="$1" v=""
  [ -e "$f" ] || return 0
  read -r v <"$f" || true
  if ! [[ "$v" =~ ^[0-9]+$ ]]; then
    c_err "state file $f is corrupt (expected an epoch); delete it to reset the Date floor"
    return 1
  fi
  echo "$v"
}

# check_date_floor DATE-EPOCH STATE-FILE ALLOW-DOWNGRADE(0|1)
# Refuses an index whose Date is older than the newest one already verified.
check_date_floor() {
  local date_e="$1" state="$2" allow="$3" saved
  saved="$(read_saved_release_date "$state")" || return 1
  [ -n "$saved" ] || return 0
  [ "$date_e" -lt "$saved" ] || return 0
  if [ "$allow" = 1 ]; then
    c_warn "OLDER INDEX: Date $(date -u -d "@$date_e" '+%F %T UTC') is older than the last verified $(date -u -d "@$saved" '+%F %T UTC') (--allow-downgrade)"
    return 0
  fi
  c_err "repository index Date $(date -u -d "@$date_e" '+%F %T UTC') is older than the last verified $(date -u -d "@$saved" '+%F %T UTC')"
  c_err "  an older signed index can be a rollback attack; refusing"
  c_info "  if this is intended, re-run with --allow-downgrade"
  return 1
}

# save_release_date STATE-FILE DATE-EPOCH -- keeps the maximum, written atomically.
# Called right after the signed InRelease (Date, Valid-Until, floor) and the
# Packages index it pins have both verified, in every mode that fetches the
# index: install, --force, --check, --inspect, and when already up to date.
# Never on an index that failed verification, and never moves backwards (even
# with --allow-downgrade).
save_release_date() {
  local f="$1" new="$2" saved
  saved="$(read_saved_release_date "$f")" || return 1
  if [ -n "$saved" ] && [ "$saved" -ge "$new" ]; then
    return 0
  fi
  mkdir -p "$(dirname "$f")"
  printf '%s\n' "$new" >"$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"
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

# --- rollback ----------------------------------------------------------------
# rollback_switch -- point "current" at the other retained version. Offline:
# nothing is downloaded or fetched, so the Date floor and the downgrade check
# (which guard what the repository serves) are not involved. Sets ROLLBACK_FROM
# and ROLLBACK_TO. Refuses, changing nothing, when there is no other version,
# when its name is not N(.N)*, or when it lacks the binary the launcher runs.
rollback_switch() {
  local from to bin d v others=""
  ROLLBACK_FROM=""; ROLLBACK_TO=""
  [ -L "$CURRENT" ] || die "nothing installed ($CURRENT missing); nothing to roll back"
  from="$(basename "$(readlink -f "$CURRENT")")"
  for d in "$VERSIONS"/*/; do
    [ -d "$d" ] || continue
    v="$(basename "$d")"
    [ "$v" = "$from" ] || others="$others$v"$'\n'
  done
  others="$(printf '%s' "$others" | sed '/^$/d')"
  [ -n "$others" ] || die "only $from is installed; there is no previous version to roll back to"
  # Retention keeps two versions, so there is one other; if more were left by
  # hand, the newest of them is taken.
  to="$(printf '%s\n' "$others" | sort -V | tail -n1)"
  valid_version "$to" \
    || die "retained version $(printf '%q' "$to") is not of the form N(.N)*; refusing to switch to it"
  # The launcher runs current/<binary>; the target must have that binary.
  bin="$(sed -n 's|^APP="\$HOME/\.local/share/claude-desktop/current/\(.*\)"$|\1|p' "$BIN" 2>/dev/null || true)"
  [ -n "$bin" ] || bin="$(CURRENT="$VERSIONS/$from" installed_binname || true)"
  [ -n "$bin" ] || die "cannot tell which binary the launcher runs; reinstall with --force"
  [ -f "$VERSIONS/$to/$bin" ] && [ -x "$VERSIONS/$to/$bin" ] \
    || die "version $to is incomplete ($bin missing or not executable); refusing to switch to it"
  # Replace the link in one rename, so "current" never dangles.
  ln -sfn "$VERSIONS/$to" "$CURRENT.rollback"
  mv -fT "$CURRENT.rollback" "$CURRENT"
  ROLLBACK_FROM="$from"; ROLLBACK_TO="$to"
}

# do_rollback -- --rollback: switch, report, then the same host check as after
# an install (including a host-check-skipped record of the version switched to).
do_rollback() {
  rollback_switch
  c_ok "rolled back: $ROLLBACK_FROM -> $ROLLBACK_TO"
  c_info "$ROLLBACK_FROM stays on disk. A plain run of this script installs the newest"
  c_info "repository version again; --rollback pins nothing."
  c_info "A Claude Desktop that is already running keeps the old version until restarted."
  echo
  c_info "host check"
  run_host_checks
  echo
  if [ "$HOST_FAIL" != 0 ]; then
    c_warn "rolled back to $ROLLBACK_TO, but the problems marked [fail:...] above will stop it from running"
    return 1
  fi
  c_ok "Claude Desktop $ROLLBACK_TO is now the active version"
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
  --rollback    switch back to the previous version kept on disk; offline,
                pins nothing (the next plain run installs the newest again)
  --allow-downgrade
                modifier: accept a repository version older than the one
                installed, and an index Date older than the last one
                verified (with a warning). Never bypasses the signature or
                Valid-Until checks
  --skip-host-check
                modifier for install and --force: continue when glibc is
                older than $MIN_GLIBC (the version floor only). It does NOT
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
USAGE
}

# --- argument parsing ------------------------------------------------------
# One mode option at most, plus the --allow-downgrade / --skip-host-check modifiers.
parse_args() {
  MODE="install"
  ALLOW_DOWNGRADE=0
  SKIP_HOST_CHECK=0
  local seen="" m
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --allow-downgrade) ALLOW_DOWNGRADE=1; shift; continue ;;
      --skip-host-check) SKIP_HOST_CHECK=1; shift; continue ;;
      --uninstall)     m="uninstall" ;;
      --purge)         m="purge" ;;
      --check)         m="check" ;;
      --inspect)       m="inspect" ;;
      --force)         m="force" ;;
      --rollback)      m="rollback" ;;
      --doctor)        m="doctor" ;;
      --print-apparmor-profile) m="apparmor" ;;
      -h|--help)       m="help" ;;
      -V|--version)    m="version" ;;
      *)               usage >&2; die "unknown option: $1" ;;
    esac
    [ -z "$seen" ] || die "options $seen and $1 cannot be combined"
    seen="$1"; MODE="$m"; shift
  done
  if [ "$ALLOW_DOWNGRADE" = 1 ]; then
    case "$MODE" in
      install|force|check|inspect) : ;;
      *) die "--allow-downgrade only applies to install, --force, --check and --inspect" ;;
    esac
  fi
  if [ "$SKIP_HOST_CHECK" = 1 ]; then
    case "$MODE" in
      install|force) : ;;
      *) die "--skip-host-check only applies to install and --force" ;;
    esac
  fi
}

run_doctor() {
  run_host_checks
  if [ "$HOST_FAIL" = 0 ]; then
    c_ok "host looks able to run Claude Desktop"
    return 0
  fi
  c_err "blocking problems found (see [fail:...] lines above)"
  return 1
}

step_preflight() {
# --- preflight -------------------------------------------------------------
for t in curl sha256sum awk find sed diff grep; do need "$t"; done
GPG="$(pick_gpg)" || die "missing required tool: gpg (or gpg2)"
AR_TOOL="$(pick_ar_tool)" || die "need one of bsdtar (libarchive), ar (binutils) or python3 to unpack the .deb"

# Refuse before a 160 MB download on hosts that cannot load the binary at all.
# The remaining checks run after installation, when there is a binary to test.
if [ "$MODE" != "check" ] && [ "$MODE" != "inspect" ]; then
  if [ "$SKIP_HOST_CHECK" = 1 ]; then
    check_libc skip-floor
    [ "$HOST_FAIL" = 0 ] || die "this host cannot run the upstream build (--skip-host-check does not cover a missing glibc)"
  else
    check_libc
    [ "$HOST_FAIL" = 0 ] || die "this host cannot run the upstream build (glibc too old? see --skip-host-check)"
  fi
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

GOT_FPR="$("$GPG" --with-colons --show-keys key.asc 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')"
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
"$GPG" --batch --quiet --import key.asc
# isolated keyring holds ONLY this key -> a good signature can only be Anthropic's

# --- 2. verify InRelease ---------------------------------------------------
c_info "verifying repository index signature"
curl -fsSLo InRelease "$REPO_BASE/dists/stable/InRelease" || die "could not download InRelease"
inrelease_well_formed InRelease || die "InRelease is not a single clear-signed block; refusing"
"$GPG" --batch --quiet --yes --output Release.verified --decrypt InRelease \
  || die "InRelease signature verification FAILED"
c_ok "InRelease signature valid"
verify_release_freshness Release.verified "$(date -u +%s)" || die "repository index failed the freshness check"
check_date_floor "$RELEASE_DATE_EPOCH" "$RELEASE_DATE_STATE" "$ALLOW_DOWNGRADE" || die "older repository index refused"

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
# InRelease and the Packages index it pins are verified: raise the Date floor
save_release_date "$RELEASE_DATE_STATE" "$RELEASE_DATE_EPOCH" || die "could not record the verified index Date"
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

# --- .deb extraction ---------------------------------------------------------
# A .deb is an ar archive holding control.tar[.ext] and data.tar[.ext]. Tools,
# first available wins:
#   bsdtar   reads the ar container and, when libarchive was built with the
#            codec, the compressed tar as well
#   ar       (binutils) container only; tar + an external decompressor unpack
#   python3  container only, same external decompression as ar. Python's
#            tarfile is never used, so its lack of zstd before 3.14 is moot.
DEB_MEMBER_RE='^(control|data)\.tar(\.(xz|gz|zst))?$'

pick_ar_tool() {
  local t
  for t in bsdtar ar python3; do
    command -v "$t" >/dev/null 2>&1 && { echo "$t"; return 0; }
  done
  return 1
}

pick_gpg() {
  local t
  for t in gpg gpg2; do
    command -v "$t" >/dev/null 2>&1 && { echo "$t"; return 0; }
  done
  return 1
}

# py_ar list DEB | py_ar extract DEB MEMBER OUTDIR -- minimal ar(5) reader
py_ar() {
  python3 -I - "$@" <<'PY'
import os, sys
mode, deb = sys.argv[1], sys.argv[2]
with open(deb, 'rb') as f:
    if f.read(8) != b'!<arch>\n':
        sys.exit("not an ar archive")
    while True:
        hdr = f.read(60)
        if len(hdr) < 60:
            break
        name = hdr[0:16].decode('ascii', 'replace').strip().rstrip('/')
        size = int(hdr[48:58].decode('ascii').strip())
        start = f.tell()
        if mode == 'list':
            print(name)
        elif name == sys.argv[3]:
            with open(os.path.join(sys.argv[4], name), 'wb') as o:
                left = size
                while left:
                    chunk = f.read(min(1 << 20, left))
                    if not chunk:
                        sys.exit("truncated archive")
                    o.write(chunk)
                    left -= len(chunk)
            sys.exit(0)
        f.seek(start + size + (size % 2))
if mode != 'list':
    sys.exit("member not found: " + sys.argv[3])
PY
}

# deb_list_members TOOL DEB
deb_list_members() {
  case "$1" in
    bsdtar)  bsdtar -tf "$2" ;;
    ar)      ar t "$2" ;;
    python3) py_ar list "$2" ;;
    *)       return 1 ;;
  esac
}

# deb_extract_member TOOL DEB MEMBER OUTDIR -- DEB and OUTDIR absolute
deb_extract_member() {
  [[ "$3" =~ $DEB_MEMBER_RE ]] || die "refusing unexpected archive member name: $3"
  case "$1" in
    bsdtar)  bsdtar -xf "$2" -C "$4" "$3" ;;
    ar)      (cd "$4" && ar x "$2" "$3") ;;
    python3) py_ar extract "$2" "$3" "$4" ;;
    *)       return 1 ;;
  esac
}

# tar_compression MEMBER -> xz | gz | zst | none
tar_compression() {
  case "$1" in
    *.tar.xz)  echo xz ;;
    *.tar.gz)  echo gz ;;
    *.tar.zst) echo zst ;;
    *.tar)     echo none ;;
    *)         return 1 ;;
  esac
}

decompressor_for() {
  case "$1" in xz) echo xz ;; gz) echo gzip ;; zst) echo zstd ;; none) echo "" ;; *) return 1 ;; esac
}

# decompressor_pkg COMPRESSION FAMILY
decompressor_pkg() {
  case "$1:$2" in
    xz:deb) echo xz-utils ;;
    xz:*)   echo xz ;;
    gz:*)   echo gzip ;;
    zst:*)  echo zstd ;;
  esac
}

# bsdtar_supports COMPRESSION -- libarchive lists its codecs in --version
bsdtar_supports() {
  local v
  v="$(bsdtar --version 2>/dev/null)" || return 1
  case "$1" in
    none) return 0 ;;
    xz)   grep -q 'liblzma' <<<"$v" ;;
    gz)   grep -q 'zlib' <<<"$v" ;;
    zst)  grep -q 'libzstd' <<<"$v" ;;
    *)    return 1 ;;
  esac
}

# unpack_method TOOL COMPRESSION -> "bsdtar" or "external"
unpack_method() {
  if [ "$1" = bsdtar ] && bsdtar_supports "$2"; then echo bsdtar; else echo external; fi
}

# require_unpackers TOOL COMPRESSION... -- every tool present before extracting anything
require_unpackers() {
  local tool="$1" comp dec missing=""
  shift
  for comp in "$@"; do
    [ "$(unpack_method "$tool" "$comp")" = bsdtar ] && continue
    command -v tar >/dev/null 2>&1 || missing="$missing tar"
    dec="$(decompressor_for "$comp")" || die "unsupported payload compression: $comp"
    if [ -n "$dec" ] && ! command -v "$dec" >/dev/null 2>&1; then
      missing="$missing $dec (package: $(decompressor_pkg "$comp" "$(os_family)"))"
    fi
  done
  [ -z "$missing" ] || die "cannot unpack the package, missing:$missing"
}

# unpack_tar_member TOOL FILE DEST
unpack_tar_member() {
  local comp dec
  comp="$(tar_compression "$2")" || die "unsupported payload: $2"
  if [ "$(unpack_method "$1" "$comp")" = bsdtar ]; then
    bsdtar -xf "$2" -C "$3"
    return
  fi
  dec="$(decompressor_for "$comp")"
  if [ -z "$dec" ]; then
    tar -xf "$2" -C "$3"
  else
    "$dec" -dc "$2" | tar -xf - -C "$3"
  fi
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
c_info "extracting (container via $AR_TOOL)"
local members data_m control_m
members="$(deb_list_members "$AR_TOOL" "$TMP/pkg.deb")" || die "could not read the .deb container"
data_m="$(grep -E '^data\.tar' <<<"$members" | head -n1 || true)"
control_m="$(grep -E '^control\.tar' <<<"$members" | head -n1 || true)"
[ -n "$data_m" ] && [ -n "$control_m" ] || die "data.tar or control.tar member not found in .deb"
require_unpackers "$AR_TOOL" "$(tar_compression "$control_m")" "$(tar_compression "$data_m")"

mkdir -p "$TMP/members"
deb_extract_member "$AR_TOOL" "$TMP/pkg.deb" "$control_m" "$TMP/members" || die "could not extract $control_m"
deb_extract_member "$AR_TOOL" "$TMP/pkg.deb" "$data_m" "$TMP/members"    || die "could not extract $data_m"

CTRL="$TMP/control"; mkdir -p "$CTRL"
unpack_tar_member "$AR_TOOL" "$TMP/members/$control_m" "$CTRL" || die "could not unpack $control_m"
[ -f "$CTRL/control" ] || die "control file missing from package"
report_package_meta "$CTRL"
[ "$MODE" = "inspect" ] && return 0

ROOT="$TMP/root"; mkdir -p "$ROOT"
unpack_tar_member "$AR_TOOL" "$TMP/members/$data_m" "$ROOT" || die "could not unpack $data_m"
c_ok "payload extracted"
}

# Written only after step_install_payload succeeded, so a failed run never
# leaves a record behind. report_package_meta rebuilt package-meta/<ver> earlier
# in this run, so a record exists only when this install used the option.
step_record_host_check_skip() {
  [ "$SKIP_HOST_CHECK" = 1 ] || return 0
  record_host_check_skip "$META_DIR/$VER" "${GLIBC_SEEN:-}" "${GLIBC_FLOOR_SKIPPED:-0}"
  c_warn "recorded in $META_DIR/$VER/$SKIP_RECORD_NAME: installed with --skip-host-check"
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
  c_warn "Claude Desktop $VER installed, but the problems marked [fail:...] above will stop it from running"
  c_info "re-run with --doctor after fixing them"
  return 1
fi
c_ok "Claude Desktop $VER installed. Launch it from your app menu, or run: claude-desktop"
c_info "To update later, just run this script again (it is idempotent)."
}

# Retired environment variables are reported, never honoured.
warn_legacy_env() {
  if [ -n "${CLAUDE_SKIP_HOST_CHECK+set}" ]; then
    c_warn "CLAUDE_SKIP_HOST_CHECK is set but no longer has any effect; use --skip-host-check"
  fi
  return 0
}

# --- main ------------------------------------------------------------------
main() {
  set -euo pipefail
  umask 022
  parse_args "$@"
  warn_legacy_env
  case "$MODE" in
    uninstall) do_uninstall no ;;
    purge)     do_uninstall purge ;;
    doctor)    run_doctor; return ;;
    rollback)  do_rollback; return ;;
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
  valid_version "$VER" \
    || die "repository version $(printf '%q' "$VER") is not of the form N(.N)*; refusing (it is used in install paths and for version ordering)"
  if [ "$MODE" = "check" ]; then
    if [ "$INSTALLED_VER" = "$VER" ]; then
      c_ok "up to date"
    elif [ -n "$INSTALLED_VER" ] && version_lt "$VER" "$INSTALLED_VER"; then
      c_warn "repository offers an OLDER version than installed; an install would refuse it"
    else
      c_warn "update available"
    fi
    return 0
  fi
  if [ "$MODE" = "install" ] || [ "$MODE" = "force" ]; then
    check_version_order "$INSTALLED_VER" "$VER" "$ALLOW_DOWNGRADE" || die "downgrade refused"
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
  step_record_host_check_skip
  step_write_launcher
  step_write_desktop_entry
  step_final_report
}

# Run only when executed (directly, via bash, or piped); not when sourced.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
