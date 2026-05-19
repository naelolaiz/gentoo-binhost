#!/usr/bin/env bash
# Install ccache for the main build.
#
# PORTAGE_BINHOST is supplied by the workflow and intentionally points at the
# official Gentoo binhost only.  The CI should publish this repository's
# packages, not consume a previous Pages publication as an input.

set -euo pipefail

log() { echo "[install-build-tools] $*"; }

: "${PORTAGE_BINHOST:?PORTAGE_BINHOST must be set in the environment}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TOOL_ATOM=dev-util/ccache

ccache_usable() {
  ccache --version >/dev/null
}

install_binary_ccache() {
  log "Installing ccache from the official Gentoo binhost"
  ACCEPT_KEYWORDS=amd64 PORTAGE_BINHOST="$PORTAGE_BINHOST" emerge \
    --oneshot --quiet \
    --usepkgonly --getbinpkgonly --binpkg-respect-use=n \
    "${TOOL_ATOM}"
}

build_ccache_from_source() {
  echo "::warning::ccache binary install failed or is unusable; rebuilding stable ccache from source"
  rm -f /var/cache/binpkgs/dev-util/ccache-*.gpkg.tar \
        /var/cache/binpkgs/dev-util/ccache/*.gpkg.tar
  ACCEPT_KEYWORDS=amd64 emerge --oneshot --quiet --usepkg n --getbinpkg n \
    "${TOOL_ATOM}"
}

if ! install_binary_ccache || ! ccache_usable; then
  build_ccache_from_source
  ccache_usable
fi

bash "${SCRIPT_DIR}/merge-pending-configs.sh" install-build-tools

log "ccache installed"
