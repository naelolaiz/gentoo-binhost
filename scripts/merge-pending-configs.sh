#!/usr/bin/env bash
# merge-pending-configs.sh — auto-merge any CONFIG_PROTECT files emerge
# dropped as ._cfg0000_* in /etc.
#
# CI policy is "always take the new file" (`etc-update --automode -5`) because
# we have no local /etc edits worth preserving.  Failing to merge leaves VDB
# entries claiming the new configs are installed while on-disk only the stale
# stage3 version exists — same VDB-vs-disk drift verify-vdb.sh guards against,
# just for /etc, where /etc/env.d/* and /etc/ld.so.conf.d/* silently affect
# every subsequent build.
#
# env-update runs afterwards so /etc/profile.env, /etc/ld.so.conf, and the
# linker cache pick up any newly-merged env.d / ld.so.conf.d entries.
#
# NOTE: this script does NOT `. /etc/profile` — that only affects the script's
# own shell and would be lost on exit.  Each caller must source /etc/profile
# itself if it cares about the new env in its *own* process.
#
# Usage: merge-pending-configs.sh [tag]
#   tag   Optional short string prepended to log lines so the caller is
#         identifiable in the CI log (defaults to "merge-pending-configs").
set -euo pipefail

tag="${1:-merge-pending-configs}"
log() { echo "[${tag}] $*"; }

before=$(find /etc -name '._cfg[0-9][0-9][0-9][0-9]_*' -print | wc -l)
log "${before} pending ._cfg* file(s) under /etc"
if [[ "$before" -eq 0 ]]; then
  exit 0
fi

if ! command -v etc-update >/dev/null; then
  echo "[${tag}] ERROR: etc-update not found; cannot merge ._cfg* files" >&2
  exit 1
fi

etc-update --automode -5
env-update

remaining=$(find /etc -name '._cfg[0-9][0-9][0-9][0-9]_*' -print | wc -l)
log "${remaining} pending ._cfg* file(s) remain after merge (started with ${before})"
