#!/usr/bin/env bash
# setup-binpkg-trust.sh — bootstrap the Portage-specific GPG keyring so
# binary packages from the Gentoo binhost can be signature-verified.
#
# Uses /usr/bin/getuto — Portage's own $PORTAGE_TRUST_HELPER, from
# app-portage/getuto, which is a hard dep of recent sys-apps/portage
# and is therefore present in any stage3 built from a modern profile.
# getuto:
#   * imports the binhost signing keys (including the binpkg key
#     534E4209AB49EEE1C19D96162C44695DB9F6043D, which is NOT a primary key in
#     /usr/share/openpgp-keys/gentoo-release.asc),
#   * sets correct trust levels, and
#   * chowns /etc/portage/gnupg to portage:portage so gpg-as-portage does not
#     error with "unsafe ownership on homedir" / "Permission denied" on
#     pubring.kbx during binpkg verification.
#
# An earlier manual `gpg --import` of the release-keys file plus a subsequent
# `chown` looked correct but produced exactly those two errors at
# install-tools time (CI run 24651146807, job 72074035707) — getuto avoids
# the whole class of bug.
#
# If the Gentoo release signing key is already trusted, this script exits 0
# without re-running getuto — idempotent so callers can invoke it
# unconditionally.
set -euo pipefail

log() { echo "[setup-binpkg-trust] $*"; }

# Key 534E4209AB49EEE1C19D96162C44695DB9F6043D is the Gentoo binpkg signing
# key.  Hard-coded because it's a well-known long-term identifier; rotation
# would require an explicit update here and that's the correct failure mode.
GENTOO_BINHOST_KEY="534E4209AB49EEE1C19D96162C44695DB9F6043D"

if [[ -d /etc/portage/gnupg ]] \
   && gpg --homedir /etc/portage/gnupg --list-keys "$GENTOO_BINHOST_KEY" >/dev/null 2>&1; then
  log "Gentoo binhost signing key ${GENTOO_BINHOST_KEY} already trusted; skipping"
  exit 0
fi

if ! command -v getuto >/dev/null; then
  echo "::error::/usr/bin/getuto not found; cannot bootstrap Portage binpkg trust" >&2
  exit 1
fi

log "Running getuto to import Gentoo binpkg signing keys"
getuto

# Verify the binhost signing key is actually present after bootstrap —
# catches a silent regression in getuto or a key rotation before it surfaces
# as a cryptic NO_PUBKEY during emerge.
if ! gpg --homedir /etc/portage/gnupg --list-keys "$GENTOO_BINHOST_KEY" >/dev/null; then
  echo "::error::Gentoo binhost signing key ${GENTOO_BINHOST_KEY} not present in /etc/portage/gnupg after getuto" >&2
  exit 1
fi

# Defence in depth: getuto already chowns to portage:portage, but re-asserting
# it here means a future getuto change that drops the chown still leaves us
# with a working keyring instead of the "unsafe ownership" failure we are
# fixing.
chown -R portage:portage /etc/portage/gnupg

log "Portage binpkg trust established"
