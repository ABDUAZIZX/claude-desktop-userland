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

## Signed release artifacts

Every release carries a signature that does not come from the same place as
the file it covers:

- **Signed tag** for every version (`git tag -s`), verifiable with
  `git tag -v` against a published signing key. Unsigned tags are never
  pushed.
- **Signed `SHA256SUMS`** attached to every GitHub Release: the checksum of
  `claude-desktop-userland.sh` (and of any future asset) plus a detached
  signature over that file, with a documented verification command
  (`ssh-keygen -Y verify` against an `allowed_signers` file, or `gpg --verify`,
  depending on the key type chosen).
- The README install snippet then gains a step that verifies `SHA256SUMS`
  before `sha256sum -c`. Today the README hash and the script come from the
  same repository, which protects against a corrupted download but is not an
  independent signature.

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
