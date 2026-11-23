#!/usr/bin/env bash
# Signed checksums for a GitHub Release.
#
# Usage:
#   bash tools/release-sums.sh make TAG OUTDIR [SIGNING-KEY]
#       Run inside the repository. Verifies the tag's signature first, then
#       writes into OUTDIR:
#         claude-desktop-userland.sh   the script as released at TAG
#         SHA256SUMS                   "<sha256>  claude-desktop-userland.sh"
#         SHA256SUMS.sig               detached SSH signature, namespace "file"
#       SIGNING-KEY defaults to git's user.signingkey. It must be the key that
#       signed TAG; any other key is refused.
#   bash tools/release-sums.sh verify DIR ALLOWED-SIGNERS
#       Checks SHA256SUMS.sig against ALLOWED-SIGNERS (namespace "file"), then
#       the files listed in SHA256SUMS. Both must pass.
#
# SSH signing keys only (gpg.format=ssh), the format used for the tags.

set -euo pipefail

NS="file"
ASSET="claude-desktop-userland.sh"

die() { printf 'release-sums: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

# Fingerprint (SHA256:...) of a public or private key file.
key_fpr() { ssh-keygen -lf "$1" 2>/dev/null | awk '{print $2}'; }

mode_make() {
  local tag="${1:?usage: release-sums.sh make TAG OUTDIR [SIGNING-KEY]}"
  local out="${2:?usage: release-sums.sh make TAG OUTDIR [SIGNING-KEY]}"
  local key="${3:-}" tag_out tag_fpr priv key_fpr_v
  need git; need ssh-keygen; need sha256sum

  [ "$(git config --get gpg.format || true)" = ssh ] \
    || die "gpg.format is not ssh; tags and checksums are signed with an SSH key"
  git rev-parse -q --verify "refs/tags/$tag" >/dev/null || die "no such tag: $tag"

  # The tag must verify; its key is the only one allowed to sign the sums.
  tag_out="$(git tag -v "$tag" 2>&1)" || { printf '%s\n' "$tag_out" >&2; die "tag $tag does not verify"; }
  tag_fpr="$(sed -nE 's/^Good "git" signature .* with [A-Z0-9-]+ key (SHA256:[A-Za-z0-9+\/=]+).*/\1/p' <<<"$tag_out" | head -n1)"
  [ -n "$tag_fpr" ] || die "could not read the signing key of $tag from git tag -v"

  [ -n "$key" ] || key="$(git config --get user.signingkey || true)"
  [ -n "$key" ] || die "no signing key: pass one, or set git's user.signingkey"
  key="${key/#\~/$HOME}"
  # ssh-keygen -Y sign needs the private half (or an agent holding it)
  priv="${key%.pub}"
  [ -f "$priv" ] || die "private key $priv not found"
  key_fpr_v="$(key_fpr "$priv")"
  [ "$key_fpr_v" = "$tag_fpr" ] \
    || die "signing key $key_fpr_v is not the key that signed $tag ($tag_fpr)"

  mkdir -p "$out"
  [ ! -e "$out/SHA256SUMS" ] && [ ! -e "$out/SHA256SUMS.sig" ] \
    || die "$out already holds SHA256SUMS or SHA256SUMS.sig; use an empty directory"
  git show "$tag:$ASSET" >"$out/$ASSET"
  (cd "$out" && sha256sum "$ASSET" >SHA256SUMS)
  ssh-keygen -q -Y sign -f "$priv" -n "$NS" "$out/SHA256SUMS" \
    || die "signing failed"
  [ -s "$out/SHA256SUMS.sig" ] || die "no signature written"
  printf 'signed %s with %s\n' "$out/SHA256SUMS" "$tag_fpr"
  cat "$out/SHA256SUMS"
}

mode_verify() {
  local dir="${1:?usage: release-sums.sh verify DIR ALLOWED-SIGNERS}"
  local signers="${2:?usage: release-sums.sh verify DIR ALLOWED-SIGNERS}" who
  need ssh-keygen; need sha256sum
  [ -f "$dir/SHA256SUMS" ] && [ -f "$dir/SHA256SUMS.sig" ] || die "$dir lacks SHA256SUMS or SHA256SUMS.sig"
  who="$(ssh-keygen -Y find-principals -f "$signers" -s "$dir/SHA256SUMS.sig" 2>/dev/null | head -n1)" \
    && [ -n "$who" ] || die "SHA256SUMS.sig was not made by any key in $signers"
  ssh-keygen -Y verify -f "$signers" -I "$who" -n "$NS" -s "$dir/SHA256SUMS.sig" <"$dir/SHA256SUMS" \
    || die "signature over SHA256SUMS does not verify"
  (cd "$dir" && sha256sum -c SHA256SUMS) || die "a file does not match SHA256SUMS"
}

case "${1:-}" in
  make)   shift; mode_make "$@" ;;
  verify) shift; mode_verify "$@" ;;
  *) printf 'usage: release-sums.sh make TAG OUTDIR [SIGNING-KEY] | verify DIR ALLOWED-SIGNERS\n' >&2; exit 2 ;;
esac
