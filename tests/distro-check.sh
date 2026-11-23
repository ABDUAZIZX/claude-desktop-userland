#!/usr/bin/env bash
# Distribution checks run by the "distros" CI workflow, inside one container
# per distribution. Root inside the container is expected: the "libs" mode
# installs packages with the distribution's own package manager.
#
# Usage:
#   bash tests/distro-check.sh libs APP-DIR
#       APP-DIR is an extracted Claude Desktop version directory (the payload
#       job's artifact). The glibc floor must pass. The shared-library check
#       must then either pass, or report only mapped, confirmed package names;
#       those packages are installed and the check must pass afterwards. This
#       proves the package names the installer suggests are real and complete
#       on this distribution.
#   bash tests/distro-check.sh refused PATTERN
#       A plain install must stop before any download, with output matching
#       PATTERN (grep -E). curl is replaced by a stub that fails loudly, so
#       reaching the network is itself a failure.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../claude-desktop-userland.sh"
WORK="$(mktemp -d -t cdu-distro.XXXXXXXX)"
trap 'rm -rf "$WORK"' EXIT

fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }

# Run check_libs in a fresh shell; print its output, return the host verdict.
run_check_libs() {
  env HOME="$WORK/home" bash -c '
    . "$1"
    HOST_FAIL=0
    check_libs "$2"
    exit "$HOST_FAIL"' _ "$SCRIPT" "$1" 2>&1 | strip_ansi
  return "${PIPESTATUS[0]}"
}

install_pkgs() {
  local fam="$1"; shift
  case "$fam" in
    deb)  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" ;;
    rpm)  dnf install -y --setopt=install_weak_deps=False "$@" ;;
    arch) pacman -S --needed --noconfirm "$@" ;;
    suse) zypper --non-interactive install --no-recommends "$@" ;;
    *)    fail "unknown distribution family '$fam'" ;;
  esac
}

mode_libs() {
  local dir="${1:?usage: distro-check.sh libs APP-DIR}" out fam pkgs
  [ -d "$dir" ] || fail "no such directory: $dir"
  mkdir -p "$WORK/home"

  out="$(env HOME="$WORK/home" bash -c '. "$1"; HOST_FAIL=0; check_libc; exit "$HOST_FAIL"' _ "$SCRIPT" 2>&1 | strip_ansi)" \
    || { printf '%s\n' "$out"; fail "glibc floor refused on a distribution expected to pass"; }
  printf '%s\n' "$out"

  if out="$(run_check_libs "$dir")"; then
    printf '%s\n' "$out"
    printf 'ok   all shared libraries resolve without installing anything\n'
    return 0
  fi
  printf '%s\n' "$out"

  # Every missing soname must map to a package the package manager knows.
  if grep -q 'not in the known list' <<<"$out"; then
    fail "a missing library has no package mapping (lib_pkg)"
  fi
  if grep -q 'apt-cache could not confirm' <<<"$out"; then
    fail "apt-cache did not confirm a suggested package name"
  fi
  pkgs="$(sed -nE 's/.*likely fix: (sudo )?(apt install|dnf install|pacman -S --needed|zypper install) //p' <<<"$out")"
  [ -n "${pkgs// /}" ] || fail "libraries are missing but no install command was suggested"

  fam="$(bash -c '. "$1"; os_family' _ "$SCRIPT")"
  printf 'info installing the suggested packages (%s): %s\n' "$fam" "$pkgs"
  # shellcheck disable=SC2086  # package names: no spaces or glob characters
  install_pkgs "$fam" $pkgs >"$WORK/install.log" 2>&1 \
    || { tail -n 40 "$WORK/install.log" >&2; fail "installing the suggested packages failed (a wrong package name?)"; }

  out="$(run_check_libs "$dir")" \
    || { printf '%s\n' "$out"; fail "libraries still missing after installing the suggested packages"; }
  printf '%s\n' "$out"
  printf 'ok   the suggested packages make every shared library resolve\n'
}

mode_refused() {
  local pattern="${1:?usage: distro-check.sh refused PATTERN}" out rc
  mkdir -p "$WORK/home" "$WORK/stubs"
  printf '#!/bin/sh\necho "curl stub called: the install reached the network" >&2\nexit 97\n' >"$WORK/stubs/curl"
  chmod +x "$WORK/stubs/curl"

  set +e
  out="$(env HOME="$WORK/home" PATH="$WORK/stubs:$PATH" bash "$SCRIPT" 2>&1 | strip_ansi)"
  rc="${PIPESTATUS[0]}"
  set -e
  printf '%s\n' "$out"
  [ "$rc" != 0 ] || fail "the install was not refused"
  grep -q 'curl stub called' <<<"$out" && fail "the install reached the network before refusing"
  grep -qE -- "$pattern" <<<"$out" || fail "refused, but output does not match: $pattern"
  [ ! -e "$WORK/home/.local" ] || fail "a refused install left files under \$HOME/.local"
  printf 'ok   refused before any download: %s\n' "$pattern"
}

case "${1:-}" in
  libs)    shift; mode_libs "$@" ;;
  refused) shift; mode_refused "$@" ;;
  *) printf 'usage: bash tests/distro-check.sh libs APP-DIR | refused PATTERN\n' >&2; exit 2 ;;
esac
