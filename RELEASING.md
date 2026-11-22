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

## 3. Update the link

In the same snippet, point the `curl` URL at the new tag:

```
https://raw.githubusercontent.com/ABDUAZIZX/claude-desktop-userland/vX.Y.Z/claude-desktop-userland.sh
```

## 4. Run the checks

```
bash -n claude-desktop-userland.sh
shellcheck -S warning -s bash claude-desktop-userland.sh
shellcheck -S warning -x tests/run.sh
bash tests/run.sh
```

All must pass. `tests/run.sh` fails if the README usage block differs from
`--help`, if the README hash differs from the script (the working copy while
tag `v$SELF_VERSION` does not exist yet, the tagged file afterwards), if the README URL does
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

## 7. GitHub Release with the SHA256

Create a release from tag `vX.Y.Z`:

- Attach `claude-desktop-userland.sh` taken from the tag
  (`git show vX.Y.Z:claude-desktop-userland.sh > claude-desktop-userland.sh`).
- Put its SHA256 in the release notes, in `sha256sum` format:
  `<sha256>  claude-desktop-userland.sh`
- Copy the `X.Y.Z` section of `CHANGELOG.md` into the notes.

The three values (README, raw URL, release asset) must be identical. If one
differs, delete the release and the tag and start again from step 1.
