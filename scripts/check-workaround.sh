#!/usr/bin/env bash
# scripts/check-workaround.sh — determine if a single workaround is still needed
#
# Usage:
#   check-workaround.sh iuse              <category/package> <flag>
#   check-workaround.sh dep-grep          <category/package> <pattern> <present_means_needed>
#   check-workaround.sh required-use-grep <category/package> <pattern>
#   check-workaround.sh version-gt        <category/package> <pinned-version>
#
# Writes one of  needed | removable | unknown  to stdout.
# Diagnostic messages go to stderr so they appear in the workflow log
# without polluting the captured output.

set -euo pipefail

PKG_TREE="/var/db/repos/gentoo"

_ensure_pkg() {
  local pkg="$1" pkg_dir="${PKG_TREE}/$1"
  if [[ ! -d "$pkg_dir" ]]; then
    echo "  ${pkg}: package directory not found — skipping" >&2
    echo "unknown"
    return 1
  fi
  if ! find "$pkg_dir" -maxdepth 1 -name '*.ebuild' | grep -q .; then
    echo "  ${pkg}: no ebuilds found — skipping" >&2
    echo "unknown"
    return 1
  fi
  return 0
}

check_iuse() {
  local pkg="$1" flag="$2"
  _ensure_pkg "$pkg" || return 0
  local pkg_dir="${PKG_TREE}/${pkg}"
  if grep -rqlw "$flag" "${pkg_dir}/" --include='*.ebuild'; then
    echo "  ${pkg}: USE flag '${flag}' still present" >&2
    echo "needed"
  else
    echo "  ${pkg}: USE flag '${flag}' no longer present" >&2
    echo "removable"
  fi
}

check_dep_grep() {
  local pkg="$1" pattern="$2" present_means_needed="${3:-true}"
  _ensure_pkg "$pkg" || return 0
  local pkg_dir="${PKG_TREE}/${pkg}"
  if grep -rqlE "$pattern" "${pkg_dir}/" --include='*.ebuild'; then
    if [[ "$present_means_needed" == "true" ]]; then
      echo "  ${pkg}: pattern '${pattern}' still found" >&2
      echo "needed"
    else
      echo "  ${pkg}: pattern '${pattern}' found (removable)" >&2
      echo "removable"
    fi
  else
    if [[ "$present_means_needed" == "true" ]]; then
      echo "  ${pkg}: pattern '${pattern}' no longer found" >&2
      echo "removable"
    else
      echo "  ${pkg}: pattern '${pattern}' not found (needed)" >&2
      echo "needed"
    fi
  fi
}

check_required_use_grep() {
  local pkg="$1" pattern="$2"
  _ensure_pkg "$pkg" || return 0
  local pkg_dir="${PKG_TREE}/${pkg}"
  # -z treats the whole file as a single record so multi-line REQUIRED_USE is matched
  if grep -rqlzE "$pattern" "${pkg_dir}/" --include='*.ebuild'; then
    echo "  ${pkg}: REQUIRED_USE pattern still present" >&2
    echo "needed"
  else
    echo "  ${pkg}: REQUIRED_USE pattern no longer present" >&2
    echo "removable"
  fi
}

check_version_gt() {
  local pkg="$1" pinned="$2"
  local pn="${pkg#*/}"
  _ensure_pkg "$pkg" || return 0
  local pkg_dir="${PKG_TREE}/${pkg}"
  # Extract PV from ebuild filename: strip leading pn- and trailing .ebuild
  local best
  best=$(find "$pkg_dir" -maxdepth 1 -name "${pn}-*.ebuild" \
    | sed "s|.*/${pn}-\(.*\)\.ebuild|\1|" | sort -V | tail -1)
  if [[ -z "$best" ]]; then
    echo "  ${pkg}: no versioned ebuilds found" >&2
    echo "unknown"
    return 0
  fi
  # removable when a version strictly newer than $pinned exists
  if printf '%s\n' "$pinned" "$best" | sort -V | tail -1 | grep -qxF "$best" \
     && [[ "$best" != "$pinned" ]]; then
    echo "  ${pkg}: best available ${best} > pinned ${pinned}" >&2
    echo "removable"
  else
    echo "  ${pkg}: best available ${best} == pinned ${pinned}" >&2
    echo "needed"
  fi
}

TYPE="${1:-}"
shift
case "$TYPE" in
  iuse)               check_iuse "$@" ;;
  dep-grep)           check_dep_grep "$@" ;;
  required-use-grep)  check_required_use_grep "$@" ;;
  version-gt)         check_version_gt "$@" ;;
  *) echo "Unknown check type: '${TYPE}'" >&2; exit 1 ;;
esac
