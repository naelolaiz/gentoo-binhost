#!/usr/bin/env bash
# sync-stage3-tag.sh — one-command way to bump the pinned Gentoo stage3 tag.
#
# Rewrites every `STAGE3_TAG:` env line and every `image: gentoo/stage3:<tag>`
# occurrence across .github/workflows/*.yml to match a single canonical tag.
# Replaces the three-places-by-hand ritual documented in the comments on
# build-packages.yml and check-stage3.yml's issue body.
#
# Usage:
#   sync-stage3-tag.sh --write <new-tag>
#     Rewrites every reference in-place.  Typical invocation when bumping.
#
#   sync-stage3-tag.sh --check
#     Checks that every reference matches the tag in build-packages.yml's
#     STAGE3_TAG env line (the declared source of truth).  Exits 1 on drift.
#     Used in CI by the build workflow and by the lint workflow.
#
#   sync-stage3-tag.sh --check <expected-tag>
#     Checks that every reference matches <expected-tag> instead of
#     deriving it from build-packages.yml.  Useful in a pre-bump sanity check.
#
# Recognised reference sites (edit this list — and only this list — when
# adding a new workflow that pins stage3):
#
#   * STAGE3_TAG: <tag>                       (any .github/workflows/*.yml)
#   * image: gentoo/stage3:<tag>              (any .github/workflows/*.yml)
#
# Lines containing `gentoo/stage3:latest` are intentionally NOT rewritten:
# check-workarounds.yml uses :latest on purpose (to test workarounds against
# the CURRENT tree, not the pinned stage3).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKFLOWS_DIR="${REPO_ROOT}/.github/workflows"
BUILD_WF="${WORKFLOWS_DIR}/build-packages.yml"

log() { echo "[sync-stage3-tag] $*"; }

usage() {
  sed -n '/^# Usage:/,/^# Recognised/p' "$0" | sed 's/^# \?//'
  exit 2
}

# Pure-stdlib tag shape check — a stage3 tag looks like amd64-openrc-20260420.
# Reject anything that doesn't parse so a typo can't silently stomp every file.
_is_valid_tag() {
  [[ "$1" =~ ^amd64-(openrc|systemd)-[0-9]{8}$ ]]
}

# Emit every (file, line-number, current-value) triple that the tool knows
# how to rewrite.  Single source of truth for "where are stage3 tags
# referenced?" — grep patterns appear nowhere else.
#
# `|| true` on each grep: under `set -e`, a grep that finds zero matches
# exits 1 and would abort the whole scan halfway through a workflow sweep.
# We want "no matches" to mean "no references in this file", not "abort".
_scan_references() {
  shopt -s nullglob
  local f lineno rest tag
  for f in "${WORKFLOWS_DIR}"/*.yml; do
    # STAGE3_TAG: <tag>
    while IFS=: read -r lineno rest; do
      [[ -n "$lineno" ]] || continue
      tag="${rest#*:}"
      tag="${tag# }"
      printf '%s\t%s\tSTAGE3_TAG\t%s\n' "$f" "$lineno" "$tag"
    done < <(grep -nE '^[[:space:]]*STAGE3_TAG:[[:space:]]+' "$f" || true)
    # image: gentoo/stage3:<tag>  (but NOT :latest)
    while IFS=: read -r lineno rest; do
      [[ -n "$lineno" ]] || continue
      tag="${rest##*gentoo/stage3:}"
      tag="${tag%% *}"
      [[ "$tag" == "latest" ]] && continue
      printf '%s\t%s\timage\t%s\n' "$f" "$lineno" "$tag"
    done < <(grep -nE '^[[:space:]]*image:[[:space:]]+gentoo/stage3:' "$f" || true)
  done
  shopt -u nullglob
}

_derive_canonical() {
  [[ -f "$BUILD_WF" ]] || { echo "ERROR: ${BUILD_WF} missing" >&2; exit 1; }
  local tag
  tag=$(grep -oP '(?<=^  STAGE3_TAG: )[^ ]+' "$BUILD_WF" | head -1 || true)
  [[ -n "$tag" ]] || { echo "ERROR: STAGE3_TAG not found in ${BUILD_WF}" >&2; exit 1; }
  printf '%s\n' "$tag"
}

do_check() {
  local expected="$1"
  _is_valid_tag "$expected" \
    || { echo "ERROR: canonical tag '${expected}' does not match amd64-(openrc|systemd)-YYYYMMDD" >&2; exit 1; }

  log "canonical tag: ${expected}"
  local drift=0
  while IFS=$'\t' read -r file lineno kind actual; do
    if [[ "$actual" != "$expected" ]]; then
      printf '::error file=%s,line=%s::stage3 tag drift (%s): got %s, expected %s\n' \
        "$file" "$lineno" "$kind" "$actual" "$expected"
      drift=1
    else
      log "  OK ${file}:${lineno} ${kind}=${actual}"
    fi
  done < <(_scan_references)
  if [[ "$drift" -ne 0 ]]; then
    echo "::error title=Stage3 tag drift::Run 'scripts/sync-stage3-tag.sh --write ${expected}' to fix" >&2
    exit 1
  fi
  log "no drift; all references match ${expected}"
}

do_write() {
  local new_tag="$1"
  _is_valid_tag "$new_tag" \
    || { echo "ERROR: tag '${new_tag}' does not match amd64-(openrc|systemd)-YYYYMMDD" >&2; exit 1; }

  local rewrote=0
  while IFS=$'\t' read -r file lineno kind actual; do
    if [[ "$actual" == "$new_tag" ]]; then
      continue
    fi
    log "  ${file}:${lineno} ${kind}: ${actual} -> ${new_tag}"
    # Rewrite only the matched tag value, not the surrounding text.
    # Using a file-specific sed invocation per line keeps blast radius tight.
    case "$kind" in
      STAGE3_TAG)
        sed -i -E "${lineno}s|^([[:space:]]*STAGE3_TAG:[[:space:]]+).*$|\\1${new_tag}|" "$file"
        ;;
      image)
        sed -i -E "${lineno}s|(image:[[:space:]]+gentoo/stage3:)[^[:space:]]+|\\1${new_tag}|" "$file"
        ;;
    esac
    rewrote=$(( rewrote + 1 ))
  done < <(_scan_references)
  log "rewrote ${rewrote} reference(s) to ${new_tag}"
  # Final verification: run the check with the new canonical tag so a
  # miscounted sed invocation fails loud instead of leaving mixed state.
  do_check "$new_tag"
}

case "${1:-}" in
  --check)
    expected="${2:-}"
    if [[ -z "$expected" ]]; then
      expected="$(_derive_canonical)"
    fi
    do_check "$expected"
    ;;
  --write)
    [[ -n "${2:-}" ]] || usage
    do_write "$2"
    ;;
  -h|--help|"")
    usage
    ;;
  *)
    echo "Unknown argument: $1" >&2
    usage
    ;;
esac
