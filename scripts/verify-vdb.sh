#!/usr/bin/env bash
# verify-vdb.sh: Remove stale VDB entries whose installed files are missing on disk.
#
# When CI restores /var/db/pkg (the VDB — Portage's "what is installed"
# database) from a system-state cache, the actual installed files under
# /usr, /lib, etc. come from the freshly-extracted stage3 image.  For any
# package that is NOT part of stage3 but was installed in a previous chain,
# the VDB claims it's installed while its files are absent from disk.
# Portage then trusts the VDB and does NOT reinstall those packages, causing
# configure-time failures when headers/libraries/executables are missing.
#
# Fix: every VDB entry records the exact files it installed in CONTENTS.
# We walk all VDB entries, sample up to 5 obj (regular-file) paths spread
# across the CONTENTS file, and remove any VDB entry whose probed files are
# absent on disk.  Portage then re-resolves and pulls/rebuilds the package
# from scratch — for ANY missing package, without a hardcoded allow-list.
#
# This script is called:
#   - from build-packages.yml before "Install build tools" so that the tools
#     emerge (ccache, gentoolkit) has a correct view of installed packages,
#   - from scripts/build.sh before the main build emerge.
#
# Usage: verify-vdb.sh [--vdb-root <path>]
#   --vdb-root <path>   VDB directory to scan (default: /var/db/pkg)
set -euo pipefail

log() { echo "[verify-vdb] $*"; }

vdb_root="/var/db/pkg"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vdb-root)
      vdb_root="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ ! -d "$vdb_root" ]]; then
  log "No VDB at ${vdb_root}, nothing to verify"
  exit 0
fi

# CONTENTS obj-line format (portage):
#   obj <absolute-path> <md5> <mtime>
# Path may contain spaces, so we strip the trailing two
# whitespace-delimited tokens (md5, mtime) rather than splitting on
# whitespace blindly.  Emit up to 5 sample paths spread across the
# file's obj entries (first, 25%, 50%, 75%, last).
_sample_obj_paths() {
  local contents="$1"
  awk '
    $1=="obj" {
      line = $0
      sub(/^obj /, "", line)
      sub(/ [^ ]+ [^ ]+$/, "", line)
      paths[++n] = line
    }
    END {
      if (n == 0) exit
      # Build a unique, ordered list of sample indices so small
      # CONTENTS (n<5) do not cause duplicate probes.
      idx[1] = 1
      idx[2] = int((n + 3) / 4)
      idx[3] = int((n + 1) / 2)
      idx[4] = int((3 * n + 1) / 4)
      idx[5] = n
      last = 0
      for (i = 1; i <= 5; i++) {
        v = idx[i]
        if (v < 1) v = 1
        if (v > n) v = n
        if (v != last) {
          print paths[v]
          last = v
        }
      }
    }' "$contents"
}

# Cached system GLIBC version — populated once before the main loop.
_SYSTEM_GLIBC_VERSION=""

_init_system_glibc_version() {
  _SYSTEM_GLIBC_VERSION=$(readelf -V /lib64/libc.so.6 2>/dev/null | \
    grep -oP 'GLIBC_\d+\.\d+' | sort -V | tail -1)
}

# Test if a library has ABI compatibility issues (GLIBC symbol version mismatch).
# Returns 0 if library is OK or check is inconclusive, 1 if incompatible.
_test_library_abi() {
  local lib="$1"
  [[ -f "$lib" ]] || return 0   # file absent — not our problem here
  [[ -n "$_SYSTEM_GLIBC_VERSION" ]] || return 0  # system version unknown, skip

  local max_required_version
  max_required_version=$(readelf -V "$lib" 2>/dev/null | \
    grep -oP 'GLIBC_\d+\.\d+' | sort -V | tail -1)

  [[ -z "$max_required_version" ]] && return 0  # library has no GLIBC requirements

  if [[ "$max_required_version" != "$_SYSTEM_GLIBC_VERSION" ]]; then
    local sorted_first
    sorted_first=$(printf '%s\n%s\n' "$_SYSTEM_GLIBC_VERSION" "$max_required_version" | sort -V | head -1)
    if [[ "$sorted_first" == "$_SYSTEM_GLIBC_VERSION" ]]; then
      log "  Library $lib requires $max_required_version but system has $_SYSTEM_GLIBC_VERSION"
      return 1
    fi
  fi
  return 0
}

_init_system_glibc_version
removed=0
shopt -s nullglob
for cat_dir in "${vdb_root}"/*/; do
  for pkg_dir in "${cat_dir}"*/; do
    contents="${pkg_dir}CONTENTS"
    [[ -f "$contents" ]] || continue

    probes=()
    while IFS= read -r probe; do
      [[ -n "$probe" ]] && probes+=("$probe")
    done < <(_sample_obj_paths "$contents")

    [[ ${#probes[@]} -gt 0 ]] || continue   # no obj entries (virtual/metapkg) — skip

    missing_probe=""
    for probe in "${probes[@]}"; do
      if [[ ! -e "$probe" ]]; then
        missing_probe="$probe"
        break
      fi
    done

    pkg_atom="${pkg_dir#"${vdb_root}"/}"
    pkg_atom="${pkg_atom%/}"

    if [[ -n "$missing_probe" ]]; then
      log "Stale VDB entry: ${pkg_atom} — probe file ${missing_probe} missing on disk"
      log "  Removing so emerge re-resolves and re-installs (or pulls a binpkg)."
      rm -rf -- "${pkg_dir%/}"
      removed=$(( removed + 1 ))
      continue
    fi

    # Check every shared library installed by this package for GLIBC ABI compatibility.
    # Any .so whose GLIBC requirements exceed the current system's GLIBC will cause
    # linker errors in packages that depend on it — remove the entire VDB entry so
    # emerge rebuilds it against the current glibc.
    abi_bad_lib=""
    while IFS= read -r so_path; do
      if ! _test_library_abi "$so_path"; then
        abi_bad_lib="$so_path"
        break
      fi
    done < <(awk '$1=="obj" {
      line = $0
      sub(/^obj /, "", line)
      sub(/ [^ ]+ [^ ]+$/, "", line)
      if (line ~ /\.so(\.|$)/) print line
    }' "$contents")

    if [[ -n "$abi_bad_lib" ]]; then
      log "Stale VDB entry: ${pkg_atom} — $(basename "$abi_bad_lib") has GLIBC symbol version mismatch"
      log "  Removing so emerge rebuilds with current glibc."
      rm -rf -- "${pkg_dir%/}"
      removed=$(( removed + 1 ))
    fi
  done
done
shopt -u nullglob

log "Removed ${removed} stale VDB entries"
