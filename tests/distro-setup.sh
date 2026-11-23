#!/bin/sh
# Installs what the installer and tests/run.sh need inside a fresh distribution
# container, and nothing else: the libraries Claude Desktop needs are left out
# on purpose, so tests/distro-check.sh can prove the installer names them.
#
# Usage (as root, POSIX sh because bash may not be installed yet):
#   sh tests/distro-setup.sh full      tools for tests/run.sh --no-skip + checks
#   sh tests/distro-setup.sh minimal   only what a plain install needs to reach
#                                      the glibc check (refused distributions)
set -eu

level="${1:?usage: distro-setup.sh full|minimal}"
case "$level" in full|minimal) : ;; *) echo "unknown level: $level" >&2; exit 2 ;; esac

. /etc/os-release
ids=" ${ID:-} ${ID_LIKE:-} "

case "$ids" in
  *" debian "*|*" ubuntu "*)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    if [ "$level" = full ]; then
      apt-get install -y --no-install-recommends bash ca-certificates curl gnupg git \
        binutils xz-utils zstd gzip tar python3 libarchive-tools diffutils findutils gawk openssh-client
    else
      apt-get install -y --no-install-recommends bash ca-certificates curl gnupg binutils
    fi ;;
  *" fedora "*|*" rhel "*)
    if [ "$level" = full ]; then
      dnf install -y --setopt=install_weak_deps=False bash ca-certificates curl gnupg2 git-core \
        binutils xz zstd gzip tar python3 bsdtar diffutils findutils gawk glibc-common openssh
    else
      dnf install -y --setopt=install_weak_deps=False bash curl gnupg2 binutils diffutils findutils gawk
    fi ;;
  *" arch "*)
    pacman -Syu --noconfirm
    if [ "$level" = full ]; then
      pacman -S --needed --noconfirm bash ca-certificates curl gnupg git \
        binutils xz zstd gzip tar python libarchive diffutils findutils gawk openssh
    else
      pacman -S --needed --noconfirm bash curl gnupg binutils diffutils findutils gawk
    fi ;;
  *" suse "*|*" opensuse "*|*opensuse-*)
    zypper --non-interactive refresh
    if [ "$level" = full ]; then
      zypper --non-interactive install --no-recommends bash ca-certificates curl gpg2 git-core \
        binutils xz zstd gzip tar python3 bsdtar diffutils findutils gawk openssh-clients
    else
      zypper --non-interactive install --no-recommends bash curl gpg2 binutils diffutils findutils gawk
    fi ;;
  *" alpine "*)
    # musl: only the refusal is tested, so the minimal set is all there is
    apk add --no-cache bash curl gnupg binutils ;;
  *)
    echo "unsupported distribution: $ids" >&2; exit 1 ;;
esac
