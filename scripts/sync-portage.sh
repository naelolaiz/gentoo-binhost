#!/usr/bin/env bash
# scripts/sync-portage.sh — synchronise the Portage package tree
#
# Tries methods in order of preference (fastest/most-reliable first):
#   1. emerge-webrsync  — http snapshot, no rsync port required
#   2. emerge --sync    — rsync/git, needs network access to rsync.gentoo.org
#   3. emaint sync      — last-resort full sync
#
# Skips if the tree is already fresh (timestamp present from a prior sync in
# the same container session), so it is safe to call multiple times.

set -euo pipefail

log() { echo "[sync-portage.sh] $*"; }

TIMESTAMP="/var/db/repos/gentoo/metadata/timestamp.chk"
if [[ -f "$TIMESTAMP" ]]; then
  log "Portage tree already synced, skipping"
  exit 0
fi

log "Syncing portage tree"
# Stderr is intentionally preserved on every attempt — suppressing it (as
# earlier 2>/dev/null versions did) made it impossible to tell why a fallback
# was triggered.
if emerge-webrsync --quiet; then
  log "Synced via emerge-webrsync"
elif emerge --sync --quiet; then
  log "Synced via emerge --sync (webrsync failed; see stderr above)"
else
  log "Falling back to emaint sync (webrsync and rsync both failed)"
  emaint sync -a
  log "Synced via emaint"
fi
