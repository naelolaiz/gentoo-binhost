#!/usr/bin/env bash
# Main build script for the Gentoo binhost CI.
#
# The CI intentionally starts each attempt from a clean stage3 image.  The
# only state carried between attempts is:
#   - /var/cache/binpkgs: finished packages from this build chain
#   - /var/cache/ccache: compiler cache
#
# We do not restore Portage's installed-package database or previous workdirs.
# A stale installed DB can claim that libraries are usable when the filesystem
# or ABI is not, which turns dependency problems into late compile failures.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PROFILE=""
GENTOO_PROFILE=""
PACKAGE_LIST=""
SINGLE_PACKAGE=""
SIGN=false
GPG_KEY=""
OUTPUT_DIR="/var/cache/binpkgs"
STATE_DIR="/var/tmp/portage-state"
MAX_BUILD_TIME=""
BINHOST_URL=""

FAILURE_LOG_TAIL_LINES=80
FAILED_ATOM_COUNT=0
_TIMEOUT_FIRED_AT=0

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[build.sh] $*"; }

usage() {
  sed -n '/^# Main build script/,/^$/p' "$0" | sed 's/^# \?//'
  cat <<'EOF'

Usage:
  build.sh --profile <profile-name> --gentoo-profile <path> --package-list <file> [options]
  build.sh --profile <profile-name> --gentoo-profile <path> --single-package <atom> [options]

Options:
  --profile <name>         Profile directory under config/profiles/
  --gentoo-profile <path>  Gentoo profile path passed to eselect
  --package-list <file>    Newline-separated package list
  --single-package <atom>  Build one package atom
  --sign                   GPG-sign produced packages
  --gpg-key <fingerprint>  GPG key fingerprint for signing
  --output-dir <dir>       Copy finished packages here
  --binhost-url <url>      Space-separated PORTAGE_BINHOST URL(s)
  --state-dir <dir>        Directory for failure metadata
  --max-build-time <min>   Stop emerge after 90% of this budget and exit 42
  --resume                 Accepted for backwards compatibility; ignored
  --help                   Show this help
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)        PROFILE="$2";        shift 2 ;;
    --gentoo-profile) GENTOO_PROFILE="$2"; shift 2 ;;
    --package-list)   PACKAGE_LIST="$2";   shift 2 ;;
    --single-package) SINGLE_PACKAGE="$2"; shift 2 ;;
    --sign)           SIGN=true;           shift ;;
    --gpg-key)        GPG_KEY="$2";        shift 2 ;;
    --output-dir)     OUTPUT_DIR="$2";     shift 2 ;;
    --state-dir)      STATE_DIR="$2";      shift 2 ;;
    --max-build-time) MAX_BUILD_TIME="$2"; shift 2 ;;
    --binhost-url)    BINHOST_URL="$2";    shift 2 ;;
    --resume)         shift ;;
    --help|-h)        usage ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -n "$PROFILE" ]] || die "--profile is required"
[[ -n "$GENTOO_PROFILE" ]] || die "--gentoo-profile is required"
[[ -n "$PACKAGE_LIST" || -n "$SINGLE_PACKAGE" ]] \
  || die "One of --package-list or --single-package is required"
[[ -z "$PACKAGE_LIST" || -z "$SINGLE_PACKAGE" ]] \
  || die "--package-list and --single-package are mutually exclusive"
[[ -d "${REPO_ROOT}/config/profiles/${PROFILE}" ]] \
  || die "Profile directory not found: ${REPO_ROOT}/config/profiles/${PROFILE}"
if [[ -n "$PACKAGE_LIST" ]]; then
  [[ -f "$PACKAGE_LIST" ]] || die "Package list not found: ${PACKAGE_LIST}"
fi
if [[ -n "$MAX_BUILD_TIME" ]]; then
  [[ "$MAX_BUILD_TIME" =~ ^[1-9][0-9]*$ ]] \
    || die "--max-build-time must be a positive integer, got: ${MAX_BUILD_TIME}"
fi
if [[ -n "$BINHOST_URL" ]]; then
  [[ "$BINHOST_URL" != *'"'* && "$BINHOST_URL" != *"'"* ]] \
    || die "--binhost-url must not contain quote characters"
  [[ "$BINHOST_URL" != *$'\n'* ]] \
    || die "--binhost-url must not contain newlines"
  read -ra _urls <<< "$BINHOST_URL"
  for _url in "${_urls[@]}"; do
    [[ "$_url" =~ ^https?:// ]] \
      || die "--binhost-url entries must start with http:// or https://, got: ${_url}"
  done
  unset _url _urls
fi

apply_profile() {
  local args=("${PROFILE}" "${GENTOO_PROFILE}")
  if [[ -n "$BINHOST_URL" ]]; then
    args+=(--binhost-url "$BINHOST_URL")
  fi
  bash "${SCRIPT_DIR}/apply-profile.sh" \
    "${args[@]}"
}

count_binpkgs() {
  if [[ -d /var/cache/binpkgs ]]; then
    find /var/cache/binpkgs -name '*.gpkg.tar' | wc -l
  else
    echo 0
  fi
}

emit_progress_summary() {
  local before="$1" after="$2"
  local delta=$(( after - before ))
  log "Build progress: ${before} -> ${after} binpkgs (delta: ${delta})"
  echo "::notice title=Build progress::${delta} new package(s) built this attempt (total: ${after}, was: ${before})"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      echo "binpkg_count_before=${before}"
      echo "binpkg_count_after=${after}"
      echo "new_package_count=${delta}"
    } >> "$GITHUB_OUTPUT"
  fi
}

report_failed_atoms() {
  if [[ "${_REPORT_FAILED_ATOMS_DONE:-0}" == "1" ]]; then
    log "report_failed_atoms: already ran in this process; skipping re-entry"
    return 0
  fi
  _REPORT_FAILED_ATOMS_DONE=1

  local portage_tmp="/var/tmp/portage"
  local failures_dir="${OUTPUT_DIR%/}/_failures"
  local list_file="${STATE_DIR%/}/failed-packages.txt"
  local captured_count=0

  FAILED_ATOM_COUNT=0
  mkdir -p "$failures_dir" "$STATE_DIR"
  : > "$list_file"

  if [[ ! -d "$portage_tmp" ]]; then
    log "No /var/tmp/portage found; no per-atom failures to report"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
      {
        echo "failed_package_count=0"
      } >> "$GITHUB_OUTPUT"
    fi
    return 0
  fi

  local die_files=()
  while IFS= read -r -d '' f; do die_files+=("$f"); done < <(
    find "$portage_tmp" -mindepth 3 -maxdepth 3 -type f -name .die_hooks -print0
  )
  while IFS= read -r -d '' f; do die_files+=("$f"); done < <(
    find "$portage_tmp" -mindepth 4 -maxdepth 4 -type f -name die.env -print0
  )

  if [[ ${#die_files[@]} -eq 0 ]]; then
    log "No failed atoms detected"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
      {
        echo "failed_package_count=0"
      } >> "$GITHUB_OUTPUT"
    fi
    return 0
  fi

  log "Detected ${#die_files[@]} failure marker(s); collecting real ebuild failures"

  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo ""
      echo "### Failed packages"
      echo ""
      echo "Timeout victims are filtered out. Full logs are uploaded under \`_failures/\` in the build artifact."
      echo ""
    } >> "$GITHUB_STEP_SUMMARY"
  fi

  local f cat_pkg cat pkg temp_dir phase env_src build_log dest
  local -A seen_atoms=()
  for f in "${die_files[@]}"; do
    cat_pkg="${f#"${portage_tmp}"/}"
    case "$f" in
      */.die_hooks)
        cat_pkg="${cat_pkg%/.die_hooks}"
        temp_dir="${portage_tmp}/${cat_pkg}/temp"
        ;;
      */temp/die.env)
        cat_pkg="${cat_pkg%/temp/die.env}"
        temp_dir="$(dirname "$f")"
        ;;
      *)
        log "  WARNING: unrecognised marker path '${f}', skipping"
        continue
        ;;
    esac
    [[ -z "${seen_atoms[$cat_pkg]:-}" ]] || continue
    seen_atoms["$cat_pkg"]=1

    if [[ "$_TIMEOUT_FIRED_AT" -gt 0 ]]; then
      local f_mtime
      f_mtime=$(stat -c %Y "$f")
      if [[ "$f_mtime" -ge $((_TIMEOUT_FIRED_AT - 2)) ]]; then
        log "  Skipping ${cat_pkg}: timeout victim, not a real failure"
        continue
      fi
    fi

    cat="${cat_pkg%%/*}"
    pkg="${cat_pkg##*/}"
    phase=""
    env_src=""
    if [[ -f "${temp_dir}/environment" ]]; then
      env_src="${temp_dir}/environment"
    elif [[ -f "${temp_dir}/die.env" ]]; then
      env_src="${temp_dir}/die.env"
    fi
    if [[ -n "$env_src" ]]; then
      phase="$(grep -m1 -E '(^|[[:space:]])EBUILD_PHASE=' "$env_src" \
        | sed -E 's/.*EBUILD_PHASE=//; s/^"//; s/"$//' || true)"
    fi
    if [[ -z "$phase" && -f "${temp_dir}/build.log" ]]; then
      phase="$(grep -m1 -oE 'failed \([a-z_-]+ phase\)' "${temp_dir}/build.log" \
        | sed -E 's/^failed \(([a-z_-]+) phase\)$/\1/' || true)"
    fi
    [[ -n "$phase" ]] || phase="unknown"

    echo "${cat}/${pkg}" >> "$list_file"
    captured_count=$(( captured_count + 1 ))

    build_log="${temp_dir}/build.log"
    dest="${failures_dir}/${cat}/${pkg}"
    mkdir -p "$dest"
    [[ -f "$build_log" ]] && cp "$build_log" "${dest}/build.log"
    [[ -f "${temp_dir}/environment" ]] && cp "${temp_dir}/environment" "${dest}/environment"
    [[ -f "${temp_dir}/die.env" ]] && cp "${temp_dir}/die.env" "${dest}/die.env"

    echo "::error title=Package build failed::${cat}/${pkg} failed in phase '${phase}'. See _failures/${cat}/${pkg}/build.log in the build artifact."

    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
      {
        echo "<details><summary><strong>${cat}/${pkg}</strong> - failed in <code>${phase}</code></summary>"
        echo ""
        if [[ -f "${dest}/build.log" ]]; then
          echo "Last ${FAILURE_LOG_TAIL_LINES} lines of \`build.log\`:"
          echo ""
          echo '```'
          tail -n "${FAILURE_LOG_TAIL_LINES}" "${dest}/build.log"
          echo '```'
        else
          echo "_No build.log was preserved._"
        fi
        echo ""
        echo "</details>"
        echo ""
      } >> "$GITHUB_STEP_SUMMARY"
    fi
    log "  Captured failure: ${cat}/${pkg} (phase: ${phase})"
  done

  if [[ "$captured_count" -eq 0 ]]; then
    log "No real failed atoms after timeout filtering"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
      {
        echo "failed_package_count=0"
      } >> "$GITHUB_OUTPUT"
    fi
    return 0
  fi

  FAILED_ATOM_COUNT="$captured_count"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      echo "failed_package_count=${captured_count}"
    } >> "$GITHUB_OUTPUT"
  fi
}

setup_ccache() {
  export CCACHE_DIR="${CCACHE_DIR:-/var/cache/ccache}"
  if command -v ccache >/dev/null; then
    log "Configuring ccache (dir: ${CCACHE_DIR})"
    mkdir -p "${CCACHE_DIR}"
    ccache --max-size="${CCACHE_SIZE:-20G}"
    ccache --set-config=compiler_check=content
    ccache --set-config=compression=true
    ccache --set-config=compression_level=1
    ccache --set-config=hash_dir=false
    ccache --zero-stats
    ccache --show-config || log "  (ccache --show-config failed)"
  fi
}

show_ccache_stats() {
  if command -v ccache >/dev/null; then
    log "ccache statistics:"
    ccache --show-stats || log "  (ccache --show-stats failed)"
  fi
}

_dir_size_bytes() {
  local d="$1"
  if [[ -d "$d" ]]; then
    du -sb "$d" | awk '{print $1+0}'
  else
    echo 0
  fi
}

measure_cache_footprint() {
  local phase="${1:-}"
  local dirs=(/var/cache/binpkgs /var/cache/ccache)
  local total=0 d size human_size human_total
  log "Cache footprint (${phase}):"
  for d in "${dirs[@]}"; do
    size="$(_dir_size_bytes "$d")"
    total=$(( total + size ))
    human_size="$(numfmt --to=iec --suffix=B "$size" || echo "${size}B")"
    log "  ${d}: ${human_size}"
  done
  human_total="$(numfmt --to=iec --suffix=B "$total" || echo "${total}B")"
  log "  TOTAL: ${human_total} (GHA per-repo cache cap: 10 GiB)"
  if [[ -n "${GITHUB_OUTPUT:-}" && "$phase" == "after" ]]; then
    echo "cache_total_bytes=${total}" >> "$GITHUB_OUTPUT"
  fi
}

setup_binpkg_trust() {
  [[ -n "$BINHOST_URL" ]] || return 0
  bash "${SCRIPT_DIR}/setup-binpkg-trust.sh"
}

sync_tree() {
  bash "${SCRIPT_DIR}/sync-portage.sh"
}

merge_pending_configs() {
  bash "${SCRIPT_DIR}/merge-pending-configs.sh" build.sh
  if [[ -f /etc/profile ]]; then
    set +u
    # shellcheck disable=SC1091
    . /etc/profile
    set -u
  fi
}

display_and_read_news() {
  log "Displaying unread Gentoo news items"
  eselect --colour=no news read new || true
  log "News items after read:"
  eselect --colour=no news list || true
}

emerge_common_flags() {
  local -n _out=$1
  _out=(--buildpkg --usepkg --verbose)
  if [[ -n "$BINHOST_URL" ]]; then
    _out+=(--getbinpkg --ignore-built-slot-operator-deps=y)
  fi
}

ensure_kernel_symlink() {
  log "Checking for installed kernel sources"
  local -a kernel_dirs kernel_flags
  shopt -s nullglob
  kernel_dirs=(/usr/src/linux-*)
  shopt -u nullglob
  if (( ${#kernel_dirs[@]} == 0 )); then
    log "No kernel sources installed; emerging sys-kernel/gentoo-kernel-bin"
    emerge_common_flags kernel_flags
    emerge "${kernel_flags[@]}" sys-kernel/gentoo-kernel-bin
    shopt -s nullglob
    kernel_dirs=(/usr/src/linux-*)
    shopt -u nullglob
    (( ${#kernel_dirs[@]} > 0 )) \
      || die "No /usr/src/linux-* directory present after emerging gentoo-kernel-bin"
  fi
  local target
  target=$(printf '%s\n' "${kernel_dirs[@]}" | sort -V | tail -n1)
  log "Setting /usr/src/linux -> ${target}"
  ln -sfn "${target##*/}" /usr/src/linux
  log "  /usr/src/linux -> $(readlink /usr/src/linux)"
}

run_emerge_with_deadline() {
  local deadline="$1"
  shift
  if [[ "$deadline" -eq 0 ]]; then
    emerge "$@"
    return $?
  fi

  local now remaining warn_secs emerge_pid start_time
  now=$SECONDS
  if [[ "$deadline" -le "$now" ]]; then
    log "Time budget exhausted before starting emerge"
    return 42
  fi
  remaining=$(( deadline - now ))
  warn_secs=$(( remaining * 9 / 10 ))

  setsid emerge "$@" &
  emerge_pid=$!
  start_time=$SECONDS

  while kill -0 "$emerge_pid" 2>/dev/null; do
    sleep 30
    local elapsed=$(( SECONDS - start_time ))
    if [[ "$elapsed" -ge "$warn_secs" ]]; then
      log "Approaching time limit (${elapsed}s elapsed / ${remaining}s budget), stopping emerge"
      _TIMEOUT_FIRED_AT=$(date +%s)
      kill -TERM -- -"${emerge_pid}" 2>/dev/null || true
      local kill_wait=0
      while kill -0 "$emerge_pid" 2>/dev/null && [[ "$kill_wait" -lt 60 ]]; do
        sleep 5
        kill_wait=$(( kill_wait + 5 ))
      done
      if kill -0 "$emerge_pid" 2>/dev/null; then
        log "  Emerge did not exit after SIGTERM, sending SIGKILL to process group"
        kill -KILL -- -"${emerge_pid}" 2>/dev/null || true
      fi
      wait "$emerge_pid" 2>/dev/null || true
      show_ccache_stats
      log "Returning 42 so the workflow can continue with restored binpkgs and ccache"
      return 42
    fi
  done

  wait "$emerge_pid"
}

read_package_list() {
  local -n _packages=$1
  _packages=()
  if [[ -n "$SINGLE_PACKAGE" ]]; then
    _packages=("$SINGLE_PACKAGE")
    return 0
  fi

  local line
  while IFS= read -r line; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | xargs)"
    [[ -n "$line" ]] && _packages+=("$line")
  done < "$PACKAGE_LIST"
}

build_packages() {
  local packages=()
  read_package_list packages
  (( ${#packages[@]} > 0 )) || die "No packages to build"
  log "Packages to build: ${packages[*]}"

  local emerge_flags=(--buildpkgonly --usepkg --keep-going --verbose --update --newuse --deep)
  if [[ -n "$BINHOST_URL" ]]; then
    emerge_flags+=(--getbinpkg --ignore-built-slot-operator-deps=y)
  fi
  run_emerge_with_deadline "$DEADLINE" "${emerge_flags[@]}" "${packages[@]}"
}

sign_packages() {
  [[ "$SIGN" == true ]] || return 0
  [[ -n "$GPG_KEY" ]] || die "--gpg-key must be specified when --sign is used"
  [[ -d "$OUTPUT_DIR" ]] || return 0
  log "Signing packages in ${OUTPUT_DIR}"
  find "${OUTPUT_DIR}" -name '*.gpkg.tar' | while read -r pkg; do
    gpg --batch --yes --local-user "$GPG_KEY" --detach-sign --armor "$pkg"
    log "  Signed: $(basename "$pkg")"
  done
}

collect_packages() {
  if [[ "$OUTPUT_DIR" != "/var/cache/binpkgs" ]]; then
    log "Copying packages to ${OUTPUT_DIR}"
    mkdir -p "$OUTPUT_DIR"
    rsync -a --include='*/' --include='*.gpkg.tar' --exclude='*' \
      /var/cache/binpkgs/ "${OUTPUT_DIR}/"
  fi
}

prune_old_binpkgs() {
  local script="${SCRIPT_DIR}/prune-old-binpkgs.py"
  [[ -f "$script" ]] || die "Pruner not found at ${script}"
  local dirs=()
  [[ -d /var/cache/binpkgs ]] && dirs+=(/var/cache/binpkgs)
  [[ "$OUTPUT_DIR" != "/var/cache/binpkgs" && -d "$OUTPUT_DIR" ]] && dirs+=("$OUTPUT_DIR")
  (( ${#dirs[@]} > 0 )) || return 0
  log "Pruning older versions in: ${dirs[*]}"
  python3 "$script" "${dirs[@]}"
}

_on_exit() {
  local rc=$?
  trap - EXIT INT TERM
  if [[ "$rc" -ne 0 && "$rc" -ne 42 ]]; then
    log "Caught unexpected exit (rc=${rc}); running failure capture before exiting"
    collect_packages || log "  collect_packages failed during cleanup (rc=$?)"
    [[ "$SIGN" == true ]] && sign_packages || true
    report_failed_atoms || log "  report_failed_atoms failed during cleanup (rc=$?)"
  fi
  exit "$rc"
}
trap _on_exit EXIT
trap 'log "Caught SIGTERM"; exit 143' TERM
trap 'log "Caught SIGINT"; exit 130' INT

DEADLINE=0
if [[ -n "$MAX_BUILD_TIME" ]]; then
  DEADLINE=$(( SECONDS + MAX_BUILD_TIME * 60 ))
fi

apply_profile
setup_ccache
sync_tree
setup_binpkg_trust

BINPKGS_BEFORE="$(count_binpkgs)"
log "Binpkgs present before this attempt: ${BINPKGS_BEFORE}"

BUILD_RC=0
display_and_read_news
ensure_kernel_symlink
measure_cache_footprint "before"
show_ccache_stats
build_packages || BUILD_RC=$?

BINPKGS_AFTER="$(count_binpkgs)"

merge_pending_configs
collect_packages
prune_old_binpkgs
sign_packages
show_ccache_stats
report_failed_atoms
measure_cache_footprint "after"
emit_progress_summary "${BINPKGS_BEFORE}" "${BINPKGS_AFTER}"

if [[ "$BUILD_RC" -eq 42 ]]; then
  log "Build timed out; exiting 42 so the workflow can continue."
  exit 42
elif [[ "$BUILD_RC" -ne 0 ]]; then
  log "emerge returned ${BUILD_RC}; package failures are not treated as resume progress."
  exit "$BUILD_RC"
elif [[ "$FAILED_ATOM_COUNT" -gt 0 ]]; then
  log "${FAILED_ATOM_COUNT} package(s) failed even though emerge returned success."
  exit 1
fi

_remaining_cfg=()
while IFS= read -r -d '' _cfg; do
  _remaining_cfg+=("$_cfg")
done < <(find /etc -name '._cfg[0-9][0-9][0-9][0-9]_*' -print0)
if [[ ${#_remaining_cfg[@]} -gt 0 ]]; then
  echo "::warning title=Unmerged /etc config files::merge_pending_configs left ${#_remaining_cfg[@]} ._cfg* file(s) behind:"
  printf '  %s\n' "${_remaining_cfg[@]}"
fi
unset _remaining_cfg _cfg

log "Build complete."
