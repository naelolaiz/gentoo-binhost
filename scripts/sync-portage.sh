#!/usr/bin/env bash
# scripts/sync-portage.sh — synchronise the Portage package tree
#
# Usage:
#   sync-portage.sh [--revert YYYYMMDD] [--date-file FILE]
#
#   --revert YYYYMMDD   use the tree snapshot of that day instead of the
#                       newest one.  A build that continues an interrupted
#                       package needs the same compiler, headers and versions
#                       as the run it continues, or the compiler cache misses.
#   --date-file FILE    write the snapshot day of the synced tree here.
#
# Tries methods in order of preference (fastest/most-reliable first):
#   1. emerge-webrsync  — http snapshot, no rsync port required
#   2. emerge --sync    — rsync/git, needs network access to rsync.gentoo.org
#   3. emaint sync      — last-resort full sync
#
# Skips if the tree is already present (timestamp left by a prior sync), so it
# is safe to call multiple times.

set -euo pipefail

log() { echo "[sync-portage.sh] $*"; }

REVERT=""
DATE_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --revert)    REVERT="$2";    shift 2 ;;
    --date-file) DATE_FILE="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done
if [[ -n "$REVERT" && ! "$REVERT" =~ ^[0-9]{8}$ ]]; then
  echo "--revert expects YYYYMMDD, got: ${REVERT}" >&2
  exit 1
fi

TREE="/var/db/repos/gentoo"
TIMESTAMP="${TREE}/metadata/timestamp.chk"

# A webrsync snapshot named for day D is cut shortly after midnight UTC of
# D+1, and that moment is what metadata/timestamp.x records.
write_tree_date() {
  [[ -n "$DATE_FILE" ]] || return 0
  local epoch=""
  if [[ -f "${TREE}/metadata/timestamp.x" ]]; then
    read -r epoch _ < "${TREE}/metadata/timestamp.x" || true
  fi
  if [[ "$epoch" =~ ^[0-9]+$ ]]; then
    date -u -d "@$(( epoch - 86400 ))" +%Y%m%d > "$DATE_FILE"
  else
    : > "$DATE_FILE"
  fi
  log "Tree snapshot day: $(cat "$DATE_FILE")"
}

if [[ -f "$TIMESTAMP" ]]; then
  log "Portage tree already synced, skipping"
  write_tree_date
  exit 0
fi

log "Syncing portage tree"
# Stderr is intentionally preserved on every attempt — suppressing it (as
# earlier 2>/dev/null versions did) made it impossible to tell why a fallback
# was triggered.
if [[ -n "$REVERT" ]] && emerge-webrsync --quiet --revert="$REVERT"; then
  log "Synced via emerge-webrsync, snapshot ${REVERT}"
elif emerge-webrsync --quiet; then
  if [[ -n "$REVERT" ]]; then
    echo "::warning::Tree snapshot ${REVERT} is no longer available; using the newest one. The compiler cache of an interrupted build may not apply."
  fi
  log "Synced via emerge-webrsync"
elif emerge --sync --quiet; then
  log "Synced via emerge --sync (webrsync failed; see stderr above)"
else
  log "Falling back to emaint sync (webrsync and rsync both failed)"
  emaint sync -a
  log "Synced via emaint"
fi
write_tree_date
