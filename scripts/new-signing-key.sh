#!/usr/bin/env bash
# new-signing-key.sh — create the key that signs the binary packages.
#
# Usage: new-signing-key.sh <public-key-output.asc> [<key name>]
#
# The public key is written to the given file.  The secret key is written to
# standard output and nowhere else, so it can be piped straight into the
# repository secret; with /tmp on a tmpfs it never reaches a disk:
#
#   podman run --rm --network none --tmpfs /tmp \
#       -v "$PWD:/repo:ro" -v "$PWD/keys:/keys" \
#       docker.io/gentoo/stage3:amd64-desktop-openrc \
#       bash /repo/scripts/new-signing-key.sh /keys/binhost-signing-key.asc \
#     | gh secret set GPG_PRIVATE_KEY
#
# The key has no passphrase: it would sit in the same secret store as the key
# and protect nothing.  Everything that is not the secret key goes to
# standard error.
set -euo pipefail
exec 3>&1 1>&2

PUBLIC="${1:-}"
NAME="${2:-Gentoo Binhost (naelolaiz/gentoo-binhost)}"
VALIDITY="3y"
[[ -n "$PUBLIC" ]] || { echo "Usage: $0 <public-key-output.asc> [<key name>]"; exit 1; }

home="$(mktemp -d)"
chmod 700 "$home"
trap 'gpgconf --homedir "$home" --kill all >/dev/null 2>&1 || true; rm -rf "$home"' EXIT

gpg --homedir "$home" --batch --quiet --pinentry-mode loopback --passphrase "" \
    --quick-generate-key "$NAME" ed25519 sign "$VALIDITY"
fpr="$(gpg --homedir "$home" --batch --with-colons --list-secret-keys \
  | awk -F: '$1 == "fpr" { print $10; exit }')"
[[ -n "$fpr" ]] || { echo "No key was generated"; exit 1; }
gpg --homedir "$home" --batch --armor --export "$fpr" > "$PUBLIC"

# Sign something and verify it with a keyring that only holds the exported
# public key: what comes out of this script has to belong together.
probe="$(mktemp -d)"
chmod 700 "$probe"
echo "binhost signing self-test" > "${probe}/data"
gpg --homedir "$home" --batch --no-tty --local-user "0x${fpr}" \
    --sign --armor --output "${probe}/data.asc" "${probe}/data"
mkdir -m 700 "${probe}/verify"
gpg --homedir "${probe}/verify" --batch --quiet --import "$PUBLIC"
status="$(gpg --homedir "${probe}/verify" --batch --no-tty --status-fd 1 \
  --verify "${probe}/data.asc" 2>/dev/null || true)"
gpgconf --homedir "${probe}/verify" --kill all >/dev/null 2>&1 || true
rm -rf "$probe"
grep -q "VALIDSIG ${fpr}" <<< "$status" \
  || { echo "Self-test failed: the exported public key does not verify a signature of the new key"; exit 1; }

secret="$(gpg --homedir "$home" --batch --pinentry-mode loopback --passphrase "" \
  --armor --export-secret-keys "$fpr")"
[[ "$secret" == *"BEGIN PGP PRIVATE KEY BLOCK"* ]] || { echo "Exporting the secret key failed"; exit 1; }

expires="$(gpg --homedir "$home" --batch --with-colons --list-keys "$fpr" \
  | awk -F: '$1 == "pub" { print $7; exit }')"
echo "Created key ${fpr}"
echo "  name:       ${NAME}"
echo "  expires:    $(date -u -d "@${expires}" +%Y-%m-%d)"
echo "  public key: ${PUBLIC}"
printf '%s\n' "$secret" >&3
