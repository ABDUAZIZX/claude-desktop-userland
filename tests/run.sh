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

# make_deb OUT DATA-COMPRESSION [app] -- control.tar.xz + data.tar.<comp>;
# with "app" the payload also holds an executable claude-desktop and
# resources/app.asar, so a full install can complete
make_deb() {
  local out="$1" comp="$2" src="$WORK/debsrc.$2"
  rm -rf "$src"; mkdir -p "$src/ctl" "$src/data/usr/lib/claude-desktop" "$src/m"
  printf 'Package: claude-desktop\nVersion: 9.9.9\n' >"$src/ctl/control"
  printf 'payload\n' >"$src/data/usr/lib/claude-desktop/marker"
  if [ "${3:-}" = app ]; then
    mkdir -p "$src/data/usr/lib/claude-desktop/resources"
    printf '#!/bin/sh\nexit 0\n' >"$src/data/usr/lib/claude-desktop/claude-desktop"
    chmod +x "$src/data/usr/lib/claude-desktop/claude-desktop"
    : >"$src/data/usr/lib/claude-desktop/resources/app.asar"
  fi
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
# released_script_ref REPO TAG -- what the README hash must match: prints "tag"
# when TAG exists, "working" when the repository has no such tag. Returns 2
# with the reason when git cannot answer (not a repository, unreadable,
# ownership refused, git missing). safe.directory is passed on the command
# line: the checkout may belong to another uid (CI containers), and this
# suite sets its own HOME, so a global setting would not be seen.
released_script_ref() {
  local repo="$1" tag="$2" err rc=0
  if ! err="$(git -c safe.directory="$repo" -C "$repo" rev-parse --git-dir 2>&1 >/dev/null)"; then
    printf 'git cannot read %s: %s\n' "$repo" "${err:-git not found}"
    return 2
  fi
  err="$(git -c safe.directory="$repo" -C "$repo" show-ref --verify --quiet "refs/tags/$tag" 2>&1)" || rc=$?
  case "$rc" in
    0) echo tag ;;
    1) echo working ;;
    *) printf 'git show-ref %s failed (rc=%s): %s\n' "$tag" "$rc" "$err"; return 2 ;;
  esac
}

t_readme() {
  local readme="$HERE/../README.md" block want got
  block="$(sed -n '/<!-- usage:begin -->/,/<!-- usage:end -->/p' "$readme" | sed '1,2d;$d' | sed '$d')"
  want="$(usage)"
  if [ "$block" = "$want" ]; then ok "README Usage block matches --help verbatim"
  else nok "README Usage block matches --help verbatim" "$(diff <(printf '%s\n' "$want") <(printf '%s\n' "$block") | head -n 20)"; fi

  # The snippet downloads the script from tag v$SELF_VERSION, so its hash must
  # match the script as released at that tag, not the working copy (which
  # changes between releases). Before the tag exists (release step 1-4) the
  # working copy is the release candidate and is compared instead. Any other
  # git failure is an error, never a silent fall back to the working copy.
  local repo ref src
  repo="$(cd "$HERE/.." && pwd -P)"
  if ! src="$(released_script_ref "$repo" "v$SELF_VERSION" 2>&1)"; then
    nok "README install hash: git can read the repository" "$src"
    return 0
  fi
  if [ "$src" = tag ]; then
    want="$(git -c safe.directory="$repo" -C "$repo" show "v$SELF_VERSION:claude-desktop-userland.sh" | sha256sum | cut -d' ' -f1)"
    ref="tag v$SELF_VERSION"
  else
    want="$(sha256sum "$SCRIPT" | cut -d' ' -f1)"
    ref="working copy"
  fi
  got="$(sed -n 's/^echo "\([0-9a-f]\{64\}\)  claude-desktop-userland.sh" | sha256sum -c -$/\1/p' "$readme")"
  if [ "$got" = "$want" ]; then ok "README install hash matches the script ($ref)"
  else nok "README install hash matches the script ($ref)" "README=$got $ref=$want (update the install snippet)"; fi

  if grep -q "raw.githubusercontent.com/ABDUAZIZX/claude-desktop-userland/v$SELF_VERSION/claude-desktop-userland.sh" "$readme"; then
    ok "README install URL points at tag v$SELF_VERSION"
  else
    nok "README install URL points at tag v$SELF_VERSION"
  fi

  # the snippet's signature step downloads release assets of the same version
  local dl
  dl="$(grep -oE 'releases/download/v[0-9][0-9.]*/[A-Za-z0-9._-]+' "$readme" | sort -u | tr '\n' ' ')"
  if [ "$dl" = "releases/download/v$SELF_VERSION/SHA256SUMS releases/download/v$SELF_VERSION/SHA256SUMS.sig " ]; then
    ok "README signature step downloads SHA256SUMS and .sig of v$SELF_VERSION"
  else
    nok "README signature step downloads SHA256SUMS and .sig of v$SELF_VERSION" "found: ${dl:-none}"
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

# --- offline trust chain: Date floor raised in every mode ---------------------
# A throwaway gpg key signs a real InRelease; a fake curl serves it, the key,
# the Packages index and a small .deb from local files. main() then runs
# unmodified, with KEY_FPR/REPO_BASE pointed at the fixture.
make_repo_fixture() {
  local fx="$1" date_e="$2" ver="$3" app="${4:-}" arch gh pkgsha pkgsize relsha
  case "$(uname -m)" in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; *) return 1 ;; esac
  mkdir -p "$fx/gnupg" "$fx/srv/pool"; chmod 700 "$fx/gnupg"
  gh="$fx/gnupg"
  if [ ! -f "$fx/srv/key.asc" ]; then
    GNUPGHOME="$gh" gpg --batch --quiet --passphrase '' --quick-gen-key 'cdu test <test@example.invalid>' ed25519 sign never 2>/dev/null || return 1
    GNUPGHOME="$gh" gpg --batch --quiet --armor --export 2>/dev/null >"$fx/srv/key.asc"
    GNUPGHOME="$gh" gpg --batch --with-colons --list-keys 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}' >"$fx/fpr"
  fi
  make_deb "$fx/srv/pool/pkg.deb" xz "$app"
  pkgsha="$(sha256sum "$fx/srv/pool/pkg.deb" | cut -d' ' -f1)"
  printf 'Package: claude-desktop\nVersion: %s\nArchitecture: %s\nFilename: pool/pkg.deb\nSHA256: %s\n\n' \
    "$ver" "$arch" "$pkgsha" >"$fx/srv/Packages"
  pkgsize="$(stat -c %s "$fx/srv/Packages")"; relsha="$(sha256sum "$fx/srv/Packages" | cut -d' ' -f1)"
  {
    printf 'Origin: Test\nSuite: stable\n'
    printf 'Date: %s\n' "$(date -u -R -d "@$date_e")"
    printf 'Valid-Until: %s\n' "$(date -u -R -d "@$((date_e + 7 * 86400))")"
    printf 'SHA256:\n %s %s main/binary-%s/Packages\n' "$relsha" "$pkgsize" "$arch"
  } >"$fx/Release"
  # a failure here surfaces as a missing InRelease in the assertions below
  GNUPGHOME="$gh" gpg --batch --quiet --yes --clearsign --digest-algo SHA512 -o "$fx/srv/InRelease" "$fx/Release" 2>/dev/null
}

# run_main_offline FIXTURE HOME ARGS... -- main() against the fixture, no network
run_main_offline() {
  local fx="$1" home="$2"; shift 2
  local fcurl="$fx/bin"
  mkdir -p "$fcurl"
  # fake curl: last arg is the URL, "-o FILE" or "-...o FILE" gives the output
  cat >"$fcurl/curl" <<FAKE
#!/bin/sh
out=""; url=""; prev=""
for a in "\$@"; do
  case "\$prev" in -o|-*o) out="\$a" ;; esac
  prev="\$a"; url="\$a"
done
case "\$url" in
  */key.asc)                  cp "$fx/srv/key.asc" "\$out" ;;
  */dists/stable/InRelease)   cp "$fx/srv/InRelease" "\$out" ;;
  */dists/stable/main/*/Packages) cp "$fx/srv/Packages" "\$out" ;;
  */pool/pkg.deb)             cp "$fx/srv/pool/pkg.deb" "\$out" ;;
  *) echo "fake curl: unexpected URL \$url" >&2; exit 22 ;;
esac
FAKE
  chmod +x "$fcurl/curl"
  env HOME="$home" PATH="$fcurl:$PATH" bash -c '
    . "$1"; shift
    KEY_FPR="$(cat "$FX/fpr")"
    REPO_BASE="https://fixture.invalid/apt/stable"
    main "$@"' _ "$SCRIPT" "$@" 2>&1
}

t_date_floor_modes() {
  if ! command -v gpg >/dev/null 2>&1; then
    skip "offline trust chain (Date floor per mode)" "gpg not installed"; return 0
  fi
  local fx="$WORK/repo" now date1 date2 st mode out home
  now="$(date -u +%s)"; date1=$((now - 3600)); date2=$((now - 60))
  make_repo_fixture "$fx" "$date1" 1.2.3 || { nok "build signed repository fixture"; return 0; }
  # the subshell in run_main_offline reads the fixture path from FX
  export FX="$fx"

  for mode in --check --inspect --force install; do
    home="$WORK/h${mode//-/}"; mkdir -p "$home"
    st="$home/.local/share/claude-desktop/state/last-release-date"
    if [ "$mode" = install ]; then
      # pretend 1.2.3 is installed: the run ends with "already up to date"
      mkdir -p "$home/.local/share/claude-desktop/versions/1.2.3"
      ln -sfn "$home/.local/share/claude-desktop/versions/1.2.3" "$home/.local/share/claude-desktop/current"
      out="$(run_main_offline "$fx" "$home")"
      grep -q 'already up to date' <<<"$out" || nok "fixture run reaches 'already up to date'" "$out"
    else
      out="$(run_main_offline "$fx" "$home" "$mode")"
    fi
    local label="${mode#--} mode"
    [ "$mode" = install ] && label="install mode, already up to date"
    if [ "$(cat "$st" 2>/dev/null)" = "$date1" ]; then
      ok "Date floor raised in $label"
    else
      nok "Date floor raised in $label" "state=$(cat "$st" 2>/dev/null) want=$date1: $(tail -n 5 <<<"$out")"
    fi
  done

  # a newer index raises the floor even in --check
  home="$WORK/hcheck"; st="$home/.local/share/claude-desktop/state/last-release-date"
  make_repo_fixture "$fx" "$date2" 1.2.3
  run_main_offline "$fx" "$home" --check >/dev/null
  [ "$(cat "$st")" = "$date2" ] && ok "newer index raises the floor in check mode" || nok "newer index raises the floor in check mode" "$(cat "$st")"

  # an older index is refused and the floor stays
  make_repo_fixture "$fx" "$date1" 1.2.3
  out="$(run_main_offline "$fx" "$home" --check)"
  if grep -q 'older repository index refused' <<<"$out" && [ "$(cat "$st")" = "$date2" ]; then
    ok "older index refused, floor unchanged"
  else
    nok "older index refused, floor unchanged" "state=$(cat "$st"): $(tail -n 3 <<<"$out")"
  fi
  # with --allow-downgrade it passes, and the floor still does not move back
  out="$(run_main_offline "$fx" "$home" --check --allow-downgrade)"
  if grep -q 'OLDER INDEX' <<<"$out" && [ "$(cat "$st")" = "$date2" ]; then
    ok "--allow-downgrade accepts the older index without lowering the floor"
  else
    nok "--allow-downgrade accepts the older index without lowering the floor" "state=$(cat "$st"): $(tail -n 3 <<<"$out")"
  fi

  # a bad signature never touches the floor
  home="$WORK/hbadsig"; st="$home/.local/share/claude-desktop/state/last-release-date"; mkdir -p "$home"
  make_repo_fixture "$fx" "$date2" 1.2.3
  sed -i 's/^Suite: stable$/Suite: tampered/' "$fx/srv/InRelease"
  out="$(run_main_offline "$fx" "$home" --check)"
  if grep -q 'signature verification FAILED' <<<"$out" && [ ! -e "$st" ]; then
    ok "tampered InRelease refused, no Date recorded"
  else
    nok "tampered InRelease refused, no Date recorded" "$(tail -n 3 <<<"$out")"
  fi
  unset FX
}

# --- CHANGELOG has a dated entry for the script's version ---------------------
# changelog_dated_heading FILE VERSION -- prints the date if "## VERSION (YYYY-MM-DD)"
# exists with a real calendar date
changelog_dated_heading() {
  local d
  d="$(sed -n "s/^## ${2//./\\.} (\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\))$/\1/p" "$1" | head -n1)"
  [ -n "$d" ] || return 1
  [ "$(date -u -d "$d" +%F 2>/dev/null)" = "$d" ] || return 1
  echo "$d"
}

t_changelog() {
  local cl="$HERE/../CHANGELOG.md" d f="$WORK/cl"
  if d="$(changelog_dated_heading "$cl" "$SELF_VERSION")"; then
    ok "CHANGELOG has a dated heading for $SELF_VERSION ($d)"
  else
    nok "CHANGELOG has a dated heading for $SELF_VERSION" \
      "expected a line '## $SELF_VERSION (YYYY-MM-DD)'; see RELEASING.md step 1"
  fi
  # the check itself
  mkdir -p "$f"
  printf '## 9.9.9 (unreleased)\n' >"$f/a";   expect_rc 1 "'(unreleased)' is not a dated heading" changelog_dated_heading "$f/a" 9.9.9
  printf '## 9.9.9 (2026-02-30)\n' >"$f/b";   expect_rc 1 "impossible date rejected"            changelog_dated_heading "$f/b" 9.9.9
  printf '## 9.9.90 (2026-01-01)\n' >"$f/c";  expect_rc 1 "another version does not count"      changelog_dated_heading "$f/c" 9.9.9
  printf '## 9x9x9 (2026-01-01)\n' >"$f/d";   expect_rc 1 "dots in the version are literal"     changelog_dated_heading "$f/d" 9.9.9
  printf '## Unreleased\n\n## 9.9.9 (2026-01-01)\n' >"$f/e"
  expect_rc 0 "dated heading found below an Unreleased section" changelog_dated_heading "$f/e" 9.9.9
}

# --- host-check-skipped is written only after a successful install ----------
t_skip_record_timing() {
  if ! command -v gpg >/dev/null 2>&1; then
    skip "host-check-skipped record timing" "gpg not installed"; return 0
  fi
  local fx="$WORK/repo-rec" home rec out now
  now="$(date -u +%s)"
  export FX="$fx"

  # the fixture payload has no executable: install stops in step_locate_app,
  # after extraction -- no record may be left
  make_repo_fixture "$fx" $((now - 60)) 2.0.0 || { nok "build fixture (no app)"; return 0; }
  home="$WORK/hrec-fail"; mkdir -p "$home"
  rec="$home/.local/share/claude-desktop/package-meta/2.0.0/host-check-skipped"
  out="$(run_main_offline "$fx" "$home" --force --skip-host-check)"
  if grep -q 'could not identify the main executable' <<<"$out" && [ ! -e "$rec" ]; then
    ok "install failing after extraction leaves no host-check-skipped record"
  else
    nok "install failing after extraction leaves no host-check-skipped record" "record=$( [ -e "$rec" ] && echo present || echo absent): $(tail -n 3 <<<"$out")"
  fi

  # same with a complete payload: the install succeeds and the record is written
  make_repo_fixture "$fx" $((now - 30)) 2.0.0 app || { nok "build fixture (app)"; return 0; }
  home="$WORK/hrec-ok"; mkdir -p "$home"
  rec="$home/.local/share/claude-desktop/package-meta/2.0.0/host-check-skipped"
  out="$(run_main_offline "$fx" "$home" --force --skip-host-check)"
  if [ -L "$home/.local/share/claude-desktop/current" ] && [ -f "$rec" ] \
     && grep -q '^option=--skip-host-check$' "$rec" \
     && grep -q 'glibc check: 2.0.0 was installed with --skip-host-check' <<<"$out"; then
    ok "successful install writes the record and the post-install check reports it"
  else
    nok "successful install writes the record and the post-install check reports it" "$(tail -n 5 <<<"$out")"
  fi
  unset FX
}

# Test groups register themselves here.
TESTS=(t_sourcing t_apparmor t_libs t_extract t_release_dates t_downgrade t_date_floor t_skip_record t_readme t_version_format t_date_floor_modes t_changelog t_skip_record_timing t_readme_git t_payload_verdict t_fail_ids t_release_sums t_rollback)

t_readme_git() {
  if ! command -v git >/dev/null 2>&1; then
    skip "README hash source: tag, working copy, git failure" "git not installed"; return 0
  fi
  local d="$WORK/readme-git" out rc
  mkdir -p "$d/plain" "$d/broken"
  git -C "$d/plain" init -q
  git -C "$d/plain" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  out="$(released_script_ref "$d/plain" v9.9.9)"; rc=$?
  if [ "$rc" = 0 ] && [ "$out" = working ]; then ok "missing tag falls back to the working copy"
  else nok "missing tag falls back to the working copy" "rc=$rc out=$out"; fi
  git -C "$d/plain" tag v9.9.9
  out="$(released_script_ref "$d/plain" v9.9.9)"; rc=$?
  if [ "$rc" = 0 ] && [ "$out" = tag ]; then ok "existing tag is used"
  else nok "existing tag is used" "rc=$rc out=$out"; fi
  # a .git file pointing nowhere: git itself fails
  printf 'gitdir: %s/nonexistent\n' "$d" >"$d/broken/.git"
  out="$(released_script_ref "$d/broken" v9.9.9)"; rc=$?
  if [ "$rc" = 2 ] && grep -q 'git cannot read' <<<"$out"; then ok "git failure is an error, not a fall back"
  else nok "git failure is an error, not a fall back" "rc=$rc out=$out"; fi
  # git missing from PATH entirely
  out="$(PATH="$WORK/empty-path" released_script_ref "$d/plain" v9.9.9 2>&1)"; rc=$?
  if [ "$rc" = 2 ]; then ok "missing git is an error, not a fall back"
  else nok "missing git is an error, not a fall back" "rc=$rc out=$out"; fi
}

# payload-verdict.sh, the distros workflow's judgement of a live install.
t_payload_verdict() {
  local d="$WORK/verdict" v="$HERE/payload-verdict.sh" aa
  mkdir -p "$d"
  printf '1\n' >"$d/sysctl"
  aa="$( (HOST_FAIL=0; check_userns "$d/sysctl" "$d/no-profile") 2>&1 )"
  { printf '%s\n' "$aa"; c_warn "Claude Desktop 1.0 installed, but the problems marked [fail] above will stop it from running"; } >"$d/aa.log" 2>&1
  { cat "$d/aa.log"; h_fail missing-libs "missing shared libraries:"; } >"$d/aa-libs.log" 2>&1
  # same marker, different wording: must still be accepted
  { h_fail apparmor-userns "reworded: user namespaces are restricted by AppArmor"; c_warn "installed, but the problems marked [fail:...] above will stop it from running"; } >"$d/aa-reworded.log" 2>&1
  # the old prose without the marker: must not be accepted
  { c_err "AppArmor restricts unprivileged user namespaces (Ubuntu 24.04+): the renderer sandbox cannot start"; } >"$d/aa-unmarked.log" 2>&1
  { h_fail apparmor-userns "x"; h_fail apparmor-userns "x"; } >"$d/aa-twice.log" 2>&1
  c_ok "all good" >"$d/clean.log" 2>&1
  die_msg() { c_err "$1"; }
  die_msg "could not download signing key" >"$d/net.log" 2>&1
  die_msg "repository index failed the freshness check" >"$d/stale.log" 2>&1
  die_msg "InRelease signature verification FAILED" >"$d/sig.log" 2>&1

  expect_rc 0 "verdict: only the AppArmor [fail] with rc=1 is accepted" bash "$v" "$d/aa.log" 1 installed
  expect_rc 1 "verdict: AppArmor plus a library [fail] is rejected" bash "$v" "$d/aa-libs.log" 1 installed
  expect_rc 0 "verdict: matches the marker, not the wording" bash "$v" "$d/aa-reworded.log" 1 installed
  expect_rc 1 "verdict: the AppArmor text without the marker is rejected" bash "$v" "$d/aa-unmarked.log" 1 installed
  expect_rc 1 "verdict: two failure lines are rejected even with the same marker" bash "$v" "$d/aa-twice.log" 1 installed
  expect_rc 1 "verdict: rc=1 without any [fail] line is rejected" bash "$v" "$d/clean.log" 1 installed
  expect_rc 1 "verdict: rc other than 1 is rejected" bash "$v" "$d/aa.log" 2 installed
  expect_rc 0 "verdict: rc=0 with a clean host check is accepted" bash "$v" "$d/clean.log" 0 installed
  expect_rc 1 "verdict: rc=0 with a [fail] line is rejected" bash "$v" "$d/aa.log" 0 installed
  expect_rc 3 "verdict: unreachable repository is reported as such" bash "$v" "$d/net.log" 1 missing
  expect_rc 3 "verdict: stale index is reported as such" bash "$v" "$d/stale.log" 1 missing
  expect_rc 1 "verdict: a signature failure is an install failure" bash "$v" "$d/sig.log" 1 missing
  expect_out 'Live repository unavailable.*not a defect in the code' "verdict: the annotation says it is not a code defect" \
    bash "$v" "$d/net.log" 1 missing
}

# Host-check failure markers: format, use at every call site, README list.
t_fail_ids() {
  local out ids readme_ids bad
  out="$( (h_fail some-id "message text"; echo "rc=$HOST_FAIL") 2>&1 | sed 's/\x1b\[[0-9;]*m//g')"
  if [ "$out" = "$(printf '[fail:some-id] message text\nrc=1')" ]; then ok "h_fail prints [fail:ID] and sets HOST_FAIL"
  else nok "h_fail prints [fail:ID] and sets HOST_FAIL" "$out"; fi

  # every call passes an ID first; a call starting with a quoted message has none
  bad="$(grep -nE '^[[:space:]]*h_fail[[:space:]]' "$SCRIPT" | grep -vE 'h_fail [a-z0-9-]+ "' || true)"
  if [ -z "$bad" ]; then ok "every h_fail call passes a marker ID"
  else nok "every h_fail call passes a marker ID" "$bad"; fi

  ids="$(sed -nE 's/^[[:space:]]*h_fail ([a-z0-9-]+) ".*/\1/p' "$SCRIPT" | sort -u)"
  readme_ids="$(sed -n '/<!-- fail-ids:begin -->/,/<!-- fail-ids:end -->/p' "$HERE/../README.md" \
    | sed -nE 's/^\| `([a-z0-9-]+)` \|.*/\1/p' | sort -u)"
  if [ -n "$ids" ] && [ "$ids" = "$readme_ids" ]; then ok "README lists exactly the marker IDs the script uses"
  else nok "README lists exactly the marker IDs the script uses" "$(diff <(printf '%s\n' "$ids") <(printf '%s\n' "$readme_ids"))"; fi

  # the verdict's expected marker is the one check_userns really prints
  local d="$WORK/fail-ids" want
  mkdir -p "$d"; printf '1\n' >"$d/sysctl"
  want="$(sed -nE "s/^EXPECTED='([a-z0-9-]+)'$/\1/p" "$HERE/payload-verdict.sh")"
  out="$( (HOST_FAIL=0; check_userns "$d/sysctl" "$d/no-profile") 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E '^\[fail:' )"
  if [ -n "$want" ] && [ "${out%%]*}]" = "[fail:$want]" ]; then ok "payload verdict expects the marker check_userns prints ($want)"
  else nok "payload verdict expects the marker check_userns prints ($want)" "check_userns printed: $out"; fi
}

# tools/release-sums.sh with a throwaway SSH key and a throwaway repository.
t_release_sums() {
  if ! command -v ssh-keygen >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
    skip "release SHA256SUMS signing and verification" "ssh-keygen or git not installed"; return 0
  fi
  local d="$WORK/sums" tool="$HERE/../tools/release-sums.sh" id="release@example.invalid"
  mkdir -p "$d/repo"
  ssh-keygen -q -t ed25519 -N '' -C test -f "$d/key"
  ssh-keygen -q -t ed25519 -N '' -C other -f "$d/other"
  printf '%s namespaces="git,file" %s\n' "$id" "$(cat "$d/key.pub")" >"$d/allowed"
  # a second key git also trusts, to sign a tag that impersonates the first
  printf 'other@example.invalid namespaces="git" %s\n' "$(cat "$d/other.pub")" >>"$d/allowed"
  printf '%s namespaces="file" %s\n' "$id" "$(cat "$d/other.pub")" >"$d/allowed-other"
  g() { git -C "$d/repo" -c user.name=t -c user.email="$id" -c gpg.format=ssh \
          -c user.signingkey="$d/key.pub" -c gpg.ssh.allowedSignersFile="$d/allowed" "$@"; }
  g init -q
  printf '#!/bin/sh\necho released\n' >"$d/repo/claude-desktop-userland.sh"
  g add claude-desktop-userland.sh
  g commit -q -m release
  g tag -s v9.9.9 -m v9.9.9
  g tag v9.9.8            # lightweight, unsigned
  g tag -a v9.9.7 -m v9.9.7   # annotated, unsigned
  # validly signed by the OTHER key, message imitating a good signature by the
  # release key: git tag -v succeeds, so only a direct check catches it
  git -C "$d/repo" -c user.name=t -c user.email=other@example.invalid -c gpg.format=ssh \
      -c user.signingkey="$d/other.pub" tag -s v9.9.5 \
      -m "$(printf 'Good "git" signature for %s with ED25519 key %s\n' "$id" "$(ssh-keygen -lf "$d/key.pub" | awk '{print $2}')")"
  # annotated, unsigned, whose message imitates a verification line
  g tag -a v9.9.6 -m "$(printf 'Good "git" signature for %s with ED25519 key %s\n' "$id" "$(ssh-keygen -lf "$d/key.pub" | awk '{print $2}')")"

  # make runs inside the repository and reads git config; pass the same -c set via env
  local cfg=(GIT_CONFIG_COUNT=3
             GIT_CONFIG_KEY_0=gpg.format GIT_CONFIG_VALUE_0=ssh
             GIT_CONFIG_KEY_1=user.signingkey GIT_CONFIG_VALUE_1="$d/key.pub"
             GIT_CONFIG_KEY_2=gpg.ssh.allowedSignersFile GIT_CONFIG_VALUE_2="$d/allowed")
  expect_rc 0 "release-sums make: signed tag, same key" \
    bash -c 'cd "$1" && shift && env "$@"' _ "$d/repo" "${cfg[@]}" bash "$tool" make v9.9.9 "$d/out"
  if [ "$(cat "$d/out/SHA256SUMS" 2>/dev/null)" = "$(cd "$d/repo" && git show v9.9.9:claude-desktop-userland.sh | sha256sum | sed 's/-$/claude-desktop-userland.sh/')" ]; then
    ok "SHA256SUMS holds the hash of the script at the tag"
  else nok "SHA256SUMS holds the hash of the script at the tag" "$(cat "$d/out/SHA256SUMS" 2>&1)"; fi
  expect_rc 0 "release-sums verify: good signature and files" bash "$tool" verify "$d/out" "$d/allowed"
  expect_rc 1 "release-sums verify: a key not in allowed_signers is refused" bash "$tool" verify "$d/out" "$d/allowed-other"

  cp -r "$d/out" "$d/tampered-sums"
  sed -i 's/^./0/' "$d/tampered-sums/SHA256SUMS"
  expect_rc 1 "release-sums verify: edited SHA256SUMS is refused" bash "$tool" verify "$d/tampered-sums" "$d/allowed"
  cp -r "$d/out" "$d/tampered-file"
  echo '# extra' >>"$d/tampered-file/claude-desktop-userland.sh"
  expect_rc 1 "release-sums verify: edited script is refused" bash "$tool" verify "$d/tampered-file" "$d/allowed"

  expect_out 'v9.9.8 is not an annotated tag' "release-sums make: lightweight (unsigned) tag is refused" \
    bash -c 'cd "$1" && shift && env "$@"' _ "$d/repo" "${cfg[@]}" bash "$tool" make v9.9.8 "$d/out-unsigned"
  expect_out 'tag v9.9.7 has no SSH signature' "release-sums make: annotated unsigned tag is refused" \
    bash -c 'cd "$1" && shift && env "$@"' _ "$d/repo" "${cfg[@]}" bash "$tool" make v9.9.7 "$d/out-annotated"
  expect_out 'tag v9.9.6 has no SSH signature' "release-sums make: a message imitating a good signature is refused" \
    bash -c 'cd "$1" && shift && env "$@"' _ "$d/repo" "${cfg[@]}" bash "$tool" make v9.9.6 "$d/out-imitation"
  expect_out 'tag v9.9.5 is not signed by' "release-sums make: tag signed by another trusted key, message imitating the release key, is refused" \
    bash -c 'cd "$1" && shift && env "$@"' _ "$d/repo" "${cfg[@]}" bash "$tool" make v9.9.5 "$d/out-impersonation"
  expect_out 'tag v9.9.9 is not signed by' "release-sums make: a key other than the tag's is refused" \
    bash -c 'cd "$1" && shift && env "$@"' _ "$d/repo" "${cfg[@]}" bash "$tool" make v9.9.9 "$d/out-other" "$d/other"
  expect_out 'already holds SHA256SUMS' "release-sums make: existing SHA256SUMS is not overwritten" \
    bash -c 'cd "$1" && shift && env "$@"' _ "$d/repo" "${cfg[@]}" bash "$tool" make v9.9.9 "$d/out"
}

# --rollback: fixture homes with retained versions; everything offline.
mk_rb_home() {  # mk_rb_home HOME CURRENT-VERSION OTHER-VERSION...
  local h="$1" cur="$2" v; shift 2
  local vers="$h/.local/share/claude-desktop/versions"
  for v in "$cur" "$@"; do
    mkdir -p "$vers/$v"
    printf '#!/bin/sh\necho %s\n' "$v" >"$vers/$v/claude-desktop"
    chmod +x "$vers/$v/claude-desktop"
  done
  ln -sfn "$vers/$cur" "$h/.local/share/claude-desktop/current"
  mkdir -p "$h/.local/bin" "$h/.local/share/claude-desktop/state"
  printf 'APP="$HOME/.local/share/claude-desktop/current/claude-desktop"\n' >"$h/.local/bin/claude-desktop"
  printf '1700000000\n' >"$h/.local/share/claude-desktop/state/last-release-date"
}
rb_cur() { basename "$(readlink -f "$1/.local/share/claude-desktop/current")"; }

t_rollback() {
  local d="$WORK/rollback" h out rc
  mkdir -p "$d"

  h="$d/basic"; mk_rb_home "$h" 2.0.0 1.0.0
  out="$(env HOME="$h" PATH="$STUBS:$PATH" bash -c '. "$1"; set -euo pipefail; rollback_switch; echo "$ROLLBACK_FROM->$ROLLBACK_TO"' _ "$SCRIPT" 2>&1)"; rc=$?
  if [ "$rc" = 0 ] && [ "$out" = "2.0.0->1.0.0" ] && [ "$(rb_cur "$h")" = 1.0.0 ]; then ok "rollback switches current to the other version"
  else nok "rollback switches current to the other version" "rc=$rc out=$out current=$(rb_cur "$h")"; fi
  [ ! -e "$h/.local/share/claude-desktop/current.rollback" ] && ok "rollback leaves no temporary link" || nok "rollback leaves no temporary link"
  if [ "$(cat "$h/.local/share/claude-desktop/state/last-release-date")" = 1700000000 ]; then ok "rollback leaves the Date floor untouched"
  else nok "rollback leaves the Date floor untouched"; fi
  out="$(env HOME="$h" PATH="$STUBS:$PATH" bash -c '. "$1"; set -euo pipefail; rollback_switch; echo "$ROLLBACK_FROM->$ROLLBACK_TO"' _ "$SCRIPT" 2>&1)"
  [ "$out" = "1.0.0->2.0.0" ] && ok "a second rollback switches back" || nok "a second rollback switches back" "$out"

  # main --rollback: offline (curl/gpg stubs fail loudly if called)
  h="$d/main"; mk_rb_home "$h" 2.0.0 1.0.0
  out="$(env HOME="$h" PATH="$STUBS:$PATH" bash "$SCRIPT" --rollback 2>&1)"
  if ! grep -q 'test stub' <<<"$out" && grep -q 'rolled back: 2.0.0 -> 1.0.0' <<<"$out" && [ "$(rb_cur "$h")" = 1.0.0 ]; then
    ok "--rollback runs offline and reports the switch"
  else nok "--rollback runs offline and reports the switch" "$out"; fi
  grep -q 'host check' <<<"$out" && ok "--rollback runs the host check afterwards" || nok "--rollback runs the host check afterwards" "$out"

  # host check verdict decides the exit code, as after an install
  h="$d/verdict-ok"; mk_rb_home "$h" 2.0.0 1.0.0
  expect_rc 0 "--rollback exits 0 when the host check passes" \
    env HOME="$h" PATH="$STUBS:$PATH" bash -c '. "$1"; set -euo pipefail; run_host_checks() { HOST_FAIL=0; }; do_rollback' _ "$SCRIPT"
  h="$d/verdict-fail"; mk_rb_home "$h" 2.0.0 1.0.0
  expect_rc 1 "--rollback exits 1 when the host check fails" \
    env HOME="$h" PATH="$STUBS:$PATH" bash -c '. "$1"; set -euo pipefail; run_host_checks() { HOST_FAIL=1; }; do_rollback' _ "$SCRIPT"

  # a host-check-skipped record of the version switched to is reported
  h="$d/record"; mk_rb_home "$h" 2.0.0 1.0.0
  mkdir -p "$h/.local/share/claude-desktop/package-meta/1.0.0"
  printf 'option=--skip-host-check\nglibc=2.31\nfloor_violated=1\n' >"$h/.local/share/claude-desktop/package-meta/1.0.0/host-check-skipped"
  out="$(env HOME="$h" PATH="$STUBS:$PATH" bash -c '. "$1"; set -euo pipefail; rollback_switch; HOST_FAIL=0; check_host_check_record; echo "HF=$HOST_FAIL"' _ "$SCRIPT" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')"
  if grep -q '^\[fail:glibc-check-skipped\] .*1\.0\.0 was installed with --skip-host-check' <<<"$out" && grep -q 'HF=1' <<<"$out"; then
    ok "the target's host-check-skipped record is reported after rollback"
  else nok "the target's host-check-skipped record is reported after rollback" "$out"; fi

  # with three versions left by hand, the newest other one is chosen
  h="$d/three"; mk_rb_home "$h" 2.0.0 1.0.0 1.5.0
  env HOME="$h" PATH="$STUBS:$PATH" bash -c '. "$1"; set -euo pipefail; rollback_switch' _ "$SCRIPT" >/dev/null 2>&1
  [ "$(rb_cur "$h")" = 1.5.0 ] && ok "with three versions the newest other one is chosen" || nok "with three versions the newest other one is chosen" "$(rb_cur "$h")"

  # refusals: nothing changes
  rb_refuse() {  # rb_refuse NAME PATTERN HOME
    local out rc before
    before="$(readlink "$3/.local/share/claude-desktop/current" 2>/dev/null || echo none)"
    out="$(env HOME="$3" PATH="$STUBS:$PATH" bash -c '. "$1"; set -euo pipefail; rollback_switch' _ "$SCRIPT" 2>&1)"; rc=$?
    if [ "$rc" != 0 ] && grep -qE -- "$2" <<<"$out" \
       && [ "$(readlink "$3/.local/share/claude-desktop/current" 2>/dev/null || echo none)" = "$before" ]; then ok "$1"
    else nok "$1" "rc=$rc out=$out"; fi
  }
  h="$d/single"; mk_rb_home "$h" 2.0.0
  rb_refuse "rollback refused with a single version" 'no previous version' "$h"
  h="$d/malformed"; mk_rb_home "$h" 2.0.0 '1.0~rc1'
  rb_refuse "rollback refused for a version not of the form N(.N)*" 'not of the form' "$h"
  h="$d/nobin"; mk_rb_home "$h" 2.0.0 1.0.0
  rm "$h/.local/share/claude-desktop/versions/1.0.0/claude-desktop"
  rb_refuse "rollback refused when the other version lacks its binary" 'incomplete' "$h"
  h="$d/noexec"; mk_rb_home "$h" 2.0.0 1.0.0
  chmod -x "$h/.local/share/claude-desktop/versions/1.0.0/claude-desktop"
  rb_refuse "rollback refused when the binary is not executable" 'incomplete' "$h"
  h="$d/empty"; mkdir -p "$h"
  rb_refuse "rollback refused when nothing is installed" 'nothing installed' "$h"

  expect_rc 1 "--rollback cannot be combined with --allow-downgrade" parse_args --rollback --allow-downgrade
  expect_rc 1 "--rollback cannot be combined with --skip-host-check" parse_args --rollback --skip-host-check

  # the next plain install moves forward again: not a downgrade from the rolled-back version
  expect_rc 0 "after rollback, the newer repository version is not a downgrade" check_version_order 1.0.0 2.0.0 0
}

for t in "${TESTS[@]}"; do "$t"; done

printf '\n%d passed, %d skipped, %d failed\n' "$PASS" "$SKIP" "$FAIL"
if [ "$NO_SKIP" = 1 ] && [ "$SKIP" -gt 0 ]; then
  printf 'FAIL --no-skip: %d test(s) skipped\n' "$SKIP"
  exit 1
fi
[ "$FAIL" = 0 ]
