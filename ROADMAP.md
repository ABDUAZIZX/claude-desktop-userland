# Roadmap

Planned, not implemented. Each item lists the constraint that shapes it.

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
