# Signing key

Packages are signed inside the gpkg by Portage (`FEATURES=binpkg-signing`).
Machines verify the signature against `binhost-signing-key.asc` in this
directory; see [scripts/trust-binhost-key.sh](../scripts/trust-binhost-key.sh).

The secret key is only stored as a repository secret and is never committed.

| Secret | Content |
|---|---|
| `GPG_PRIVATE_KEY` | the armored secret key |
| `GPG_PASSPHRASE` | its passphrase; leave unset for a key without one |

Before building anything, each run signs a test file and verifies it the way
a machine would.  If the secret key and the public key in this directory do
not belong together, or the key has expired, the run stops there.

## Creating a key

[scripts/new-signing-key.sh](../scripts/new-signing-key.sh) creates one in a
container, so that nothing touches a personal keyring.  It writes the public
key into this directory and the secret key to its standard output, which goes
straight into the repository secret without being stored anywhere else:

```bash
podman run --rm --network none --tmpfs /tmp \
    -v "$PWD:/repo:ro" -v "$PWD/keys:/keys" \
    docker.io/gentoo/stage3:amd64-desktop-openrc \
    bash /repo/scripts/new-signing-key.sh /keys/binhost-signing-key.asc \
  | gh secret set GPG_PRIVATE_KEY
```

Commit the new `binhost-signing-key.asc`.  The key is valid for three years
and has no passphrase.

## Renewing or replacing it

A signature made by an expired key is rejected, including on packages that
were signed while the key was valid.  Before the key expires:

1. Extend the expiry (`gpg --quick-set-expire <fingerprint> 3y`) or create a
   new key, and update the `GPG_PRIVATE_KEY` secret.
2. Commit the new public key.
3. On every machine, run `scripts/trust-binhost-key.sh` again with the new
   file.

With a *new* key, packages signed by the old one stay installable only as
long as machines still trust the old key; rebuild them by deleting the
`binhost` branch (see "Starting over" in
[docs/TROUBLESHOOTING.md](../docs/TROUBLESHOOTING.md)) or let them be replaced
as versions move on.
