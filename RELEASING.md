# Releasing

The order matters: the README install snippet pins both a tag and the
script's SHA256, and the SHA256 covers the version string inside the script.
`X.Y.Z` below is the new version.

## Between releases

Record changes under a `## Unreleased` heading at the top of `CHANGELOG.md`
and leave `SELF_VERSION` at the last released version. The tests require a
dated CHANGELOG heading for `SELF_VERSION`, so bumping the version early
would fail CI until release day.

## 1. Bump the version and date the entry

Both in the same commit:

- `SELF_VERSION="X.Y.Z"` in `claude-desktop-userland.sh`.
- In `CHANGELOG.md`, turn `## Unreleased` into `## X.Y.Z (YYYY-MM-DD)`, with
  the release date.

Make no further change to the script after this step. Any edit changes the
hash computed next.

## 2. Update the hash

```
sha256sum claude-desktop-userland.sh
```

Put the value into the `echo "<sha256>  claude-desktop-userland.sh" | sha256sum -c -`
line of the README install snippet.

## 3. Update the links

In the same snippet, point every URL at the new tag: the raw script URL and
both release-asset URLs (`SHA256SUMS`, `SHA256SUMS.sig`).

```
https://raw.githubusercontent.com/ABDUAZIZX/claude-desktop-userland/vX.Y.Z/claude-desktop-userland.sh
https://github.com/ABDUAZIZX/claude-desktop-userland/releases/download/vX.Y.Z/SHA256SUMS
https://github.com/ABDUAZIZX/claude-desktop-userland/releases/download/vX.Y.Z/SHA256SUMS.sig
```

The release-asset URLs return 404 until step 8 publishes them.

## 4. Run the checks

```
bash -n claude-desktop-userland.sh
shellcheck -S warning -s bash claude-desktop-userland.sh
shellcheck -S warning -x tests/run.sh
bash tests/run.sh
```

All must pass. `tests/run.sh` fails if the README usage block differs from
`--help`, if the README hash differs from the script (the working copy while
tag `v$SELF_VERSION` does not exist yet, the tagged file afterwards), if a README URL does
not point at `v$SELF_VERSION`, or if `CHANGELOG.md` has no
`## $SELF_VERSION (YYYY-MM-DD)` heading with a real date, so steps 1 to 3 are
checked here.

The summary reads `N passed, M skipped, K failed`. A skip means a code path
was not exercised on this machine (for example no `bsdtar`); it is not a pass.
CI runs `bash tests/run.sh --no-skip`, where any skip fails the job, so do not
merge unless CI is green.

## 5. Merge

Open the pull request, wait for CI to pass, merge into `main`. Then confirm
that `main` carries exactly the script that was hashed:

```
git switch main && git pull --ff-only
sha256sum claude-desktop-userland.sh     # must equal the README value
```

## 6. Signed tag

**Precondition:** on the merge commit, `bash tests/run.sh` passes, including
the dated CHANGELOG heading for `SELF_VERSION`. Do not tag a commit whose
CHANGELOG still says `Unreleased` for this version; a tag cannot be fixed
afterwards without moving it.

Tag the merge commit on `main`, signed, and verify the signature before
pushing:

```
git tag -s vX.Y.Z -m "vX.Y.Z"
git tag -v vX.Y.Z
git push origin vX.Y.Z
```

With an SSH signing key, `git tag -v` needs `gpg.ssh.allowedSignersFile` to
list that key. Never push an unsigned or unverifiable tag; delete it locally
and tag again.

Then check the pinned URL serves the hashed file:

```
curl -fsSL https://raw.githubusercontent.com/ABDUAZIZX/claude-desktop-userland/vX.Y.Z/claude-desktop-userland.sh \
  | sha256sum                            # must equal the README value
```

## 7. Signed SHA256SUMS

Create the release files from the verified tag, signed with the key that
signed the tag (git's `user.signingkey`; any other key is refused):

```
DIR="$(mktemp -d)"
bash tools/release-sums.sh make vX.Y.Z "$DIR"
```

It verifies the tag (`git tag -v`), takes `claude-desktop-userland.sh` from
the tag, writes `SHA256SUMS` and signs it into `SHA256SUMS.sig` (SSH
signature, namespace `file`).

Verify them against the key **as published on GitHub**, not the local copy,
exactly as a user would (the README section "Verify a release signature"):

```
curl -fsSL https://api.github.com/users/ABDUAZIZX/ssh_signing_keys \
  | grep -o '"key": *"[^"]*"' | cut -d'"' -f4 > "$DIR/signing_key.pub"
ssh-keygen -lf "$DIR/signing_key.pub"   # SHA256:DFqKPwKi7WOq6aOIBO9yx6LqjhgqC/n29X6v4u8oVsI
sed 's/^/release namespaces="file" /' "$DIR/signing_key.pub" > "$DIR/allowed_signers"
bash tools/release-sums.sh verify "$DIR" "$DIR/allowed_signers"
```

If verification fails, do not publish; find out why (wrong key, key not
registered as a signing key on GitHub, edited file).

## 8. GitHub Release

Create a release from tag `vX.Y.Z` with three assets from that directory:

- `claude-desktop-userland.sh`
- `SHA256SUMS`
- `SHA256SUMS.sig`

```
gh release create vX.Y.Z --verify-tag --title vX.Y.Z --notes-file NOTES.md \
  "$DIR/claude-desktop-userland.sh" "$DIR/SHA256SUMS" "$DIR/SHA256SUMS.sig"
```

In the notes:

- the content of `SHA256SUMS` (`<sha256>  claude-desktop-userland.sh`)
- the `X.Y.Z` section of `CHANGELOG.md`

The values in the README, the raw URL, the release asset and `SHA256SUMS`
must be identical, and `SHA256SUMS.sig` must verify. If any check fails,
delete the release and the tag and start again from step 1.

After publishing, download the three assets from the release page into an
empty directory and run the README verification commands once more.
