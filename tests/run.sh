#!/usr/bin/env bash
# Unit tests for claude-desktop-userland.sh.
#
# The script is sourced (its main() guard keeps it from running) and its
# functions are called directly. Every call that may exit runs in a subshell
# so a die() fails one assertion instead of the whole suite.
#
# Usage: bash tests/run.sh [--no-skip]  (no network, no root, touches only $TMPDIR)
#   --no-skip  a test skipped for a missing tool counts as a failure (CI uses it)

set -uo pipefail

NO_SKIP=0
case "${1:-}" in
  --no-skip) NO_SKIP=1 ;;
  "") : ;;
  *) printf 'usage: bash tests/run.sh [--no-skip]\n' >&2; exit 2 ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../claude-desktop-userland.sh"
WORK="$(mktemp -d -t cdu-tests.XXXXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# Isolate every path the script derives from HOME before sourcing it.
export HOME="$WORK/home"
unset XDG_DATA_HOME
mkdir -p "$HOME"

# Preflight requires curl and gpg to exist, but the tests that reach it never
# download or verify anything. Stubs make those tests independent of the host
# (a bare Ubuntu image has neither); a stub that is actually called fails loudly.
STUBS="$WORK/stubs"
mkdir -p "$STUBS"
for _t in curl gpg; do
  printf '#!/bin/sh\necho "test stub %s was called; tests must not reach the network" >&2\nexit 97\n' "$_t" >"$STUBS/$_t"
  chmod +x "$STUBS/$_t"
done
unset _t

# shellcheck source=../claude-desktop-userland.sh
. "$SCRIPT"

PASS=0
FAIL=0
SKIP=0
ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
nok()  { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; return 0; }
# skip <name> <reason> -- a test that could not run; never counted as passed
skip() { SKIP=$((SKIP + 1)); printf 'SKIP %s (%s)\n' "$1" "$2"; }

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
    env PATH="$STUBS:$PATH" bash -c 'set -euo pipefail; . "$1"; MODE=check; CURRENT="$2/none"; step_preflight; echo "INSTALLED=[$INSTALLED_VER]"' _ "$SCRIPT" "$WORK"
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

# --- .deb extraction chain ---------------------------------------------------
# ar_pack OUT FILE... -- writes a System V ar archive (the .deb container format)
ar_pack() {
  local out="$1" f name size
  shift
  printf '!<arch>\n' >"$out"
  for f in "$@"; do
    name="$(basename "$f")"; size="$(stat -c %s "$f")"
    printf '%-16s%-12s%-6s%-6s%-8s%-10s`\n' "$name/" 0 0 0 100644 "$size" >>"$out"
    cat "$f" >>"$out"
    [ $((size % 2)) = 1 ] && printf '\n' >>"$out"
  done
  return 0
}

# make_deb OUT DATA-COMPRESSION -- control.tar.xz + data.tar.<comp>
make_deb() {
  local out="$1" comp="$2" src="$WORK/debsrc.$2"
  rm -rf "$src"; mkdir -p "$src/ctl" "$src/data/usr/lib/claude-desktop" "$src/m"
  printf 'Package: claude-desktop\nVersion: 9.9.9\n' >"$src/ctl/control"
  printf 'payload\n' >"$src/data/usr/lib/claude-desktop/marker"
  tar -C "$src/ctl" -cf - . | xz -c >"$src/m/control.tar.xz"
  case "$comp" in
    xz)   tar -C "$src/data" -cf - . | xz -c   >"$src/m/data.tar.xz" ;;
    gz)   tar -C "$src/data" -cf - . | gzip -c >"$src/m/data.tar.gz" ;;
    zst)  tar -C "$src/data" -cf - . | zstd -q -c >"$src/m/data.tar.zst" ;;
    none) tar -C "$src/data" -cf "$src/m/data.tar" . ;;
  esac
  printf '2.0\n' >"$src/m/debian-binary"
  ar_pack "$out" "$src/m/debian-binary" "$src/m/control.tar.xz" "$src/m"/data.tar*
}

# extract_with TOOL DEB DEST -- the same sequence step_extract_package runs
extract_with() {
  local tool="$1" deb="$2" dest="$3" members data_m control_m
  mkdir -p "$dest/members" "$dest/control" "$dest/root"
  members="$(deb_list_members "$tool" "$deb")" || return 1
  data_m="$(grep -E '^data\.tar' <<<"$members" | head -n1)"
  control_m="$(grep -E '^control\.tar' <<<"$members" | head -n1)"
  require_unpackers "$tool" "$(tar_compression "$control_m")" "$(tar_compression "$data_m")"
  deb_extract_member "$tool" "$deb" "$control_m" "$dest/members"
  deb_extract_member "$tool" "$deb" "$data_m" "$dest/members"
  unpack_tar_member "$tool" "$dest/members/$control_m" "$dest/control"
  unpack_tar_member "$tool" "$dest/members/$data_m" "$dest/root"
  grep -q 'Version: 9.9.9' "$dest/control/control" \
    && grep -q payload "$dest/root/usr/lib/claude-desktop/marker"
}

t_extract() {
  local d="$WORK/ex" tool comp deb n=0
  mkdir -p "$d"
  for comp in xz gz zst none; do
    if [ "$comp" = zst ] && ! command -v zstd >/dev/null 2>&1; then
      for tool in bsdtar ar python3; do skip "extract data.tar.zst via $tool" "zstd not installed"; done
      continue
    fi
    deb="$d/test-$comp.deb"; make_deb "$deb" "$comp"
    for tool in bsdtar ar python3; do
      if ! command -v "$tool" >/dev/null 2>&1; then
        skip "extract data.tar.$comp via $tool" "$tool not installed"; continue
      fi
      n=$((n + 1))
      expect_rc 0 "extract data.tar.$comp via $tool" extract_with "$tool" "$deb" "$d/out-$tool-$comp"
    done
  done
  [ "$n" -gt 0 ] || nok "at least one extraction path exercised"

  # member names outside control/data.tar[.ext] are refused before extraction
  expect_out 'refusing unexpected archive member' "path-like member name refused" \
    deb_extract_member python3 "$d/test-xz.deb" "../../etc/passwd" "$d"

  # a missing decompressor stops before anything is extracted, naming the package
  local nozstd="$d/nozstd" t src
  mkdir -p "$nozstd"
  for t in bash tar xz gzip grep cat; do src="$(command -v "$t")" && ln -sf "$src" "$nozstd/$t"; done
  expect_out 'missing: zstd \(package: zstd\)' "missing zstd reported with package name" \
    env PATH="$nozstd" "$(command -v bash)" -c '. "$1"; require_unpackers ar xz zst' _ "$SCRIPT"
  expect_rc 0 "xz and gzip present -> no complaint" \
    env PATH="$nozstd" "$(command -v bash)" -c '. "$1"; require_unpackers ar xz gz' _ "$SCRIPT"

  # tool preference order and gpg2 fallback
  local only="$d/only"; mkdir -p "$only"
  for t in python3 bash; do src="$(command -v "$t")" && ln -sf "$src" "$only/$t"; done
  expect_out '^python3$' "python3 chosen when bsdtar and ar are absent" \
    env PATH="$only" "$(command -v bash)" -c '. "$1"; pick_ar_tool' _ "$SCRIPT"
  printf '#!/bin/sh\nexit 0\n' >"$only/gpg2"; chmod +x "$only/gpg2"
  expect_out '^gpg2$' "gpg2 accepted when gpg is absent" \
    env PATH="$only" "$(command -v bash)" -c '. "$1"; pick_gpg' _ "$SCRIPT"
}

# --- repository freshness ----------------------------------------------------
t_release_dates() {
  local d="$WORK/rel"; mkdir -p "$d"
  cat >"$d/Release.verified" <<'REL'
Origin: Anthropic
Suite: stable
Date: Sat, 21 Nov 2026 21:15:46 +0000
Valid-Until: Sat, 28 Nov 2026 21:15:46 UTC
SHA256:
 abc 123 main/binary-amd64/Packages

Date: Thu, 01 Jan 2099 00:00:00 +0000
REL
  local date_e valid_e
  date_e="$(to_epoch 'Sat, 21 Nov 2026 21:15:46 +0000')"
  valid_e="$(to_epoch 'Sat, 28 Nov 2026 21:15:46 UTC')"
  [ "$date_e" = 1795295746 ] && ok "Date parsed to epoch" || nok "Date parsed to epoch" "$date_e"
  [ "$valid_e" = 1795900546 ] && ok "Valid-Until (UTC suffix) parsed to epoch" || nok "Valid-Until (UTC suffix) parsed to epoch" "$valid_e"
  [ "$(release_field "$d/Release.verified" Date)" = 'Sat, 21 Nov 2026 21:15:46 +0000' ] \
    && ok "release_field reads the first paragraph only" || nok "release_field reads the first paragraph only"

  expect_rc 1 "Valid-Until: time after expiry rejected" check_release_validity "$date_e" "$valid_e" $((valid_e + 1))
  expect_out 'expired' "Valid-Until: rejection says expired" check_release_validity "$date_e" "$valid_e" $((valid_e + 1))
  expect_rc 0 "Valid-Until: time before expiry accepted" check_release_validity "$date_e" "$valid_e" $((valid_e - 1))
  expect_rc 1 "Date > 10 min in the future rejected" check_release_validity "$date_e" "$valid_e" $((date_e - 601))
  expect_rc 0 "Date 5 min in the future tolerated" check_release_validity "$date_e" "$valid_e" $((date_e - 300))

  expect_rc 0 "freshness on verified file, inside window" verify_release_freshness "$d/Release.verified" $((date_e + 3600))
  expect_rc 1 "freshness on verified file, after expiry" verify_release_freshness "$d/Release.verified" $((valid_e + 60))
  sed '/^Valid-Until:/d' "$d/Release.verified" >"$d/novalid"
  expect_rc 1 "missing Valid-Until fails closed" verify_release_freshness "$d/novalid" $((date_e + 3600))

  # InRelease structure: one clear-signed block, nothing outside it
  local good="$d/InRelease.good"
  printf '%s\n' '-----BEGIN PGP SIGNED MESSAGE-----' 'Hash: SHA512' '' 'Date: x' \
    '-----BEGIN PGP SIGNATURE-----' '' 'sig' '-----END PGP SIGNATURE-----' >"$good"
  expect_rc 0 "well-formed InRelease accepted" inrelease_well_formed "$good"
  { printf 'Valid-Until: Thu, 01 Jan 2099 00:00:00 UTC\n'; cat "$good"; } >"$d/InRelease.prefix"
  expect_rc 1 "unsigned text before the signed block rejected" inrelease_well_formed "$d/InRelease.prefix"
  { cat "$good"; printf 'Valid-Until: Thu, 01 Jan 2099 00:00:00 UTC\n'; } >"$d/InRelease.suffix"
  expect_rc 1 "unsigned text after the signed block rejected" inrelease_well_formed "$d/InRelease.suffix"
  cat "$good" "$good" >"$d/InRelease.double"
  expect_rc 1 "two signed blocks rejected" inrelease_well_formed "$d/InRelease.double"
}

# --- downgrade protection ----------------------------------------------------
t_downgrade() {
  expect_rc 1 "older version refused"                    check_version_order 6.28899.6 5.11492.5 0
  expect_out 'older than the installed' "refusal names the rollback" check_version_order 6.28899.6 5.11492.5 0
  expect_rc 0 "older version accepted with --allow-downgrade" check_version_order 6.28899.6 5.11492.5 1
  expect_out 'DOWNGRADE' "allowed downgrade prints a warning"   check_version_order 6.28899.6 5.11492.5 1
  expect_rc 0 "newer version accepted"                   check_version_order 5.11492.5 6.28899.6 0
  expect_rc 0 "same version accepted (--force reinstall)" check_version_order 6.28899.6 6.28899.6 0
  expect_rc 0 "nothing installed -> accepted"            check_version_order "" 6.28899.6 0
  expect_rc 1 "sort -V, not lexical: 6.9 < 6.10"         check_version_order 6.10.0 6.9.0 0

  expect_rc 0 "--allow-downgrade combines with --force"  parse_args --force --allow-downgrade
  expect_rc 0 "--allow-downgrade alone means install"    parse_args --allow-downgrade
  expect_rc 1 "--allow-downgrade rejected with --doctor" parse_args --doctor --allow-downgrade
  expect_rc 1 "two mode options rejected"                parse_args --check --force

  expect_rc 0 "--skip-host-check accepted with install"   parse_args --skip-host-check
  expect_rc 0 "--skip-host-check accepted with --force"   parse_args --force --skip-host-check
  expect_rc 1 "--skip-host-check rejected with --check"   parse_args --check --skip-host-check
  expect_rc 1 "--skip-host-check rejected with --doctor"  parse_args --doctor --skip-host-check
  # scope: version floor only
  local fk="$WORK/fakeglibc"; mkdir -p "$fk/old" "$fk/musl"
  printf '#!/bin/sh\necho "glibc 2.31"\n' >"$fk/old/getconf"
  printf '#!/bin/sh\nexit 1\n' >"$fk/musl/getconf"
  chmod +x "$fk/old/getconf" "$fk/musl/getconf"
  expect_out 'HOST_FAIL=1' "old glibc fails without --skip-host-check" \
    env PATH="$fk/old:$PATH" bash -c '. "$1"; check_libc; echo "HOST_FAIL=$HOST_FAIL"' _ "$SCRIPT"
  expect_out 'HOST_FAIL=0' "old glibc only warns with --skip-host-check" \
    env PATH="$fk/old:$PATH" bash -c '. "$1"; check_libc skip-floor; echo "HOST_FAIL=$HOST_FAIL"' _ "$SCRIPT"
  expect_out 'HOST_FAIL=1' "musl still refused with --skip-host-check" \
    env PATH="$fk/musl:$PATH" bash -c '. "$1"; check_libc skip-floor; echo "HOST_FAIL=$HOST_FAIL"' _ "$SCRIPT"
  expect_out 'does not cover a missing glibc' "preflight on musl with the flag dies with the scope message" \
    env PATH="$fk/musl:$STUBS:$PATH" bash -c 'set -euo pipefail; . "$1"; parse_args --skip-host-check; CURRENT="$2/none"; step_preflight' _ "$SCRIPT" "$WORK"

  # the old environment variable must have no effect any more
  expect_out 'SKIP=0' "CLAUDE_SKIP_HOST_CHECK env var ignored" \
    env CLAUDE_SKIP_HOST_CHECK=1 bash -c '. "$1"; parse_args; echo "SKIP=$SKIP_HOST_CHECK"' _ "$SCRIPT"
  expect_out 'no longer has any effect; use --skip-host-check' "legacy env var produces a warning" \
    env CLAUDE_SKIP_HOST_CHECK=1 bash -c '. "$1"; warn_legacy_env' _ "$SCRIPT"
  expect_out '^$' "no warning when the legacy env var is unset" \
    env -u CLAUDE_SKIP_HOST_CHECK bash -c '. "$1"; warn_legacy_env' _ "$SCRIPT"
  # end to end through main: warning shown, behaviour unchanged (still refused on old glibc)
  local e2e
  e2e="$(env CLAUDE_SKIP_HOST_CHECK=1 PATH="$fk/old:$STUBS:$PATH" HOME="$WORK/legacy-home" bash "$SCRIPT" 2>&1)"
  if grep -q 'no longer has any effect' <<<"$e2e" && grep -q 'glibc too old' <<<"$e2e"; then
    ok "main warns about the legacy var and still refuses old glibc"
  else
    nok "main warns about the legacy var and still refuses old glibc" "$e2e"
  fi
}

# --- Date floor ---------------------------------------------------------------
t_date_floor() {
  local d="$WORK/state" st
  mkdir -p "$d"; st="$d/last-release-date"
  expect_rc 0 "no saved Date -> any Date accepted" check_date_floor 1000 "$st" 0
  save_release_date "$st" 2000
  [ "$(cat "$st")" = 2000 ] && ok "verified Date saved" || nok "verified Date saved"
  expect_rc 1 "Date older than saved -> rejected"      check_date_floor 1999 "$st" 0
  expect_out 'older than the last verified' "rejection explains the rollback" check_date_floor 1999 "$st" 0
  expect_rc 0 "Date equal to saved -> accepted"         check_date_floor 2000 "$st" 0
  expect_rc 0 "Date newer than saved -> accepted"       check_date_floor 2001 "$st" 0
  expect_rc 0 "older Date with --allow-downgrade -> accepted" check_date_floor 1999 "$st" 1
  expect_out 'OLDER INDEX' "allowed older Date prints a warning" check_date_floor 1999 "$st" 1

  save_release_date "$st" 1500
  [ "$(cat "$st")" = 2000 ] && ok "saving an older Date never lowers the floor" || nok "saving an older Date never lowers the floor" "$(cat "$st")"
  save_release_date "$st" 3000
  [ "$(cat "$st")" = 3000 ] && ok "saving a newer Date raises the floor" || nok "saving a newer Date raises the floor"

  printf 'garbage\n' >"$st"
  expect_rc 1 "corrupt state file fails closed" check_date_floor 5000 "$st" 0
  expect_rc 1 "corrupt state file is not overwritten silently" save_release_date "$st" 5000
}

# --- record of --skip-host-check ----------------------------------------------
t_skip_record() {
  local d="$WORK/skiprec" out
  mkdir -p "$d/meta" "$d/versions/6.0.0"
  ln -sfn "$d/versions/6.0.0" "$d/current"
  expect_rc 0 "no record -> no glibc failure" check_host_check_record "$d/meta" "$d/current"

  record_host_check_skip "$d/meta/6.0.0" 2.31 1
  grep -q '^option=--skip-host-check$' "$d/meta/6.0.0/host-check-skipped" \
    && grep -q '^glibc=2.31$' "$d/meta/6.0.0/host-check-skipped" \
    && ok "record written with option and glibc" || nok "record written with option and glibc"
  out="$( (HOST_FAIL=0; check_host_check_record "$d/meta" "$d/current"; echo "HOST_FAIL=$HOST_FAIL") 2>&1 )"
  if grep -q 'HOST_FAIL=1' <<<"$out" && grep -q 'glibc check: 6.0.0 was installed with --skip-host-check' <<<"$out"; then
    ok "doctor reports the skipped install as a glibc failure"
  else
    nok "doctor reports the skipped install as a glibc failure" "$out"
  fi
  expect_out 'once glibc >= ' "violated floor: advice mentions upgrading glibc" check_host_check_record "$d/meta" "$d/current"
  record_host_check_skip "$d/meta/6.0.0" 2.39 0
  expect_out 'floor was met at install time' "floor met: advice says so" check_host_check_record "$d/meta" "$d/current"
  # record belongs to a version: another current version is clean
  mkdir -p "$d/versions/7.0.0"; ln -sfn "$d/versions/7.0.0" "$d/current"
  expect_rc 0 "record of another version does not fail the current one" check_host_check_record "$d/meta" "$d/current"
  # the pre-download check must not read the record (an upgrade can clear it)
  if grep -q 'check_host_check_record' <<<"$(declare -f step_preflight)"; then
    nok "pre-download check ignores the record"
  else
    ok "pre-download check ignores the record"
  fi
}

# --- README stays in sync with the script ------------------------------------
t_readme() {
  local readme="$HERE/../README.md" block want got
  block="$(sed -n '/<!-- usage:begin -->/,/<!-- usage:end -->/p' "$readme" | sed '1,2d;$d' | sed '$d')"
  want="$(usage)"
  if [ "$block" = "$want" ]; then ok "README Usage block matches --help verbatim"
  else nok "README Usage block matches --help verbatim" "$(diff <(printf '%s\n' "$want") <(printf '%s\n' "$block") | head -n 20)"; fi

  want="$(sha256sum "$SCRIPT" | cut -d' ' -f1)"
  got="$(sed -n 's/^echo "\([0-9a-f]\{64\}\)  claude-desktop-userland.sh" | sha256sum -c -$/\1/p' "$readme")"
  if [ "$got" = "$want" ]; then ok "README install hash matches the script"
  else nok "README install hash matches the script" "README=$got script=$want (update the install snippet)"; fi

  if grep -q "raw.githubusercontent.com/ABDUAZIZX/claude-desktop-userland/v$SELF_VERSION/claude-desktop-userland.sh" "$readme"; then
    ok "README install URL points at tag v$SELF_VERSION"
  else
    nok "README install URL points at tag v$SELF_VERSION"
  fi
}

# --- repository version format -------------------------------------------------
t_version_format() {
  local v
  for v in 6.28899.6 1 10.0.0 0.1; do
    expect_rc 0 "version accepted: $v" valid_version "$v"
  done
  for v in "../x" "1.0~rc1" "1:2.0" "" "1..2" "1." ".1" "1.0 " "-1" "1.0/.." $'1.0\n2' "v1.0" "1.0-1"; do
    expect_rc 1 "version refused: $(printf '%q' "$v")" valid_version "$v"
  done
  # the check sits right after step_select_package, before VER is used anywhere
  local body sel chk first_use
  body="$(declare -f main)"
  sel="$(grep -n 'step_select_package' <<<"$body" | head -n1 | cut -d: -f1)"
  chk="$(grep -n 'valid_version "\$VER"' <<<"$body" | head -n1 | cut -d: -f1)"
  first_use="$(grep -n '\$VER' <<<"$body" | grep -v 'valid_version\|printf' | head -n1 | cut -d: -f1)"
  if [ -n "$sel" ] && [ -n "$chk" ] && [ "$chk" -eq $((sel + 1)) ] && [ "$chk" -lt "$first_use" ]; then
    ok "VER validated immediately after step_select_package"
  else
    nok "VER validated immediately after step_select_package" "select=$sel check=$chk first_use=$first_use"
  fi
}

# Test groups register themselves here.
TESTS=(t_sourcing t_apparmor t_libs t_extract t_release_dates t_downgrade t_date_floor t_skip_record t_readme t_version_format)

for t in "${TESTS[@]}"; do "$t"; done

printf '\n%d passed, %d skipped, %d failed\n' "$PASS" "$SKIP" "$FAIL"
if [ "$NO_SKIP" = 1 ] && [ "$SKIP" -gt 0 ]; then
  printf 'FAIL --no-skip: %d test(s) skipped\n' "$SKIP"
  exit 1
fi
[ "$FAIL" = 0 ]
