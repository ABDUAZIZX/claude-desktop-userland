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
#       SIGNING-KEY defaults to git's user.signingkey (an SSH key file). TAG
#       must be an annotated tag whose signature verifies with exactly that key
#       (checked with ssh-keygen, not by parsing git output); otherwise
#       nothing is written.
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
  local key="${3:-}" tag_fpr priv work
  need git; need ssh-keygen; need sha256sum

  git rev-parse -q --verify "refs/tags/$tag" >/dev/null || die "no such tag: $tag"

  [ -n "$key" ] || key="$(git config --get user.signingkey || true)"
  [ -n "$key" ] || die "no signing key: pass one, or set git's user.signingkey"
  key="${key/#\~/$HOME}"
  # ssh-keygen -Y sign needs the private half (or an agent holding it)
  priv="${key%.pub}"
  [ -f "$priv" ] || die "private key $priv not found"

  # The tag must carry a signature by exactly this key. It is checked directly
  # with ssh-keygen against an allowed_signers holding only this key, instead
  # of reading "git tag -v" output, whose stdout carries the tag message and
  # could imitate a verification line.
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' RETURN
  git cat-file tag "$tag" >"$work/tag" 2>/dev/null \
    || die "tag $tag is not an annotated tag, so it carries no signature"
  grep -qx -- '-----BEGIN SSH SIGNATURE-----' "$work/tag" \
    || die "tag $tag has no SSH signature"
  sed -n '/^-----BEGIN SSH SIGNATURE-----$/,$p' "$work/tag" >"$work/tag.sig"
  sed '/^-----BEGIN SSH SIGNATURE-----$/,$d' "$work/tag" >"$work/tag.payload"
  ssh-keygen -y -f "$priv" >"$work/key.pub" 2>/dev/null \
    || die "cannot derive the public key from $priv"
  printf 'signer namespaces="git" %s\n' "$(cat "$work/key.pub")" >"$work/allowed"
  ssh-keygen -Y verify -f "$work/allowed" -I signer -n git \
      -s "$work/tag.sig" <"$work/tag.payload" >/dev/null 2>&1 \
    || die "tag $tag is not signed by $(key_fpr "$priv"); sign the sums with the key that signed the tag"
  tag_fpr="$(key_fpr "$priv")"

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
