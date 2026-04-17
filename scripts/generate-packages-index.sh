#!/usr/bin/env bash
# scripts/generate-packages-index.sh
#
# Regenerate the Packages index file for a binhost directory.
# Portage needs this file to find available binary packages.
#
# Usage:
#   generate-packages-index.sh <packages-dir>
#
# Example:
#   generate-packages-index.sh /var/www/binhost/amd64/23.0/desktop/plasma/openrc/x86-64-v3

set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[generate-packages-index.sh] $*"; }

PACKAGES_DIR="${1:-}"
[[ -n "$PACKAGES_DIR" ]] || die "Usage: $0 <packages-dir>"
[[ -d "$PACKAGES_DIR" ]] || die "Directory not found: ${PACKAGES_DIR}"

INDEX_FILE="${PACKAGES_DIR}/Packages"

log "Generating Packages index in: ${PACKAGES_DIR}"

# Use emaint or pkgcheck if available; otherwise fall back to a manual index
if command -v emaint &>/dev/null; then
  log "Using emaint binhost to generate index"
  PKGDIR="$PACKAGES_DIR" emaint binhost --fix
elif python3 -c "import portage" &>/dev/null; then
  log "Using portage Python API to generate index"
  python3 - <<'PYEOF'
import os, sys
import portage
pkgdir = os.environ.get("PKGDIR", sys.argv[1] if len(sys.argv) > 1 else ".")
bintree = portage.db[portage.root]["bintree"]
bintree.populate()
bintree.inject_sequence(bintree.dbapi.cpv_all())
print("Index generated via portage API")
PYEOF
else
  log "Generating Packages index manually"

  # Write header.  VERSION: 2 is required by modern Portage (>=2.3.51); a
  # missing field produces "Binhost package index version is not supported:
  # 'None'" warnings on the client and may prevent some clients from using
  # the binhost at all.
  cat > "$INDEX_FILE" <<EOF
ARCH: amd64
VERSION: 2
TIMESTAMP: $(date -u +%s)
REPO: gentoo-binhost

EOF

  # Iterate over all .gpkg.tar files
  find "$PACKAGES_DIR" -name '*.gpkg.tar' | sort | while read -r pkg; do
    rel="${pkg#${PACKAGES_DIR}/}"
    cat_pkg_ver="${rel%.gpkg.tar}"   # e.g. dev-qt/qtbase-6.7.0
    cpv="${cat_pkg_ver}"

    size=$(stat -c '%s' "$pkg")
    md5=$(md5sum "$pkg" | awk '{print $1}')
    sha1=$(sha1sum "$pkg" | awk '{print $1}')

    cat >> "$INDEX_FILE" <<EOF
CPV: ${cpv}
PATH: ${rel}
SIZE: ${size}
MD5: ${md5}
SHA1: ${sha1}

EOF
  done

  log "Packages index written to ${INDEX_FILE}"
fi

log "Done."
