# Trust chain

The goal is to end up executing exactly the bytes Anthropic published, while
never handing root to anything and never widening the set of keys the system
trusts. Five links, each one deriving its authority from the previous one.

```
pinned fingerprint
        |
        v
   signing key  --(imported into isolated keyring)-->  InRelease clearsig
        |
        v
   verified Release metadata  --(SHA256)-->  Packages index
        |
        v
   verified index  --(SHA256)-->  claude-desktop_<ver>_<arch>.deb
        |
        v
   ar container  -->  data.tar.*  -->  ~/.local/share/claude-desktop
```

## Link 1: fingerprint pinning

```
KEY_FPR="31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE"
```

The key is fetched over HTTPS, then its fingerprint is extracted with
`gpg --with-colons --show-keys` and compared byte for byte with the constant.

**Protects against:** a compromised or substituted key served from the download
host, and against a proxy or middlebox that can present a valid TLS certificate.

**Does not protect against:** a first-install user who copied a bad fingerprint
into the script. This is trust-on-first-read, not trust-on-first-use, which is
why the README asks you to verify the constant against Anthropic's own
documentation rather than against the server it was downloaded from.

**Key rotation:** if Anthropic rotates the key, this link fails and the script
aborts. That is deliberate. Update the constant only after confirming the new
fingerprint from the vendor, not from the file that failed the check.

## Link 2: isolated keyring

```
export GNUPGHOME="$TMP/gnupg"
```

`gpg` is pointed at a directory inside the temporary workspace, created with
mode 700, containing exactly one key.

**Why it matters:** with the default `~/.gnupg` a valid signature only proves
that *some* key you trust signed the file. Since your personal keyring may hold
dozens of keys accumulated over years, that is a much weaker statement than it
looks. Here, "the signature verifies" and "Anthropic signed it" are the same
proposition.

The directory is destroyed by the `EXIT` trap, so nothing persists.

## Link 3: InRelease

```
gpg --batch --quiet --yes --output Release.verified --decrypt InRelease
```

`InRelease` is the clear-signed form of the APT `Release` file. Using
`--decrypt` and writing to `Release.verified` means the script only ever parses
the payload that gpg extracted from inside the signature envelope. Parsing the
raw `InRelease` instead would be a mistake: an attacker could append unsigned
lines after the signed block and a naive parser would read them.

**Provides:** authenticated SHA256 checksums for every index in the
distribution, plus the freshness fields (`Date`, `Valid-Until`) that APT would
normally use for replay protection.

**Note:** the script does not currently enforce `Valid-Until`. A network
attacker able to serve a stale but genuinely signed `InRelease` could pin you to
an older release. Given that the script also refuses to downgrade an existing
install only by version comparison, treat this as a known gap rather than a
solved problem. Enforcing it is a small awk addition if you want it.

## Link 4: Packages index

```
IDX_PATH="main/binary-${DEB_ARCH}/Packages"
```

The SHA256 line for that exact path is pulled out of `Release.verified`, the
index is downloaded, and `sha256sum -c` validates it. If the path is not listed
in the signed metadata, the script aborts rather than trusting an index that
nobody vouched for.

The awk block tracks the `SHA256:` stanza and stops at the first non-indented
line, so a checksum from the `MD5Sum:` or `SHA1:` section can never be picked
up by mistake.

## Link 5: the package

Each stanza of the verified index carries `Package`, `Version`, `Filename` and
`SHA256`. The script selects the highest `Version` for `PKG_NAME` using
`sort -V`, downloads `Filename` relative to the repository base, and verifies
the checksum before touching it.

At this point the `.deb` is authenticated transitively: signature to metadata,
metadata to index, index to package.

## Extraction

`dpkg` is not available and is not wanted, so a short Python program reads the
`ar` container directly:

- checks the `!<arch>\n` magic
- walks 60-byte member headers
- streams out the first member whose name starts with `data.tar`
- ignores `debian-binary` and `control.tar.*` entirely

Control scripts are therefore never even extracted, let alone executed. This is
the single most important property of the whole design: installing a package
does not run vendor code as root, because it does not run vendor code at all
until you launch the application yourself.

`data.tar.{xz,gz,zst,tar}` are all handled. The tarball is unpacked into a
scratch root, and the Electron app directory is located by searching for
`resources/app.asar` rather than by assuming `/usr/lib/claude-desktop`, so a
vendor path change does not necessarily break the install.

## What is still trusted

Being explicit about the residual trust:

- **The application itself.** Verification proves provenance, not safety. You
  are running Anthropic's Electron app with your user's privileges and your
  user's file access.
- **TLS and the CA set** for the initial key fetch, before pinning can help.
- **The local toolchain**: `gpg`, `curl`, `sha256sum`, `python3`, `tar` from
  the base image.
- **`$TMPDIR`.** On a shared machine with a world-writable `/tmp` and no
  `mktemp` privacy, a local attacker could in principle race the extracted
  payload. `mktemp -d` creates mode 0700 directories, which closes the ordinary
  case.
- **Chromium's sandbox** for renderer isolation, which requires unprivileged
  user namespaces since `chrome-sandbox` is not setuid here.
