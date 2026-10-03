#!/usr/bin/env bash
# scripts/apply-profile.sh — apply a profile configuration to /etc/portage
#
# Usage:
#   apply-profile.sh <profile-name> <gentoo-profile-path>
#
#   <profile-name>         directory name under config/profiles/ (e.g. amd64-23.0-desktop-plasma-openrc)
#   <gentoo-profile-path>  argument passed to `eselect profile set` (e.g. default/linux/amd64/23.0/desktop/plasma)
#
# The profile directory holds only what decides whether a machine accepts a
# binary package (USE flags, keywords, masks, licenses).  Binhost locations go
# into binrepos.conf and builder-only settings are added by
# scripts/container-build.sh, so this script is the same for the builder and
# for a test consumer.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

log() { echo "[apply-profile.sh] $*"; }

PROFILE="${1:-}"
GENTOO_PROFILE="${2:-}"
[[ -n "$PROFILE" && -n "$GENTOO_PROFILE" && $# -eq 2 ]] \
  || { echo "Usage: apply-profile.sh <profile-name> <gentoo-profile-path>" >&2; exit 1; }

PROFILE_DIR="${REPO_ROOT}/config/profiles/${PROFILE}"
[[ -d "$PROFILE_DIR" ]] || { echo "Profile directory not found: ${PROFILE_DIR}" >&2; exit 1; }

log "Applying profile: ${PROFILE}"

# Use nullglob so empty profile subdirs produce zero cp arguments instead of
# a literal '*' filename.  cp errors are NOT silenced: perm denied or a bad
# source path must fail RED, not silently build with missing USE overrides.
shopt -s nullglob

# make.conf
[[ -f "${PROFILE_DIR}/make.conf" ]] \
  || { echo "ERROR: ${PROFILE_DIR}/make.conf is missing" >&2; exit 1; }
cp "${PROFILE_DIR}/make.conf" /etc/portage/make.conf
# Byte-check immediately after copy: guards against a rogue prior step
# silently overwriting the file we just wrote.
if ! cmp -s "${PROFILE_DIR}/make.conf" /etc/portage/make.conf; then
  echo "ERROR: make.conf byte-mismatch immediately after copy" >&2
  exit 1
fi
log "  Installed make.conf"

# Package configuration directories (order is irrelevant; all are overrides)
for dir in package.use package.accept_keywords package.mask package.license; do
  mkdir -p "/etc/portage/${dir}"
  if [[ -d "${PROFILE_DIR}/${dir}" ]]; then
    files=( "${PROFILE_DIR}/${dir}/"* )
    if (( ${#files[@]} > 0 )); then
      cp "${files[@]}" "/etc/portage/${dir}/"
      log "  Installed ${#files[@]} ${dir} file(s)"
    fi
  fi
done

shopt -u nullglob

# Set the Gentoo profile. No || true: wrong/missing profile must fail RED.
eselect profile set "${GENTOO_PROFILE}"
log "  eselect profile set '${GENTOO_PROFILE}'"
