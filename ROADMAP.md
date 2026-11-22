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

## CI distribution matrix

Two kinds of job, because a container cannot test what matters most.

- **Containers** (Ubuntu 22.04 / 24.04, Debian 12 / 13, Fedora, Arch,
  openSUSE Tumbleweed, Alpine): host checks, library resolution and the
  `.deb` extraction chain only. Electron inside a container runs as root and
  needs `--no-sandbox` regardless, so a container says nothing about the
  sandbox.
- **Sandbox**: a direct run on a `ubuntu-24.04` runner, no container, as the
  runner's unprivileged user. This is the only job that exercises the AppArmor
  userns restriction and the profile from `--print-apparmor-profile`
  (load, launch headless, confirm the renderer sandbox started, unload).

## README compatibility table

Generated from the CI results, with wording that matches what was actually
tested:

- **"Libraries checked"** when only the container job ran for that
  distribution.
- **"Works"** only when the application was actually launched and the sandbox
  confirmed on that distribution.
