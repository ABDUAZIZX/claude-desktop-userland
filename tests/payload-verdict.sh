#!/usr/bin/env bash
# Verdict on a live install run by the "distros" workflow's payload job.
#
# Usage: bash tests/payload-verdict.sh LOG RC installed|missing
#   LOG        combined stdout/stderr of the installer
#   RC         the installer's exit code
#   installed  ~/.local/share/claude-desktop/current exists after the run
#
# Exit 0: accept. Exit 1: the install failed or the host check found a problem
# other than the expected one. Exit 3: the live repository was unreachable or
# served an expired / future-dated index; not a defect in this code. Reasons
# are printed as GitHub ::error:: annotations.
#
# On a GitHub ubuntu-24.04 runner the final host check fails for exactly one
# reason: AppArmor restricts unprivileged user namespaces and no profile is
# loaded (the sandbox job covers that). So rc=1 is accepted only when the
# single failure line is the installer's fixed marker [fail:apparmor-userns];
# any other marker (missing-libs, glibc-*, ...) or an unmarked [fail] line
# from die() fails the job. The marker, not the message text, is matched, so
# rewording the message does not break this verdict.

set -euo pipefail

log="${1:?usage: payload-verdict.sh LOG RC installed|missing}"
rc="${2:?usage: payload-verdict.sh LOG RC installed|missing}"
state="${3:?usage: payload-verdict.sh LOG RC installed|missing}"
[ -r "$log" ] || { echo "::error title=Install failed::installer log $log not readable"; exit 1; }

EXPECTED='apparmor-userns'

clean="$(sed 's/\x1b\[[0-9;]*m//g' "$log")"
# Failure lines start with "[fail:<id>] " (host checks) or "[fail] " (die).
# Only line starts count: the closing [warn] line mentions "[fail:...]" too.
fails="$(grep -E '^\[fail(:[a-z0-9-]+)?\] ' <<<"$clean" || true)"

if [ "$state" != installed ]; then
  if grep -qE 'could not download|download failed|failed the freshness check' <<<"$clean"; then
    echo "::error title=Live repository unavailable::downloads.claude.ai could not be reached or served an expired / future-dated index (Valid-Until / Date). This is not a defect in the code; re-run the workflow later."
    exit 3
  fi
  echo "::error title=Install failed::the installer stopped before completing (rc=$rc)"
  exit 1
fi

if [ "$rc" = 0 ]; then
  if [ -n "$fails" ]; then
    echo "::error title=Install failed::rc=0 but the output has [fail] lines"
    printf '%s\n' "$fails"
    exit 1
  fi
  echo "accepted: install completed and the host check passed"
  exit 0
fi

if [ "$rc" = 1 ] && [ -n "$fails" ] && [ "$(wc -l <<<"$fails")" = 1 ] \
   && [ "${fails%%]*}]" = "[fail:$EXPECTED]" ]; then
  echo "accepted: install completed; the only host-check failure is the expected AppArmor restriction"
  exit 0
fi

echo "::error title=Host check failed::rc=$rc; only [fail:$EXPECTED] is expected on this runner, found:"
printf '%s\n' "${fails:-(no [fail] lines)}"
exit 1
