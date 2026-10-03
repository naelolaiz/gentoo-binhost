#!/usr/bin/env bash
# consumer-smoke.sh — check, on a clean stage3 container, that a machine can
# really use what was just published.
#
# Usage:
#   consumer-smoke.sh --binhost-uri <url> --trust-key <public-key.asc>
#                     [--tree-date YYYYMMDD] [--install N] <cpv>...
#
# For every <cpv> Portage must choose the published binary instead of
# compiling; the first N of them (default 2) are then downloaded, verified
# against the binhost key and installed.  This is the check that was missing
# while builds completed for months and nothing installable was published.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo "[consumer-smoke] $*"; }
die() { echo "::error::$*" >&2; exit 1; }

BINHOST_URI=""
TRUST_KEY=""
TREE_DATE=""
INSTALL=2
CPVS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --binhost-uri) BINHOST_URI="$2"; shift 2 ;;
    --trust-key)   TRUST_KEY="$2";   shift 2 ;;
    --tree-date)   TREE_DATE="$2";   shift 2 ;;
    --install)     INSTALL="$2";     shift 2 ;;
    -*) die "Unknown argument: $1" ;;
    *)  CPVS+=("$1"); shift ;;
  esac
done
(( ${#CPVS[@]} > 0 )) || die "No packages to check"

bash "${SCRIPT_DIR}/setup-consumer.sh" --binhost-uri "$BINHOST_URI" --trust-key "$TRUST_KEY" \
  ${TREE_DATE:+--tree-date "$TREE_DATE"}

index="$(mktemp)"
python3 - "$BINHOST_URI" "$index" <<'PY'
import sys
import urllib.request
with urllib.request.urlopen(sys.argv[1].rstrip("/") + "/Packages", timeout=60) as response:
    data = response.read()
with open(sys.argv[2], "wb") as handle:
    handle.write(data)
PY
python3 "${SCRIPT_DIR}/portage-index.py" check "$index"

published_build_time() {
  awk -v cpv="$1" '
    /^$/ { if (found) { print time; exit } time = ""; found = 0 }
    $1 == "CPV:" && $2 == cpv { found = 1 }
    $1 == "BUILD_TIME:" { time = $2 }
    END { if (found) print time }' "$index" | head -1
}

# 1. Portage has to pick the binary.  A package it would rather compile is a
#    package whose USE flags do not match what a machine with this
#    configuration wants.  --nodeps: the question is about this package, not
#    about whether its whole dependency tree can be installed on a bare
#    stage3.
plan="$(mktemp)"
bad=0
for cpv in "${CPVS[@]}"; do
  [[ -n "$(published_build_time "$cpv")" ]] || die "${cpv} is not in the index at ${BINHOST_URI}"
  emerge --pretend --verbose --color=n --oneshot --nodeps --usepkg --getbinpkg "=${cpv}" > "$plan" 2>&1 || true
  if grep -qE "^\[binary[^]]*\] +${cpv//+/\\+}(-[0-9]+)?(:|[[:space:]]|\$)" "$plan"; then
    log "ok: ${cpv} would be installed from the binhost"
  else
    bad=$(( bad + 1 ))
    echo "::error title=Binary not used::Portage would not install ${cpv} from the binhost"
    cat "$plan"
  fi
done
(( bad == 0 )) || die "${bad} published package(s) would be compiled instead of installed"

# 2. Download, verify the signature, install.  --nodeps: this is about the
#    published file, not about whether its dependencies exist yet.
count=0
for cpv in "${CPVS[@]}"; do
  (( count < INSTALL )) || break
  count=$(( count + 1 ))
  emerge --oneshot --nodeps --usepkgonly --getbinpkg --color=n "=${cpv}"
  installed="$(tr -d '[:space:]' < "/var/db/pkg/${cpv}/BUILD_TIME")"
  expected="$(published_build_time "$cpv")"
  [[ "$installed" == "$expected" ]] \
    || die "${cpv}: installed build ${installed} is not the published build ${expected}"
  log "ok: ${cpv} downloaded, signature verified, installed (build ${installed})"
done

log "All checks passed for ${#CPVS[@]} package(s)"
