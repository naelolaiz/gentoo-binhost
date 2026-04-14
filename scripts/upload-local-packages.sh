#!/usr/bin/env bash
# scripts/upload-local-packages.sh
#
# Helper script for contributors who want to upload locally-built packages
# to the gentoo-binhost repository via a Pull Request.
#
# Prerequisites:
#   - git, gpg (optional but recommended)
#   - A fork of https://github.com/naelolaiz/gentoo-binhost
#   - The packages built with BINPKG_FORMAT="gpkg" (produces .gpkg.tar files)
#
# Usage:
#   upload-local-packages.sh [options] <package.gpkg.tar> [<package2.gpkg.tar> ...]
#
# Options:
#   --march <value>   The -march value used when building (e.g. znver3, native)
#                     Used to place packages in an appropriate sub-path.
#                     Defaults to "custom"
#   --sign            GPG-sign the packages before uploading
#   --gpg-key <id>    GPG key ID to sign with (required when --sign is used)
#   --branch <name>   Git branch name for the PR (default: contrib/<timestamp>)
#   --help            Show this message

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------- defaults ----------
MARCH="custom"
SIGN=false
GPG_KEY=""
BRANCH=""
PACKAGES=()

# ---------- helpers ----------
die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[upload-local-packages.sh] $*"; }

usage() {
  sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \?//'
  exit 0
}

# ---------- argument parsing ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --march)    MARCH="$2";   shift 2 ;;
    --sign)     SIGN=true;    shift   ;;
    --gpg-key)  GPG_KEY="$2"; shift 2 ;;
    --branch)   BRANCH="$2";  shift 2 ;;
    --help|-h)  usage ;;
    *.gpkg.tar) PACKAGES+=("$1"); shift ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ ${#PACKAGES[@]} -gt 0 ]] || die "No .gpkg.tar files specified"
[[ "$SIGN" == false || -n "$GPG_KEY" ]] || die "--gpg-key is required when --sign is used"

# Validate that each file exists
for pkg in "${PACKAGES[@]}"; do
  [[ -f "$pkg" ]] || die "File not found: ${pkg}"
  [[ "$pkg" == *.gpkg.tar ]] || die "Not a .gpkg.tar file: ${pkg}"
done

# ---------- detect arch path from make.conf / environment ----------
ARCH_PATH="amd64/23.0/desktop/plasma/openrc/${MARCH}"

# ---------- set up git branch ----------
if [[ -z "$BRANCH" ]]; then
  BRANCH="contrib/$(date -u +%Y%m%d-%H%M%S)"
fi

log "Creating branch: ${BRANCH}"
cd "$REPO_ROOT"
git checkout -b "$BRANCH"

# ---------- copy packages into contrib/ ----------
DEST_DIR="${REPO_ROOT}/contrib/${ARCH_PATH}"
mkdir -p "$DEST_DIR"

for pkg in "${PACKAGES[@]}"; do
  pkg_basename="$(basename "$pkg")"

  # Optional: GPG detach-sign
  if [[ "$SIGN" == true ]]; then
    log "Signing ${pkg_basename}"
    gpg --batch --yes \
        --local-user "$GPG_KEY" \
        --detach-sign --armor \
        "$pkg"
    cp "${pkg}.asc" "${DEST_DIR}/"
  fi

  log "Copying ${pkg_basename} → ${DEST_DIR}/"
  cp "$pkg" "${DEST_DIR}/"
done

# ---------- commit ----------
git add contrib/

# Build commit message in a temp file to handle special characters safely
COMMIT_MSG_FILE="$(mktemp)"
{
  echo "contrib: add locally-built packages for ${ARCH_PATH}"
  echo ""
  echo "Packages added:"
  for pkg in "${PACKAGES[@]}"; do
    echo "  - $(basename "$pkg")"
  done
  echo ""
  echo "march: ${MARCH}"
} > "$COMMIT_MSG_FILE"
git commit -F "$COMMIT_MSG_FILE"
rm -f "$COMMIT_MSG_FILE"

log ""
log "Done! Next steps:"
log "  1. Push this branch to your fork:"
log "     git push origin ${BRANCH}"
log "  2. Open a Pull Request against naelolaiz/gentoo-binhost"
log "  3. The CI will validate and, on merge, publish the packages."
