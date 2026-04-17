#!/usr/bin/env bash
# scripts/build.sh — main build script for the Gentoo binhost CI
#
# Usage:
#   build.sh --profile <profile-name> --package-list <file>
#   build.sh --profile <profile-name> --single-package <atom>
#
# Options:
#   --profile <name>         Profile directory under config/profiles/ (required)
#   --package-list <file>    Path to a newline-separated package list file
#   --single-package <atom>  Build a single package atom
#   --sign                   GPG-sign all produced .gpkg.tar files
#   --gpg-key <fingerprint>  GPG key fingerprint to use for signing
#   --output-dir <dir>       Directory to copy finished packages into (default: /var/cache/binpkgs)
#   --binhost-url <url>      URL of a binhost to fetch pre-built packages from (sets PORTAGE_BINHOST)
#   --resume                 Restore intermediate build state before running emerge
#   --state-dir <dir>        Directory for saving/restoring portage build state (default: /var/tmp/portage-state)
#   --max-build-time <min>   Stop emerge gracefully after this many minutes (90% of limit),
#                            save build state, and exit 42 ("timed out, state saved")
#   --help                   Show this help message

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------- defaults ----------
PROFILE=""
PACKAGE_LIST=""
SINGLE_PACKAGE=""
SIGN=false
GPG_KEY=""
OUTPUT_DIR="/var/cache/binpkgs"
RESUME=false
STATE_DIR="/var/tmp/portage-state"
MAX_BUILD_TIME=""
BINHOST_URL=""

# ---------- helpers ----------
die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[build.sh] $*"; }

usage() {
  sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \?//'
  exit 0
}

# ---------- argument parsing ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)        PROFILE="$2";        shift 2 ;;
    --package-list)   PACKAGE_LIST="$2";   shift 2 ;;
    --single-package) SINGLE_PACKAGE="$2"; shift 2 ;;
    --sign)           SIGN=true;           shift   ;;
    --gpg-key)        GPG_KEY="$2";        shift 2 ;;
    --output-dir)     OUTPUT_DIR="$2";     shift 2 ;;
    --resume)         RESUME=true;         shift   ;;
    --state-dir)      STATE_DIR="$2";      shift 2 ;;
    --max-build-time) MAX_BUILD_TIME="$2"; shift 2 ;;
    --binhost-url)    BINHOST_URL="$2";    shift 2 ;;
    --help|-h)        usage ;;
    *) die "Unknown argument: $1" ;;
  esac
done

# ---------- validation ----------
[[ -n "$PROFILE" ]] || die "--profile is required"
[[ -n "$PACKAGE_LIST" || -n "$SINGLE_PACKAGE" ]] \
  || die "One of --package-list or --single-package is required"
[[ -z "$PACKAGE_LIST" || -z "$SINGLE_PACKAGE" ]] \
  || die "--package-list and --single-package are mutually exclusive"

PROFILE_DIR="${REPO_ROOT}/config/profiles/${PROFILE}"
[[ -d "$PROFILE_DIR" ]] || die "Profile directory not found: ${PROFILE_DIR}"

if [[ -n "$PACKAGE_LIST" ]]; then
  [[ -f "$PACKAGE_LIST" ]] || die "Package list not found: ${PACKAGE_LIST}"
fi

if [[ -n "$MAX_BUILD_TIME" ]]; then
  [[ "$MAX_BUILD_TIME" =~ ^[1-9][0-9]*$ ]] \
    || die "--max-build-time must be a positive integer (minutes), got: ${MAX_BUILD_TIME}"
fi

if [[ -n "$BINHOST_URL" ]]; then
  # Validate every space-separated URL before any of them are written into make.conf.
  # A quote or newline in the value can break the config file or inject extra settings.
  [[ "$BINHOST_URL" != *'"'* && "$BINHOST_URL" != *"'"* ]] \
    || die "--binhost-url must not contain quote characters"
  [[ "$BINHOST_URL" != *$'\n'* ]] \
    || die "--binhost-url must not contain newlines"
  read -ra _urls <<< "$BINHOST_URL"
  for _url in "${_urls[@]}"; do
    [[ "$_url" =~ ^https?:// ]] \
      || die "--binhost-url entries must start with http:// or https://, got: ${_url}"
  done
  unset _url
fi

# ---------- portage configuration ----------
apply_profile() {
  log "Applying profile: ${PROFILE}"

  # Use nullglob so an empty profile subdirectory expands to zero arguments
  # instead of triggering a literal `cp /…/* …` error.  We deliberately do NOT
  # silence cp's stderr or `|| true` it: if cp fails for a real reason
  # (permission denied, broken mount, etc.) the job must fail RED instead of
  # silently building with no USE overrides applied.
  shopt -s nullglob

  # make.conf
  if [[ -f "${PROFILE_DIR}/make.conf" ]]; then
    cp "${PROFILE_DIR}/make.conf" /etc/portage/make.conf
    log "  Installed make.conf"
  fi

  # package.use
  mkdir -p /etc/portage/package.use
  if [[ -d "${PROFILE_DIR}/package.use" ]]; then
    local _files=( "${PROFILE_DIR}/package.use/"* )
    if (( ${#_files[@]} > 0 )); then
      cp "${_files[@]}" /etc/portage/package.use/
      log "  Installed ${#_files[@]} package.use file(s)"
    fi
  fi

  # package.accept_keywords
  mkdir -p /etc/portage/package.accept_keywords
  if [[ -d "${PROFILE_DIR}/package.accept_keywords" ]]; then
    local _files=( "${PROFILE_DIR}/package.accept_keywords/"* )
    if (( ${#_files[@]} > 0 )); then
      cp "${_files[@]}" /etc/portage/package.accept_keywords/
      log "  Installed ${#_files[@]} package.accept_keywords file(s)"
    fi
  fi

  # package.mask
  mkdir -p /etc/portage/package.mask
  if [[ -d "${PROFILE_DIR}/package.mask" ]]; then
    local _files=( "${PROFILE_DIR}/package.mask/"* )
    if (( ${#_files[@]} > 0 )); then
      cp "${_files[@]}" /etc/portage/package.mask/
      log "  Installed ${#_files[@]} package.mask file(s)"
    fi
  fi

  # package.license
  mkdir -p /etc/portage/package.license
  if [[ -d "${PROFILE_DIR}/package.license" ]]; then
    local _files=( "${PROFILE_DIR}/package.license/"* )
    if (( ${#_files[@]} > 0 )); then
      cp "${_files[@]}" /etc/portage/package.license/
      log "  Installed ${#_files[@]} package.license file(s)"
    fi
  fi

  shopt -u nullglob

  # Set the Gentoo profile.  No `|| true`: a typo or missing profile is a
  # configuration bug that must fail the job, not silently leave the previous
  # (or default stage3) profile active and produce mysteriously wrong builds.
  eselect profile set default/linux/amd64/23.0/desktop/plasma
  log "  eselect profile set"

  # Portage's config parser doesn't support $(cmd) command substitutions.
  # Evaluate any $(nproc) placeholders now that we're running under bash.
  if [[ -f /etc/portage/make.conf ]]; then
    local nproc_val
    nproc_val="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
    sed -i "s/\$(nproc)/${nproc_val}/g" /etc/portage/make.conf
    log "  Evaluated \$(nproc) → ${nproc_val} in make.conf"
  fi

  # Configure binhost for fetching pre-built packages
  if [[ -n "$BINHOST_URL" ]]; then
    echo "PORTAGE_BINHOST=\"${BINHOST_URL}\"" >> /etc/portage/make.conf
    log "  Set PORTAGE_BINHOST=${BINHOST_URL}"
  fi
}

# ---------- progress accounting ----------
# Count fully-built *.gpkg.tar files in /var/cache/binpkgs (where Portage
# always writes finished binpkgs).  Used to detect "exit 42 with zero new
# packages" so the workflow can stop wasting 5-hour resume slots on a
# permanently stuck build.
count_binpkgs() {
  if [[ -d /var/cache/binpkgs ]]; then
    find /var/cache/binpkgs -name '*.gpkg.tar' 2>/dev/null | wc -l
  else
    echo 0
  fi
}

emit_progress_summary() {
  local before="$1" after="$2"
  local delta=$(( after - before ))
  log "Build progress: ${before} → ${after} binpkgs (delta: ${delta})"
  # GitHub Actions notice — bubbles up to the run summary at the top
  echo "::notice title=Build progress::${delta} new package(s) built this attempt (total: ${after}, was: ${before})"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      echo "binpkg_count_before=${before}"
      echo "binpkg_count_after=${after}"
      echo "new_package_count=${delta}"
    } >> "$GITHUB_OUTPUT"
  fi
}

# ---------- ccache ----------
setup_ccache() {
  # Export CCACHE_DIR so every `ccache …` invocation in this shell (and any
  # child processes) targets the same directory that the workflow restores
  # and saves via actions/cache.  Without this, ccache falls back to
  # ~/.cache/ccache (e.g. /github/home/.cache/ccache under the GHA container)
  # and the restored cache at /var/cache/ccache is effectively unused, which
  # is exactly the symptom we observed (cache size 0.0 GB at every attempt).
  export CCACHE_DIR="${CCACHE_DIR:-/var/cache/ccache}"
  if command -v ccache &>/dev/null; then
    log "Configuring ccache (dir: ${CCACHE_DIR})"
    mkdir -p "${CCACHE_DIR}"
    # Do NOT silence these — if ccache config writes fail (bad CCACHE_DIR
    # perms, corrupt config, etc.) the job must fail RED.  Suppressing
    # stderr+exit here is exactly what hid the original "cache_dir defaulted
    # to ~/.cache/ccache" bug for months.
    ccache --max-size="${CCACHE_SIZE:-20G}"
    # Use file content for compiler identification (more cache hits across runs)
    ccache --set-config=compiler_check=content
    # Enable compression to save cache space
    ccache --set-config=compression=true
    ccache --set-config=compression_level=1
    # Ignore working directory in cache keys (better hit rate across jobs)
    ccache --set-config=hash_dir=false
    ccache --zero-stats
    log "ccache configuration:"
    # --show-config is informational; allow non-zero exit but keep stderr
    # visible so any "config file unreadable" message reaches the log.
    ccache --show-config || log "  (ccache --show-config failed; see stderr above)"
  fi
}

# ---------- ccache stats ----------
show_ccache_stats() {
  if command -v ccache &>/dev/null; then
    log "ccache statistics:"
    # Informational; tolerate non-zero exit but do not hide stderr.
    ccache --show-stats || log "  (ccache --show-stats failed; see stderr above)"
  fi
}

# ---------- build state ----------
restore_build_state() {
  [[ "$RESUME" == true ]] || return 0
  if [[ -d "$STATE_DIR" ]] && [[ -n "$(ls -A "$STATE_DIR" 2>/dev/null)" ]]; then
    log "Restoring build state from ${STATE_DIR}"
    mkdir -p /var/tmp/portage
    rsync -a --delete "${STATE_DIR}/" /var/tmp/portage/
    log "  Build state restored"
  else
    log "No saved build state found at ${STATE_DIR}, starting fresh"
  fi
}

save_build_state() {
  log "Saving build state to ${STATE_DIR}"
  mkdir -p "$STATE_DIR"
  if [[ -d /var/tmp/portage ]] && [[ -n "$(ls -A /var/tmp/portage 2>/dev/null)" ]]; then
    rsync -a --delete /var/tmp/portage/ "${STATE_DIR}/"
    log "  Build state saved"
  else
    log "  No intermediate build state found in /var/tmp/portage"
  fi
}

# ---------- binpkg trust ----------
setup_binpkg_trust() {
  # When fetching from a remote binhost, Portage verifies GPG signatures on
  # downloaded binary packages.  The signing key must be trusted in the
  # Portage-specific keyring (/etc/portage/gnupg/).  `getuto` (from
  # app-portage/gentoolkit) sets this up automatically.
  [[ -n "$BINHOST_URL" ]] || return 0

  # Skip if the specific Gentoo release signing key is already trusted.
  # Checking only for the keyring file is not enough — the key may be missing
  # or outdated after a rotation.
  local gentoo_key="534E4209AB49EEE1C19D96162C44695DB9F6043D"
  if [[ -d /etc/portage/gnupg ]] \
     && gpg --homedir /etc/portage/gnupg --list-keys "$gentoo_key" &>/dev/null; then
    log "Gentoo binpkg signing key ${gentoo_key} already trusted, skipping trust setup"
    return 0
  fi

  if command -v getuto &>/dev/null; then
    log "Running getuto to import Gentoo binpkg signing keys"
    getuto
    log "  Portage binary-package trust established via getuto"
  else
    log "Warning: getuto not found; setting up Portage GnuPG keyring manually"
    mkdir -p /etc/portage/gnupg
    chmod 0700 /etc/portage/gnupg
    # Initialise an empty keyring so gpg doesn't complain about missing files
    gpg --homedir /etc/portage/gnupg --list-keys &>/dev/null || true
    # Try to receive the Gentoo release key from the official keyserver
    gpg --homedir /etc/portage/gnupg \
        --keyserver hkps://keys.gentoo.org \
        --recv-keys 534E4209AB49EEE1C19D96162C44695DB9F6043D \
      && log "  Imported Gentoo release key from keyserver" \
      || log "  Warning: could not fetch Gentoo release key from keyserver; binpkg signature verification will fail"
  fi
}

# ---------- sync ----------
sync_tree() {
  if [[ -f /var/db/repos/gentoo/metadata/timestamp.chk ]]; then
    log "Portage tree already synced, skipping"
    return 0
  fi
  log "Syncing portage tree"
  # Try methods in order of preference; log which one actually succeeds so
  # silent fallbacks (e.g. webrsync mirror outage) are visible in CI logs.
  # Stderr is preserved on every attempt — earlier "2>/dev/null" suppression
  # made it impossible to tell *why* a fallback was triggered.
  if emerge-webrsync --quiet; then
    log "  Synced via emerge-webrsync"
  elif emerge --sync --quiet; then
    log "  Synced via emerge --sync (webrsync failed; see stderr above)"
  else
    log "  Falling back to emaint sync (webrsync and rsync both failed)"
    emaint sync -a
    log "  Synced via emaint"
  fi
}

# ---------- build ----------
build_packages() {
  local packages=()

  if [[ -n "$SINGLE_PACKAGE" ]]; then
    packages=("$SINGLE_PACKAGE")
  else
    # Read package list, stripping comments and blank lines
    while IFS= read -r line; do
      line="${line%%#*}"   # strip inline comments
      line="$(echo "$line" | xargs)"  # strip leading/trailing whitespace
      [[ -n "$line" ]] && packages+=("$line")
    done < "$PACKAGE_LIST"
  fi

  [[ ${#packages[@]} -gt 0 ]] || die "No packages to build"
  log "Packages to build: ${packages[*]}"

  # Build the emerge flags array; add --getbinpkg when a binhost URL is configured
  local emerge_flags=(--buildpkg --usepkg --keep-going --verbose)
  if [[ -n "$BINHOST_URL" ]]; then
    emerge_flags+=(--getbinpkg)
    # Binary packages on the binhost may have been built against older sub-slot
    # versions (e.g. :6/6.10.2=).  When newer ebuilds are available, the slot
    # operator deps from those binaries pull in the old versions alongside the
    # new ones, causing unresolvable slot conflicts.  Ignoring built slot
    # operator deps lets Portage prefer the latest ebuilds and rebuild
    # dependents as needed instead of mixing binary and source versions.
    emerge_flags+=(--ignore-built-slot-operator-deps=y)
  fi

  if [[ -n "$MAX_BUILD_TIME" ]]; then
    # Run emerge in background and monitor elapsed time.
    # Stop gracefully at 90% of the limit, save state, return 42.
    local limit_secs=$(( MAX_BUILD_TIME * 60 ))
    local warn_secs=$(( limit_secs * 9 / 10 ))

    # Launch emerge in its own process group so we can kill the whole tree
    # (emerge spawns compiler subprocesses that must also be terminated)
    setsid emerge \
      "${emerge_flags[@]}" \
      "${packages[@]}" &
    local emerge_pid=$!
    local start_time=$SECONDS

    while kill -0 "$emerge_pid" 2>/dev/null; do
      sleep 30
      local elapsed=$(( SECONDS - start_time ))
      if [[ $elapsed -ge $warn_secs ]]; then
        log "Approaching time limit (${elapsed}s elapsed / ${limit_secs}s limit), stopping emerge"
        # Send SIGTERM to the entire process group
        kill -TERM -- -${emerge_pid} 2>/dev/null || true
        # Wait up to 60 seconds for graceful exit, then force-kill the group
        local kill_wait=0
        while kill -0 "$emerge_pid" 2>/dev/null && [[ $kill_wait -lt 60 ]]; do
          sleep 5
          kill_wait=$(( kill_wait + 5 ))
        done
        if kill -0 "$emerge_pid" 2>/dev/null; then
          log "  Emerge did not exit after SIGTERM, sending SIGKILL to process group"
          kill -KILL -- -${emerge_pid} 2>/dev/null || true
        fi
        wait "$emerge_pid" 2>/dev/null || true
        save_build_state
        show_ccache_stats
        log "Build state saved; returning 42 (timed out, state saved)"
        return 42
      fi
    done

    wait "$emerge_pid"
  else
    emerge \
      "${emerge_flags[@]}" \
      "${packages[@]}"
  fi
}

# ---------- signing ----------
sign_packages() {
  [[ "$SIGN" == true ]] || return 0
  [[ -n "$GPG_KEY" ]] || die "--gpg-key must be specified when --sign is used"

  log "Signing packages in ${OUTPUT_DIR}"
  find "${OUTPUT_DIR}" -name '*.gpkg.tar' | while read -r pkg; do
    gpg --batch --yes \
        --local-user "$GPG_KEY" \
        --detach-sign --armor \
        "$pkg"
    log "  Signed: $(basename "$pkg")"
  done
}

# ---------- collect output ----------
collect_packages() {
  if [[ "$OUTPUT_DIR" != "/var/cache/binpkgs" ]]; then
    log "Copying packages to ${OUTPUT_DIR}"
    mkdir -p "$OUTPUT_DIR"
    rsync -a --include='*/' --include='*.gpkg.tar' --exclude='*' \
      /var/cache/binpkgs/ "${OUTPUT_DIR}/"
  fi
}

# ---------- main ----------
apply_profile
setup_ccache
sync_tree
setup_binpkg_trust
restore_build_state
show_ccache_stats

# Collect and sign whatever binpkgs were produced, even on a timed-out build,
# so partial results are published and later phases don't have to rebuild them.
BINPKGS_BEFORE="$(count_binpkgs)"
log "Binpkgs present before this attempt: ${BINPKGS_BEFORE}"
build_packages || BUILD_RC=$?
BUILD_RC=${BUILD_RC:-0}
BINPKGS_AFTER="$(count_binpkgs)"

collect_packages
sign_packages
show_ccache_stats
emit_progress_summary "${BINPKGS_BEFORE}" "${BINPKGS_AFTER}"

if [[ $BUILD_RC -eq 42 ]]; then
  log "Build timed out (state saved); exiting 42 so the workflow can resume in the next phase."
  exit 42
elif [[ $BUILD_RC -ne 0 ]]; then
  die "emerge failed with exit code ${BUILD_RC}"
fi

log "Build complete."
