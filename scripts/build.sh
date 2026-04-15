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

  # make.conf
  if [[ -f "${PROFILE_DIR}/make.conf" ]]; then
    cp "${PROFILE_DIR}/make.conf" /etc/portage/make.conf
    log "  Installed make.conf"
  fi

  # package.use
  mkdir -p /etc/portage/package.use
  if [[ -d "${PROFILE_DIR}/package.use" ]]; then
    cp "${PROFILE_DIR}/package.use/"* /etc/portage/package.use/ 2>/dev/null || true
    log "  Installed package.use files"
  fi

  # package.accept_keywords
  mkdir -p /etc/portage/package.accept_keywords
  if [[ -d "${PROFILE_DIR}/package.accept_keywords" ]]; then
    cp "${PROFILE_DIR}/package.accept_keywords/"* /etc/portage/package.accept_keywords/ 2>/dev/null || true
    log "  Installed package.accept_keywords files"
  fi

  # package.mask
  mkdir -p /etc/portage/package.mask
  if [[ -d "${PROFILE_DIR}/package.mask" ]]; then
    cp "${PROFILE_DIR}/package.mask/"* /etc/portage/package.mask/ 2>/dev/null || true
    log "  Installed package.mask files"
  fi

  # package.license
  mkdir -p /etc/portage/package.license
  if [[ -d "${PROFILE_DIR}/package.license" ]]; then
    cp "${PROFILE_DIR}/package.license/"* /etc/portage/package.license/ 2>/dev/null || true
    log "  Installed package.license files"
  fi

  # Set the Gentoo profile
  eselect profile set default/linux/amd64/23.0/desktop/plasma || true
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

# ---------- ccache ----------
setup_ccache() {
  if command -v ccache &>/dev/null; then
    log "Configuring ccache (dir: ${CCACHE_DIR:-/var/cache/ccache})"
    mkdir -p "${CCACHE_DIR:-/var/cache/ccache}"
    ccache --max-size="${CCACHE_SIZE:-20G}" 2>/dev/null || true
    # Use file content for compiler identification (more cache hits across runs)
    ccache --set-config=compiler_check=content 2>/dev/null || true
    # Enable compression to save cache space
    ccache --set-config=compression=true 2>/dev/null || true
    ccache --set-config=compression_level=1 2>/dev/null || true
    # Ignore working directory in cache keys (better hit rate across jobs)
    ccache --set-config=hash_dir=false 2>/dev/null || true
    ccache --zero-stats 2>/dev/null || true
    log "ccache configuration:"
    ccache --show-config 2>/dev/null || true
  fi
}

# ---------- ccache stats ----------
show_ccache_stats() {
  if command -v ccache &>/dev/null; then
    log "ccache statistics:"
    ccache --show-stats 2>/dev/null || true
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

# ---------- sync ----------
sync_tree() {
  if [[ -f /var/db/repos/gentoo/metadata/timestamp.chk ]]; then
    log "Portage tree already synced, skipping"
    return 0
  fi
  log "Syncing portage tree"
  # emerge-webrsync is faster in CI (downloads a compressed snapshot over HTTPS)
  # Fall back to emerge --sync (rsync) or emaint sync if webrsync is unavailable
  emerge-webrsync --quiet 2>/dev/null \
    || emerge --sync --quiet \
    || emaint sync -a
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
restore_build_state
show_ccache_stats

# Collect and sign whatever binpkgs were produced, even on a timed-out build,
# so partial results are published and later phases don't have to rebuild them.
build_packages || BUILD_RC=$?
BUILD_RC=${BUILD_RC:-0}

collect_packages
sign_packages
show_ccache_stats

if [[ $BUILD_RC -eq 42 ]]; then
  log "Build timed out (state saved); exiting 42 so the workflow can resume in the next phase."
  exit 42
elif [[ $BUILD_RC -ne 0 ]]; then
  die "emerge failed with exit code ${BUILD_RC}"
fi

log "Build complete."
