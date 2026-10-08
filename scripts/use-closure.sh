#!/usr/bin/env bash
# use-closure.sh — work out which packages need a USE flag so that a set of
# atoms with USE dependencies can be installed.
#
# Usage (inside a Gentoo stage3 container, repository mounted at /repo):
#   use-closure.sh <tier-file> <output-file> <generated-file-name>
#
#   <tier-file>            atoms that have to resolve, e.g.
#                          media-libs/mesa[abi_x86_32]
#   <output-file>          where to write the package.use lines
#   <generated-file-name>  name of the package.use file this output replaces;
#                          it is ignored while computing, so entries that are
#                          no longer needed disappear
#
# An atom like media-libs/fontconfig[abi_x86_32] cannot be installed until
# fontconfig itself and every library it links to have the flag as well.
# Portage names one missing package at a time; this script keeps asking and
# collects the answers.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=config/binhost.conf
. "${REPO_ROOT}/config/binhost.conf"

TIER_FILE="${1:-}"
OUTPUT="${2:-}"
GENERATED="${3:-}"
[[ -f "$TIER_FILE" && -n "$OUTPUT" && -n "$GENERATED" ]] \
  || { sed -n '2,/^set -euo/s/^# \{0,1\}//p' "$0" >&2; exit 1; }

bash "${SCRIPT_DIR}/sync-portage.sh"
bash "${SCRIPT_DIR}/sync-overlays.sh"
bash "${SCRIPT_DIR}/apply-profile.sh" "$PROFILE_NAME" "$GENTOO_PROFILE"
rm -f "/etc/portage/package.use/${GENERATED}"

atoms=()
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%%#*}"
  line="$(xargs <<< "$line")"
  [[ -n "$line" ]] && atoms+=("$line")
done < "$TIER_FILE"
(( ${#atoms[@]} > 0 )) || { echo "No atoms in ${TIER_FILE}" >&2; exit 1; }

work="/etc/portage/package.use/zz-use-closure"
log="$(mktemp)"
: > "$work"
for _ in $(seq 1 100); do
  if emerge --pretend --color=n --oneshot --update --deep --newuse --backtrack=100 \
       "${atoms[@]}" > "$log" 2>&1; then
    break
  fi
  before="$(wc -l < "$work")"
  # Only flags to switch on are collected.  While it searches, Portage also
  # proposes switching flags off again; those are alternatives it tried, not
  # requirements.
  # Slotted packages get the flag for the slot that needs it only: LLVM has
  # several slots installed side by side, and only the one Mesa uses has to
  # be built for 32 bit as well.
  add() {
    local enable atom slot
    enable="$(tr ' ' '\n' <<< "${2//+/}" | grep -v '^-' | xargs || true)"
    [[ -n "$enable" ]] || return 0
    atom="$(qatom -F '%{CATEGORY}/%{PN}' "$1")"
    slot="$(portageq metadata / ebuild "$(qatom -F '%{CATEGORY}/%{PF}' "$1")" SLOT 2>/dev/null || true)"
    slot="${slot%%/*}"
    [[ -z "$slot" || "$slot" == 0 ]] || atom="${atom}:${slot}"
    echo "${atom} ${enable}" >> "$work"
  }
  # Portage usually names everything at once:
  #   The following USE changes are necessary to proceed:
  #   >=media-libs/fontconfig-2.18.3 abi_x86_32
  while read -r atom flags; do
    add "$atom" "$flags"
  done < <(awk '/USE changes are necessary to proceed/ { on = 1 }
                on && /^[<>=~]+[A-Za-z0-9_-]+\// { print }' "$log")
  # ... and sometimes one package at a time:
  #   - media-libs/fontconfig-2.18.3::gentoo (Change USE: +abi_x86_32)
  while read -r cpv flags; do
    add "$cpv" "$flags"
  done < <(sed -nE 's/^- ([^ :]+)::[A-Za-z0-9_-]+ \(Change USE: ([^)]*)\)$/\1 \2/p' "$log")
  sort -u -o "$work" "$work"
  if [[ "$(wc -l < "$work")" == "$before" ]]; then
    # Nothing new was asked for.  A build-time dependency loop on a bare
    # stage3 is not a USE problem; the builder deals with those on its own.
    grep -q 'Error: circular dependencies' "$log" && break
    cat "$log" >&2
    echo "Portage cannot resolve the atoms for a reason other than a missing USE flag" >&2
    exit 1
  fi
done

# Keep the explanatory header of the file being replaced.  Read it before
# writing: the output may be that very file.
current="${REPO_ROOT}/config/profiles/${PROFILE_NAME}/package.use/${GENERATED}"
header=""
[[ -f "$current" ]] && header="$(sed -n '/^#/!q;p' "$current")"
{
  [[ -n "$header" ]] && printf '%s\n' "$header"
  sort -u "$work"
} > "$OUTPUT"
echo "$(sort -u "$work" | wc -l) package(s) need a USE change; written to ${OUTPUT}"
