#!/usr/bin/env bash
# install-build-tools.sh — install ccache and gentoolkit for the main build,
# pulling from the binhost when available and self-healing the two failure
# modes observed in CI:
#
#   1. Our own-binhost Packages index is corrupt (e.g. a CPV entry like
#      "tmp/artifacts/acct-group/cuse/cuse-0-1" from a prior buggy publish
#      run).  A single malformed entry crashes emerge with
#      portage.exception.InvalidData, preventing the entire build chain from
#      starting.  Validate the index first; if ours is unreachable or has
#      bad entries, fall back to the Gentoo official binhost for this step.
#      The publish job that always runs after build (even on failure) will
#      scrub and regenerate a clean index so subsequent runs recover
#      automatically.
#
#   2. A previously published binpkg was built against an older SONAME than
#      what the current stage3 ships (observed: ccache linked against
#      libblake3.so.0 after dev-libs/blake3 bumped its SONAME).  The recorded
#      RDEPEND in the gpkg is satisfied by any version in the slot, so
#      Portage installs it without rebuilding.  Detect this by actually
#      invoking the binaries and, if they fail, drop the bad gpkgs from the
#      local binpkg cache and rebuild from source so the next publish
#      replaces the broken artifact in the binhost.
#
# PORTAGE_BINHOST is read from the environment (the workflow sets it).
#
# Binpkg trust is established separately by scripts/setup-binpkg-trust.sh,
# which MUST have run before this script.
set -euo pipefail

log() { echo "[install-build-tools] $*"; }

: "${PORTAGE_BINHOST:?PORTAGE_BINHOST must be set in the environment}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Split the first two URLs out of PORTAGE_BINHOST (own binhost first,
# Gentoo official second — matching the workflow's BINHOST_URLS ordering).
read -r _OWN_BINHOST _OFFICIAL_BINHOST <<< "$PORTAGE_BINHOST"

# Default to the full PORTAGE_BINHOST; swap to official-only if our index is
# unusable for any reason.
_tools_binhost="$PORTAGE_BINHOST"

if ! _own_pkg_idx="$(curl --fail --no-progress-meter --max-time 30 "${_OWN_BINHOST}/Packages")"; then
  echo "::warning::Could not fetch own binhost Packages index — excluding own binhost from tools install"
  _tools_binhost="$_OFFICIAL_BINHOST"
elif ! printf '%s\n' "$_own_pkg_idx" | python3 "${SCRIPT_DIR}/check-packages-index.py"; then
  echo "::warning::Own binhost Packages index has malformed CPV entries — excluding own binhost from tools install to prevent emerge crash"
  _tools_binhost="$_OFFICIAL_BINHOST"
fi
unset _own_pkg_idx _OWN_BINHOST _OFFICIAL_BINHOST

PORTAGE_BINHOST="$_tools_binhost" emerge --oneshot --quiet --usepkg y --getbinpkg y \
  dev-util/ccache app-portage/gentoolkit

if ! ccache --version >/dev/null || ! equery --version >/dev/null; then
  echo "::warning::Stale binpkg ABI mismatch detected for ccache/gentoolkit — rebuilding from source"
  rm -f /var/cache/binpkgs/dev-util/ccache-*.gpkg.tar \
        /var/cache/binpkgs/app-portage/gentoolkit-*.gpkg.tar
  emerge --oneshot --quiet --usepkg n --getbinpkg n \
    dev-util/ccache app-portage/gentoolkit
  # Re-verify; if still broken, fail loud — this is not the bug we're
  # working around.
  ccache --version >/dev/null
  equery --version >/dev/null
fi

bash "${SCRIPT_DIR}/merge-pending-configs.sh" install-build-tools

log "ccache + gentoolkit installed"
