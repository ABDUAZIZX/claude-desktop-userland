#!/usr/bin/env bash
# Unit tests for claude-desktop-userland.sh.
#
# The script is sourced (its main() guard keeps it from running) and its
# functions are called directly. Every call that may exit runs in a subshell
# so a die() fails one assertion instead of the whole suite.
#
# Usage: bash tests/run.sh            (no network, no root, touches only $TMPDIR)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../claude-desktop-userland.sh"
WORK="$(mktemp -d -t cdu-tests.XXXXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# Isolate every path the script derives from HOME before sourcing it.
export HOME="$WORK/home"
unset XDG_DATA_HOME
mkdir -p "$HOME"

# shellcheck source=../claude-desktop-userland.sh
. "$SCRIPT"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
nok()  { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; }

# expect_rc <expected-rc> <name> <command...>  -- runs the command in a subshell
expect_rc() {
  local want="$1" name="$2" got out
  shift 2
  out="$( ( "$@" ) 2>&1 )"; got=$?
  if [ "$got" = "$want" ]; then ok "$name"; else nok "$name" "rc=$got want=$want: $out"; fi
}

# expect_out <pattern> <name> <command...>  -- combined output must match (grep -E)
expect_out() {
  local pat="$1" name="$2" out
  shift 2
  out="$( ( "$@" ) 2>&1 )"
  if grep -qE -- "$pat" <<<"$out"; then ok "$name"; else nok "$name" "no match for /$pat/ in: $out"; fi
}

# --- sourcing ----------------------------------------------------------------
t_sourcing() {
  if declare -F main >/dev/null && [ -z "${MODE:-}" ]; then
    ok "sourcing defines main() without running it"
  else
    nok "sourcing defines main() without running it"
  fi
  # regression: on a fresh install (no "current" link) preflight must succeed;
  # an "[ -L ] && ..." as the function's last statement used to return 1 and
  # end the script silently under set -e
  expect_rc 0 "preflight succeeds with nothing installed" \
    bash -c 'set -euo pipefail; . "$1"; MODE=check; CURRENT="$2/none"; step_preflight; echo "INSTALLED=[$INSTALLED_VER]"' _ "$SCRIPT" "$WORK"
  expect_rc 0 "parse_args accepts --doctor" parse_args --doctor
  expect_rc 1 "parse_args rejects an unknown option" parse_args --bogus
}

# --- AppArmor userns restriction ---------------------------------------------
t_apparmor() {
  local d="$WORK/aa"; mkdir -p "$d"
  printf '0\n' >"$d/zero"; printf '1\n' >"$d/one"
  expect_rc 1 "apparmor sysctl=0 -> not restricted"   aa_restricts_userns "$d/zero"
  expect_rc 0 "apparmor sysctl=1 -> restricted"       aa_restricts_userns "$d/one"
  expect_rc 1 "apparmor sysctl missing -> not restricted, no error" aa_restricts_userns "$d/absent"
  expect_out '^$' "apparmor sysctl missing prints nothing" aa_restricts_userns "$d/absent"

  # check_userns end to end: restricted, no profile -> blocking failure
  expect_out 'AppArmor restricts' "check_userns flags restriction without profile" \
    check_userns "$d/one" "$d/no-profile"
  local out; out="$( (HOST_FAIL=0; check_userns "$d/one" "$d/no-profile"; echo "HOST_FAIL=$HOST_FAIL") 2>&1 )"
  if grep -q 'HOST_FAIL=1' <<<"$out"; then ok "check_userns sets HOST_FAIL when restricted"; else nok "check_userns sets HOST_FAIL when restricted" "$out"; fi
  # remedies: profile first, CLAUDE_NO_SANDBOX last
  local p_line s_line
  p_line="$(grep -n 'print-apparmor-profile' <<<"$out" | head -n1 | cut -d: -f1)"
  s_line="$(grep -n 'CLAUDE_NO_SANDBOX' <<<"$out" | head -n1 | cut -d: -f1)"
  if [ -n "$p_line" ] && [ -n "$s_line" ] && [ "$p_line" -lt "$s_line" ]; then
    ok "remedies list the profile before CLAUDE_NO_SANDBOX"
  else
    nok "remedies list the profile before CLAUDE_NO_SANDBOX" "$out"
  fi

  # restricted, matching profile file present -> ok
  aa_attach_path >"$d/profile"
  expect_out 'profile .* present' "check_userns accepts a matching profile" check_userns "$d/one" "$d/profile"
  # not restricted -> ok
  expect_out 'sandbox OK' "check_userns passes when unrestricted" check_userns "$d/zero" "$d/no-profile"

  # profile text: abi 4.0, unconfined, userns, and the warning on stderr
  local prof err
  prof="$( (print_apparmor_profile) 2>/dev/null )"
  err="$( (print_apparmor_profile) 2>&1 >/dev/null )"
  if grep -q '^abi <abi/4.0>,' <<<"$prof" && grep -q 'flags=(unconfined)' <<<"$prof" \
     && grep -q '^  userns,' <<<"$prof"; then
    ok "profile has abi 4.0, flags=(unconfined), userns"
  else
    nok "profile has abi 4.0, flags=(unconfined), userns" "$prof"
  fi
  if grep -q 'writable' <<<"$prof" && grep -q 'WARNING' <<<"$err" && grep -q 'can write to' <<<"$err"; then
    ok "profile output carries the writable-path warning"
  else
    nok "profile output carries the writable-path warning" "$err"
  fi
}

# --- shared-library resolution (no execution of the payload) -----------------
t_libs() {
  local re od d="$WORK/libs"
  mkdir -p "$d/app" "$d/bin"
  re=' 0x000000000000001d (RUNPATH)            Library runpath: [$ORIGIN]
 0x0000000000000001 (NEEDED)             Shared library: [libffmpeg.so]
 0x0000000000000001 (NEEDED)             Shared library: [libgtk-3.so.0]'
  if [ "$(parse_readelf_dynamic <<<"$re")" = 'RUNPATH $ORIGIN
NEEDED libffmpeg.so
NEEDED libgtk-3.so.0' ]; then ok "readelf -d output parsed"; else nok "readelf -d output parsed" "$(parse_readelf_dynamic <<<"$re")"; fi
  od='  NEEDED               libffmpeg.so
  RUNPATH              $ORIGIN
  SONAME               libx.so'
  if [ "$(parse_objdump_dynamic <<<"$od")" = 'NEEDED libffmpeg.so
RUNPATH $ORIGIN' ]; then ok "objdump -p output parsed"; else nok "objdump -p output parsed" "$(parse_objdump_dynamic <<<"$od")"; fi

  : >"$d/app/libffmpeg.so"
  expect_rc 0 'bundled lib found through $ORIGIN'   resolve_soname libffmpeg.so "$d/app" '$ORIGIN' ""
  expect_rc 0 'bundled lib found through ${ORIGIN}' resolve_soname libffmpeg.so "$d/app" '${ORIGIN}/' ""
  expect_rc 1 'no RUNPATH -> bundled lib not visible' resolve_soname libffmpeg.so "$d/app" '' ""
  expect_rc 0 "system lib found in ldconfig cache"  resolve_soname libgtk-3.so.0 "$d/app" '$ORIGIN' $'libc.so.6\nlibgtk-3.so.0'
  expect_rc 1 "lib absent everywhere -> missing"     resolve_soname libgtk-3.so.0 "$d/app" '$ORIGIN' 'libc.so.6'
  expect_rc 1 "cache match is exact, not substring"  resolve_soname libX11.so.6 "$d/app" '' 'libX11.so.6.4'

  # ldconfig -p: only the 64-bit entry counts for an x86_64 binary
  cat >"$d/bin/fake-ldconfig" <<'FAKE'
#!/bin/sh
cat <<'OUT'
5 libs found in cache `/etc/ld.so.cache'
	libgtk-3.so.0 (libc6,x86-64) => /lib64/libgtk-3.so.0
	libc.so.6 (libc6,x86-64, OS ABI: Linux 3.2.0) => /lib/x86_64-linux-gnu/libc.so.6
	libx86-64-lookalike.so.1 (libc6) => /lib/libx86-64-lookalike.so.1
	libasound.so.2 (libc6) => /lib/libasound.so.2
	libfoo.so.1 (libc6,AArch64) => /lib/aarch64-linux-gnu/libfoo.so.1
OUT
FAKE
  chmod +x "$d/bin/fake-ldconfig"
  if [ "$(ld_cache_sonames "$d/bin/fake-ldconfig" x86_64)" = $'libc.so.6\nlibgtk-3.so.0' ]; then
    ok "ldconfig cache filtered to the machine ABI (32-bit ignored, OS ABI suffix handled)"
  else
    nok "ldconfig cache filtered to the machine ABI (32-bit ignored, OS ABI suffix handled)" "$(ld_cache_sonames "$d/bin/fake-ldconfig" x86_64)"
  fi
  if [ "$(ld_cache_sonames "$d/bin/fake-ldconfig" aarch64)" = "libfoo.so.1" ]; then
    ok "ldconfig cache filtered for aarch64"
  else
    nok "ldconfig cache filtered for aarch64"
  fi

  # apt naming follows apt-cache, not the release number
  fake_apt_t64() { [ "$1" = show ] && [ "$3" = "libasound2t64" ]; }
  fake_apt_old() { [ "$1" = show ] && [ "$3" = "libasound2" ]; }
  fake_apt_none() { return 100; }
  local n
  n="$(deb_pick_name "libasound2t64/libasound2" fake_apt_t64)"
  [ "$n" = libasound2t64 ] && ok "apt-cache knows t64 name -> t64 chosen" || nok "apt-cache knows t64 name -> t64 chosen" "$n"
  n="$(deb_pick_name "libasound2t64/libasound2" fake_apt_old)"
  [ "$n" = libasound2 ] && ok "apt-cache knows only old name -> old chosen" || nok "apt-cache knows only old name -> old chosen" "$n"
  expect_rc 1 "apt-cache knows neither -> unconfirmed" deb_pick_name "libasound2t64/libasound2" fake_apt_none

  expect_rc 1 "lib outside the Electron table is unmapped" lib_pkg libfoo.so.9
  expect_out "dnf provides '\*/libfoo.so.9'" "search command for unmapped lib (dnf)" lib_search_cmd libfoo.so.9 rpm
  expect_out "apt-file search libfoo.so.9"   "search command for unmapped lib (apt)" lib_search_cmd libfoo.so.9 deb
  expect_out "pacman -F libfoo.so.9"         "search command for unmapped lib (pacman)" lib_search_cmd libfoo.so.9 arch
  expect_out "zypper se --provides"          "search command for unmapped lib (zypper)" lib_search_cmd libfoo.so.9 suse

  # with neither readelf nor objdump the check is skipped, never falls back to ldd
  local fakebin="$d/app2"; mkdir -p "$fakebin"; : >"$fakebin/claude-desktop"
  # PATH with every tool the check uses except readelf/objdump
  local nobin="$d/nobinutils" tool src
  mkdir -p "$nobin"
  for tool in bash getconf dirname sort sed awk grep cut cat uname; do
    src="$(command -v "$tool")" && ln -sf "$src" "$nobin/$tool"
  done
  expect_out 'install binutils' "no readelf/objdump -> skipped with binutils hint" \
    env PATH="$nobin" "$(command -v bash)" -c '. "$1"; check_libs "$2" x86_64' _ "$SCRIPT" "$fakebin"
  if env PATH="$nobin" "$(command -v bash)" -c '. "$1"; check_libs "$2" x86_64' _ "$SCRIPT" "$fakebin" 2>&1 | grep -q ldd; then
    nok "no fallback to ldd"
  else
    ok "no fallback to ldd"
  fi
}

# Test groups register themselves here.
TESTS=(t_sourcing t_apparmor t_libs)

for t in "${TESTS[@]}"; do "$t"; done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
