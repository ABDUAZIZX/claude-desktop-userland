# Roadmap

Planned, not implemented. Each item lists the constraint that shapes it.

## `--enable-auto-update`

A systemd user timer plus service that **downloads, verifies and notifies
only**.

- The timer runs the full trust chain (fingerprint, `InRelease` signature,
  `Valid-Until`, `Date` floor, `Packages` and `.deb` checksums) and stages the
  verified version under `versions/<ver>` without touching `current`.
- It then sends a desktop notification (`notify-send`, or the journal when no
  session bus is present) naming the staged version and the result of the
  `--inspect` metadata diff.
- Switching `current` to the staged version stays a manual command run by the
  user. A timer never changes what is launched.
- `--disable-auto-update` removes the units.

## `--rollback` (for 1.2.0)

Two versions are kept under `versions/` precisely so an update can be undone,
but switching back today means re-pointing the `current` link by hand.

- `--rollback` points `current` at the other retained version, offline: no
  download, no index fetch, so the `Date` floor and the downgrade check are
  untouched (they guard what the repository serves, not a local switch the
  user asks for).
- Refuses when there is no second version, when its directory is incomplete
  (main binary missing), or when its version string is not `N(.N)*`.
- Prints both versions and runs the host check on the version switched to,
  like after an install, including a `host-check-skipped` record of that
  version.
- The next plain install still moves forward to the newest version in the
  repository; `--rollback` does not pin anything.

## Signed release artifacts: install snippet

Releases from 1.2.0 on carry `SHA256SUMS` and `SHA256SUMS.sig`, signed with
the tag key and verified as documented in RELEASING.md and the README
section "Verify a release signature". The README install snippet still
checks the script against the hash in the README only, because the release it
pins (1.1.0) has no signature. Once 1.2.0 is released, the snippet gains the
signature check before `sha256sum -c`.

## Keep the weekly `distros` run alive

GitHub disables scheduled workflows in a public repository after 60 days
without repository activity, silently. The weekly run is what catches a new
upstream release that needs another library, so a quiet repository would lose
it exactly when nobody is watching.

- Options: re-enable by hand when GitHub's notice arrives, or a keep-alive
  that makes no commits (for example the workflow calling the API to re-enable
  itself with a minimal-permission token). Commits only to keep the schedule
  alive are not wanted.

## Generate the README compatibility table

The statuses in the README (Works (daily use), Launch + sandbox verified
(CI), Libraries checked (CI), Untested, Refused (CI)) are written by hand
from the `distros` results. Generating the CI rows from the last green run
of that workflow would keep them from drifting when the matrix changes.
