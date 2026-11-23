#!/usr/bin/env bash
# Sandbox check for the "distros" CI workflow. Runs directly on an Ubuntu
# 24.04+ host (no container: a container shares the host's AppArmor sysctl and
# runs Electron as root, so it says nothing about the sandbox), as an
# unprivileged user with passwordless sudo, after a real install into $HOME.
#
# Usage: bash tests/sandbox-check.sh
#
# Steps, each one an assertion:
#   1. the host restricts unprivileged user namespaces (otherwise the test
#      would prove nothing)
#   2. --doctor reports the restriction while no profile is loaded
#   3. without the profile, the app does not get a sandboxed renderer
#      (negative control: shows step 5 can fail)
#   4. the profile from --print-apparmor-profile loads with apparmor_parser
#   5. with it, a renderer runs in a user namespace other than the app's main
#      process, and --no-sandbox is nowhere on its command line
# Each launch runs under Xvfb for at most 60 seconds, then the app's process
# group is terminated. App logs go to $SANDBOX_LOG_DIR when set.
#   6. the profile is unloaded and removed again

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../claude-desktop-userland.sh"
LAUNCHER="$HOME/.local/bin/claude-desktop"
PROFILE_NAME="claude-desktop-userland"
PROFILE_FILE="/etc/apparmor.d/$PROFILE_NAME"
SYSCTL="/proc/sys/kernel/apparmor_restrict_unprivileged_userns"
WAIT=60                      # seconds under Xvfb before the app is stopped
WORK="$(mktemp -d -t cdu-sandbox.XXXXXXXX)"
# App logs land here; CI uploads the directory when the job fails.
LOGS="${SANDBOX_LOG_DIR:-$WORK/logs}"
mkdir -p "$LOGS"
APP_PGID=""

cleanup() {
  stop_app
  if [ -f "$PROFILE_FILE" ]; then
    sudo apparmor_parser -R "$PROFILE_FILE" 2>/dev/null || true
    sudo rm -f "$PROFILE_FILE"
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
ok()   { printf 'ok   %s\n' "$*"; }
strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }

stop_app() {
  [ -n "$APP_PGID" ] || return 0
  kill -TERM -- "-$APP_PGID" 2>/dev/null || true
  sleep 2
  kill -KILL -- "-$APP_PGID" 2>/dev/null || true
  APP_PGID=""
}

# start_app LOG -- launch through the generated launcher, in its own process
# group (setsid in a non-interactive shell: its PID is the group ID), on a
# virtual display with a private session bus.
start_app() {
  setsid xvfb-run -a dbus-run-session -- "$LAUNCHER" >"$1" 2>&1 &
  APP_PGID=$!
}

app_running() { kill -0 -- "-$APP_PGID" 2>/dev/null; }

# Processes running the installed main binary: "<pid> <type>", type "browser"
# for the main process (no --type= argument), the --type value otherwise.
# Helpers such as chrome_crashpad_handler are a different executable and are
# left out, so "browser" is always the app's own main process.
app_procs() {
  local bin p exe t
  bin="$(sed -n 's|^APP="\$HOME/\.local/share/claude-desktop/current/\(.*\)"$|\1|p' "$LAUNCHER")"
  [ -n "$bin" ] || fail "cannot read the binary name from $LAUNCHER"
  bin="$(readlink -f "$HOME/.local/share/claude-desktop/current/$bin")"
  for p in $(pgrep -f -- "$(dirname "$bin")/" || true); do
    exe="$(readlink -f "/proc/$p/exe" 2>/dev/null)" || continue
    [ "$exe" = "$bin" ] || continue
    t="$(tr '\0 ' '\n\n' <"/proc/$p/cmdline" 2>/dev/null | sed -n 's/^--type=//p' | head -n1)" || continue
    printf '%s %s\n' "$p" "${t:-browser}"
  done
}

# sandboxed_renderer LOG -- 0 when, within WAIT seconds, a renderer of this
# install runs in a user namespace other than the app's main (browser)
# process, without --no-sandbox; 1 otherwise. The app is stopped either way.
sandboxed_renderer() {
  local log="$1" procs main main_ns p ns _ rc=1
  for _ in $(seq 1 "$WAIT"); do
    procs="$(app_procs)"
    main="$(awk '$2=="browser" {print $1; exit}' <<<"$procs")"
    main_ns="$( [ -n "$main" ] && readlink "/proc/$main/ns/user" 2>/dev/null || true)"
    if [ -n "$main_ns" ]; then
      for p in $(awk '$2=="renderer" {print $1}' <<<"$procs"); do
        if tr '\0 ' '\n\n' <"/proc/$p/cmdline" 2>/dev/null | grep -qx -- '--no-sandbox'; then
          printf 'renderer %s runs with --no-sandbox\n' "$p" >&2
          break 2
        fi
        ns="$(readlink "/proc/$p/ns/user" 2>/dev/null)" || continue
        if [ "$ns" != "$main_ns" ]; then
          printf 'renderer %s: %s; main process %s: %s\n' "$p" "$ns" "$main" "$main_ns"
          rc=0; break 2
        fi
      done
    fi
    # Chromium aborts at startup when no sandbox is usable
    grep -q 'No usable sandbox' "$log" 2>/dev/null && break
    app_running || break
    sleep 1
  done
  stop_app
  return "$rc"
}

# --- 1. the restriction is active ------------------------------------------
[ -x "$LAUNCHER" ] || fail "launcher $LAUNCHER missing: run the installer first"
[ "$(cat "$SYSCTL" 2>/dev/null || echo 0)" = 1 ] \
  || fail "$SYSCTL is not 1 on this host; the sandbox check would prove nothing"
ok "AppArmor restricts unprivileged user namespaces on this host"
[ ! -e "$PROFILE_FILE" ] || fail "$PROFILE_FILE already exists before the test"

# --- 2. --doctor reports it ------------------------------------------------
out="$(bash "$SCRIPT" --doctor 2>&1 | strip_ansi || true)"
grep -q 'AppArmor restricts unprivileged user namespaces' <<<"$out" \
  || { printf '%s\n' "$out"; fail "--doctor did not report the AppArmor restriction"; }
ok "--doctor reports the restriction without a profile"

# --- 3. negative control: no sandboxed renderer without the profile ----------
start_app "$LOGS/without-profile.log"
if sandboxed_renderer "$LOGS/without-profile.log"; then
  fail "a sandboxed renderer started without the profile; this check cannot detect the restriction"
fi
ok "without the profile the renderer sandbox does not start"
grep -m3 -E 'sandbox|namespace' "$LOGS/without-profile.log" | sed 's/^/     /' || true

# --- 4. load the generated profile -----------------------------------------
bash "$SCRIPT" --print-apparmor-profile 2>/dev/null | sudo tee "$PROFILE_FILE" >/dev/null
sudo apparmor_parser -r "$PROFILE_FILE"
sudo grep -qx "$PROFILE_NAME (unconfined)" /sys/kernel/security/apparmor/profiles \
  || fail "profile $PROFILE_NAME is not listed as loaded"
ok "profile from --print-apparmor-profile loaded"

out="$(bash "$SCRIPT" --doctor 2>&1 | strip_ansi || true)"
grep -q "AppArmor restricts user namespaces; profile $PROFILE_FILE present" <<<"$out" \
  || { printf '%s\n' "$out"; fail "--doctor does not see the profile"; }
ok "--doctor reports the profile"

# --- 5. sandboxed renderer with the profile ----------------------------------
start_app "$LOGS/with-profile.log"
if ! sandboxed_renderer "$LOGS/with-profile.log"; then
  tail -n 40 "$LOGS/with-profile.log" >&2
  fail "no sandboxed renderer within ${WAIT}s with the profile loaded"
fi
ok "with the profile a renderer runs in its own user namespace"

# --- 6. unload --------------------------------------------------------------
sudo apparmor_parser -R "$PROFILE_FILE"
sudo rm -f "$PROFILE_FILE"
ok "profile unloaded and removed"
