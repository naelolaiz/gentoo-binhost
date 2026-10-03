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

In a container, so that nothing touches a personal keyring:

```bash
podman run --rm -it -v "$PWD/keys":/keys docker.io/gentoo/stage3:amd64-desktop-openrc bash -c '
  export GNUPGHOME="$(mktemp -d)"
  gpg --batch --passphrase "" --quick-generate-key "Gentoo Binhost (naelolaiz/gentoo-binhost)" ed25519 sign 3y
  gpg --armor --export > /keys/binhost-signing-key.asc
  echo "----- copy everything below into the GPG_PRIVATE_KEY secret -----"
  gpg --armor --export-secret-keys'
```

Commit the new `binhost-signing-key.asc`.

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
