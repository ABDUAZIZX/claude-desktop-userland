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
      printf 'skip zstd fixtures (zstd not installed)\n'; continue
    fi
    deb="$d/test-$comp.deb"; make_deb "$deb" "$comp"
    for tool in bsdtar ar python3; do
      if ! command -v "$tool" >/dev/null 2>&1; then
        printf 'skip %s path for %s (%s not installed)\n' "$tool" "$comp" "$tool"; continue
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
  # the old environment variable must have no effect any more
  expect_out 'SKIP=0' "CLAUDE_SKIP_HOST_CHECK env var ignored" \
    env CLAUDE_SKIP_HOST_CHECK=1 bash -c '. "$1"; parse_args; echo "SKIP=$SKIP_HOST_CHECK"' _ "$SCRIPT"
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

# Test groups register themselves here.
TESTS=(t_sourcing t_apparmor t_libs t_extract t_release_dates t_downgrade t_date_floor)

for t in "${TESTS[@]}"; do "$t"; done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
