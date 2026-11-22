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

# Test groups register themselves here.
TESTS=(t_sourcing t_apparmor)

for t in "${TESTS[@]}"; do "$t"; done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
