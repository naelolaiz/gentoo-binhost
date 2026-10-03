#!/usr/bin/env bash
# setup-consumer.sh — configure a fresh Gentoo stage3 container the way a
# machine that installs from this binhost is configured.
#
# Usage:
#   setup-consumer.sh --binhost-uri <url> --trust-key <public-key.asc>
#                     [--tree-date YYYYMMDD] [--date-file FILE]
#
# Used by the builder (which then adds its build-only settings) and by the
# consumer check, so both see the binhost through the same configuration.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=config/binhost.conf
. "${REPO_ROOT}/config/binhost.conf"

log() { echo "[setup-consumer] $*"; }
die() { echo "::error::$*" >&2; exit 1; }

BINHOST_URI=""
TRUST_KEY=""
TREE_DATE=""
DATE_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --binhost-uri) BINHOST_URI="$2"; shift 2 ;;
    --trust-key)   TRUST_KEY="$2";   shift 2 ;;
    --tree-date)   TREE_DATE="$2";   shift 2 ;;
    --date-file)   DATE_FILE="$2";   shift 2 ;;
    *) die "Unknown argument: $1" ;;
  esac
done
[[ "$BINHOST_URI" =~ ^https?:// ]] || die "--binhost-uri must be an http(s) URL"
[[ -f "$TRUST_KEY" ]] || die "--trust-key file not found: ${TRUST_KEY}"

sync_args=()
[[ -n "$TREE_DATE" ]] && sync_args+=(--revert "$TREE_DATE")
[[ -n "$DATE_FILE" ]] && sync_args+=(--date-file "$DATE_FILE")
bash "${SCRIPT_DIR}/sync-portage.sh" "${sync_args[@]}"

bash "${SCRIPT_DIR}/apply-profile.sh" "$PROFILE_NAME" "$GENTOO_PROFILE"

# Two Portage behaviours the binhost relies on: fetched packages are kept
# apart from locally built ones (3.0.77), and signatures are verified per
# binrepos.conf entry (3.0.74, default since 3.0.78).
portage_version="$(python3 -c 'import portage; print(portage.VERSION)')"
python3 - "$portage_version" <<'PY' || die "Portage ${portage_version} is too old for this binhost (needs >= 3.0.77); use a newer stage3"
import sys
from portage.versions import vercmp
sys.exit(0 if vercmp(sys.argv[1].split("-")[0], "3.0.77") >= 0 else 1)
PY
log "Portage ${portage_version}"

# binrepos.conf only: with PORTAGE_BINHOST set, Portage stores fetched
# packages in PKGDIR, mixed with the ones built here.
rm -rf /etc/portage/binrepos.conf
mkdir -p /etc/portage/binrepos.conf
cat > /etc/portage/binrepos.conf/binhost.conf <<EOF
[own-binhost]
priority = 10
sync-uri = ${BINHOST_URI}
verify-signature = true

[gentoobinhost]
priority = 1
sync-uri = ${OFFICIAL_BINHOST}
verify-signature = true
EOF
log "binrepos.conf: ${BINHOST_URI} (own), ${OFFICIAL_BINHOST} (official)"

bash "${SCRIPT_DIR}/trust-binhost-key.sh" "$TRUST_KEY"
