#!/usr/bin/env bash
# Runs the distribution checks for one container image, on the host side.
# Used by the "distros" CI workflow and usable locally with podman or docker.
#
# Usage:
#   bash tests/distro-run.sh full IMAGE APP-DIR
#       tests/run.sh --no-skip, then tests/distro-check.sh libs APP-DIR
#   bash tests/distro-run.sh refused IMAGE PATTERN
#       tests/distro-check.sh refused PATTERN (no payload needed)
#
# The repository is mounted read-only at /src and APP-DIR at /payload. The
# container runs as root so it can install packages; nothing on the host is
# changed. Set CONTAINER_ENGINE to force podman or docker.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

engine="${CONTAINER_ENGINE:-}"
if [ -z "$engine" ]; then
  if command -v podman >/dev/null 2>&1; then engine=podman
  elif command -v docker >/dev/null 2>&1; then engine=docker
  else echo "neither podman nor docker found" >&2; exit 1
  fi
fi

kind="${1:-}"; image="${2:-}"
[ -n "$image" ] || { echo "usage: distro-run.sh full IMAGE APP-DIR | refused IMAGE PATTERN" >&2; exit 2; }

# SELinux hosts (Fedora, Bluefin) would deny the container access to the
# mounts; label=disable avoids relabelling the user's files with :Z.
opts=(--rm -e LC_ALL=C.UTF-8 -v "$REPO:/src:ro")
[ "$engine" = podman ] && opts+=(--security-opt label=disable)

case "$kind" in
  full)
    app="${3:?usage: distro-run.sh full IMAGE APP-DIR}"
    app="$(cd "$app" && pwd)"
    "$engine" run "${opts[@]}" -v "$app:/payload:ro" "$image" sh -c '
      set -e
      sh /src/tests/distro-setup.sh full >/tmp/setup.log 2>&1 \
        || { tail -n 40 /tmp/setup.log; echo "FAIL setting up the container" >&2; exit 1; }
      # the checkout belongs to another uid than root in the container
      git config --global --add safe.directory "*"
      bash /src/tests/run.sh --no-skip
      echo "--- shared libraries"
      bash /src/tests/distro-check.sh libs /payload'
    ;;
  refused)
    pattern="${3:?usage: distro-run.sh refused IMAGE PATTERN}"
    "$engine" run "${opts[@]}" "$image" sh -c '
      set -e
      sh /src/tests/distro-setup.sh minimal >/tmp/setup.log 2>&1 \
        || { tail -n 40 /tmp/setup.log; echo "FAIL setting up the container" >&2; exit 1; }
      bash /src/tests/distro-check.sh refused "$1"' _ "$pattern"
    ;;
  *)
    echo "usage: distro-run.sh full IMAGE APP-DIR | refused IMAGE PATTERN" >&2; exit 2 ;;
esac
