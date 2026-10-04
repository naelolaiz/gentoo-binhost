#!/usr/bin/env bash
# trust-binhost-key.sh — make Portage accept packages signed by this binhost.
#
# Usage: trust-binhost-key.sh <public-key.asc>
#
# Portage verifies binary package signatures against the keyring in
# /etc/portage/gnupg and only accepts keys it considers fully trusted.
# getuto builds that keyring for the official Gentoo keys; a custom binhost
# key has to be imported and signed with the keyring's local trust key, which
# is what this script does.  Run it as root on every machine that should
# install from the binhost (the build container runs it too, so the builder
# consumes its own packages exactly the way a desktop does).
#
# Idempotent: safe to run again after the key was renewed.
set -euo pipefail

log() { echo "[trust-binhost-key] $*"; }

KEY_FILE="${1:-}"
[[ -n "$KEY_FILE" && -f "$KEY_FILE" ]] || { echo "Usage: $0 <public-key.asc>" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYRING="/etc/portage/gnupg"

# Official Gentoo keys first: this also creates the keyring and its local
# trust key when they do not exist yet.
bash "${SCRIPT_DIR}/setup-binpkg-trust.sh"

FPR="$(gpg --batch --with-colons --show-keys "$KEY_FILE" | awk -F: '$1 == "fpr" { print $10; exit }')"
[[ -n "$FPR" ]] || { echo "No OpenPGP key found in ${KEY_FILE}" >&2; exit 1; }

gpg --homedir "$KEYRING" --no-permission-warning --batch --import "$KEY_FILE"

# getuto stores the passphrase of the local trust key next to the keyring.
[[ -f "${KEYRING}/pass" ]] || {
  echo "::error::${KEYRING}/pass not found; getuto did not create the local trust key" >&2
  exit 1
}
gpg --homedir "$KEYRING" --no-permission-warning --batch --yes --no-tty \
    --passphrase-file "${KEYRING}/pass" --pinentry-mode loopback \
    --quick-lsign-key "$FPR"
gpg --homedir "$KEYRING" --no-permission-warning --batch --check-trustdb

# Portage needs GOODSIG plus TRUST_FULLY/TRUST_ULTIMATE; anything less is
# rejected at install time, so check the outcome now.
VALIDITY="$(gpg --homedir "$KEYRING" --no-permission-warning --batch --with-colons --list-keys "$FPR" \
  | awk -F: '$1 == "pub" { print $2; exit }')"
case "$VALIDITY" in
  f|u) ;;
  e) echo "::error::Binhost signing key ${FPR} has expired; renew it and publish the new public key" >&2; exit 1 ;;
  *) echo "::error::Binhost signing key ${FPR} is not fully trusted in ${KEYRING} (validity '${VALIDITY}')" >&2; exit 1 ;;
esac

# Verification runs with dropped privileges; the keyring must stay readable.
chown -R portage:portage "$KEYRING"

log "Binhost key ${FPR} is trusted for binary package verification"
