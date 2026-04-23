#!/usr/bin/env bash
# scripts/apply-profile.sh — apply a build profile configuration to /etc/portage
#
# Usage:
#   apply-profile.sh <profile-name> <gentoo-profile-path> [--binhost-url <url>]
#
#   <profile-name>         directory name under config/profiles/ (e.g. amd64-23.0-desktop-plasma-openrc)
#   <gentoo-profile-path>  argument passed to `eselect profile set` (e.g. default/linux/amd64/23.0/desktop/plasma)
#   --binhost-url <url>    space-separated PORTAGE_BINHOST URL(s) appended to make.conf (optional)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

log() { echo "[apply-profile.sh] $*"; }

PROFILE=""
GENTOO_PROFILE=""
BINHOST_URL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --binhost-url) BINHOST_URL="$2"; shift 2 ;;
    -*)            echo "Unknown option: $1" >&2; exit 1 ;;
    *)
      if [[ -z "$PROFILE" ]];         then PROFILE="$1"
      elif [[ -z "$GENTOO_PROFILE" ]]; then GENTOO_PROFILE="$1"
      else echo "Unexpected argument: $1" >&2; exit 1
      fi
      shift ;;
  esac
done

[[ -n "$PROFILE" ]]         || { echo "Usage: apply-profile.sh <profile-name> <gentoo-profile-path> [--binhost-url <url>]" >&2; exit 1; }
[[ -n "$GENTOO_PROFILE" ]]  || { echo "apply-profile.sh: <gentoo-profile-path> is required" >&2; exit 1; }

PROFILE_DIR="${REPO_ROOT}/config/profiles/${PROFILE}"
[[ -d "$PROFILE_DIR" ]] || { echo "Profile directory not found: ${PROFILE_DIR}" >&2; exit 1; }

log "Applying profile: ${PROFILE}"

# Use nullglob so empty profile subdirs produce zero cp arguments instead of
# a literal '*' filename.  cp errors are NOT silenced: perm denied or a bad
# source path must fail RED, not silently build with missing USE overrides.
shopt -s nullglob

# make.conf
if [[ -f "${PROFILE_DIR}/make.conf" ]]; then
  cp "${PROFILE_DIR}/make.conf" /etc/portage/make.conf
  # Byte-check immediately after copy: guards against a cache layer or
  # rogue prior step silently overwriting the file we just wrote.
  if ! cmp -s "${PROFILE_DIR}/make.conf" /etc/portage/make.conf; then
    echo "ERROR: make.conf byte-mismatch immediately after copy" >&2
    exit 1
  fi
  log "  Installed make.conf"
fi

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

# Portage's config parser doesn't support $(cmd) substitutions.
# Evaluate any $(nproc) placeholders now that we're running under bash.
if [[ -f /etc/portage/make.conf ]]; then
  nproc_val="$(nproc || getconf _NPROCESSORS_ONLN || echo 1)"
  sed -i "s/\$(nproc)/${nproc_val}/g" /etc/portage/make.conf
  log "  Evaluated \$(nproc) → ${nproc_val} in make.conf"
fi

# Append PORTAGE_BINHOST if requested
if [[ -n "$BINHOST_URL" ]]; then
  echo "PORTAGE_BINHOST=\"${BINHOST_URL}\"" >> /etc/portage/make.conf
  log "  Set PORTAGE_BINHOST=${BINHOST_URL}"
fi
