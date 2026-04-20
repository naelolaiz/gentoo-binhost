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
    # Hard check: the just-written make.conf must byte-equal the repo source.
    # Guards against a /etc/portage cache layer (or a rogue prior step) that
    # silently overwrites it after our cp.  No `|| true`: we WANT to fail RED.
    if ! cmp -s "${PROFILE_DIR}/make.conf" /etc/portage/make.conf; then
      die "make.conf byte-mismatch immediately after copy — something else is writing to /etc/portage/make.conf"
    fi
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
    nproc_val="$(nproc || getconf _NPROCESSORS_ONLN || echo 1)"
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
    find /var/cache/binpkgs -name '*.gpkg.tar' | wc -l
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

# ---------- failure surfacing ----------
# Detect every ebuild that failed during the just-finished emerge and SHOW it
# loudly: GitHub Actions ::error annotation, build log copied into the
# artifact directory, and a step-summary entry with the tail of the log.
#
# Without this, --keep-going makes emerge exit 0 even when individual atoms
# fail, leaving the user with no way to tell why qtwebengine (or whatever)
# blocks the chain — the actual `temp/build.log` is deleted with the runner
# at job end.  Surfacing failures is the explicit, repeatedly-requested
# user requirement: "Not hiding errors, but showing them and reporting logs
# appropriately to fix it."
#
# Failure marker convention used by Portage:
#   /var/tmp/portage/<cat>/<pkg>/.die_hooks    — touched UNCONDITIONALLY by
#       isolated-functions.sh::die() for any non-`depend` phase invoked via
#       ebuild.sh/misc-functions.sh.  This is the canonical "this ebuild
#       called die" marker.
#   /var/tmp/portage/<cat>/<pkg>/temp/environment — saved environment for the
#       failed phase; readable for `EBUILD_PHASE=...` and useful for repro.
#   /var/tmp/portage/<cat>/<pkg>/temp/build.log — full build output for that atom
#   /var/tmp/portage/<cat>/<pkg>/temp/die.env  — LEGACY fallback: Portage only
#       writes this when ${T}/environment does NOT exist (see die() in
#       isolated-functions.sh: `if [[ -f "${T}/environment" ]]; ... elif [[ -d
#       "${T}" ]]; then { set; export; } > "${T}/die.env"; fi`).  For a normal
#       compile/install-phase failure, environment exists and die.env is never
#       written, which is why the previous .die_hooks-less probe missed every
#       real failure (e.g. dev-lang/go-1.26.2 in run 24664855594) and reported
#       "No failed atoms detected" while the chain was definitively broken.
# Number of lines of build.log tailed into the GitHub step summary for each
# failed package.  80 is enough for a typical configure/cmake error; raising
# it would clutter the summary, lowering it would hide enough context.
FAILURE_LOG_TAIL_LINES=80
report_failed_atoms() {
  local portage_tmp="/var/tmp/portage"
  local failures_dir="${OUTPUT_DIR%/}/_failures"
  local list_file="${STATE_DIR%/}/failed-packages.txt"
  local prev_list_file="${STATE_DIR%/}/failed-packages.previous.txt"
  local repeated_file="${STATE_DIR%/}/failed-packages.repeated.txt"

  mkdir -p "$failures_dir" "$STATE_DIR"
  : > "$list_file"
  : > "$repeated_file"

  if [[ ! -d "$portage_tmp" ]]; then
    log "No /var/tmp/portage found; no per-atom failures to report"
    return 0
  fi

  # Iterate every .die_hooks under /var/tmp/portage/<cat>/<pkg>/.die_hooks.
  # This is the canonical marker (see header comment).  We also probe for
  # legacy die.env files at /var/tmp/portage/<cat>/<pkg>/temp/die.env so that
  # if Portage ever writes one (only possible when ${T}/environment is
  # absent) we still capture it.  Two passes because -mindepth/-maxdepth are
  # global to a find invocation, not per -o branch.
  # No 2>/dev/null on find: if the directory is unreadable for a real reason
  # (perm denied, IO error) we want to see it, not lose all failure context.
  local die_files=()
  while IFS= read -r -d '' f; do die_files+=("$f"); done < <(
    find "$portage_tmp" -mindepth 3 -maxdepth 3 -type f -name .die_hooks -print0
  )
  while IFS= read -r -d '' f; do die_files+=("$f"); done < <(
    find "$portage_tmp" -mindepth 4 -maxdepth 4 -type f -name die.env -print0
  )

  if [[ ${#die_files[@]} -eq 0 ]]; then
    log "No failed atoms detected (no .die_hooks or die.env files under ${portage_tmp})"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
      echo "failed_package_count=0" >> "$GITHUB_OUTPUT"
      echo "repeated_failures=false" >> "$GITHUB_OUTPUT"
    fi
    return 0
  fi

  log "Detected ${#die_files[@]} failed atom(s); collecting logs and emitting annotations"

  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo ""
      echo "### Failed packages (${#die_files[@]})"
      echo ""
      echo "Each entry below is a Portage ebuild that died during this attempt."
      echo "The full \`build.log\` and saved \`environment\` (or legacy \`die.env\`) are uploaded under \`_failures/\` in the build artifact."
      echo ""
    } >> "$GITHUB_STEP_SUMMARY"
  fi

  local f cat_pkg cat pkg phase build_log dest temp_dir env_src
  # Track which atoms we've already captured so a package with both
  # .die_hooks (depth 3) and die.env (depth 4) isn't reported twice.
  local -A seen_atoms=()
  for f in "${die_files[@]}"; do
    # Derive <cat>/<pkg> and the package's temp/ directory from the marker
    # file path.  Two layouts to handle:
    #   /var/tmp/portage/<cat>/<pkg>/.die_hooks       (canonical, depth 3)
    #   /var/tmp/portage/<cat>/<pkg>/temp/die.env     (legacy fallback, depth 4)
    cat_pkg="${f#"${portage_tmp}"/}"
    case "$f" in
      */.die_hooks)
        cat_pkg="${cat_pkg%/.die_hooks}"        # <cat>/<pkg>
        temp_dir="${portage_tmp}/${cat_pkg}/temp"
        ;;
      */temp/die.env)
        cat_pkg="${cat_pkg%/temp/die.env}"      # <cat>/<pkg>
        temp_dir="$(dirname "$f")"
        ;;
      *)
        log "  WARNING: unrecognised marker path '${f}', skipping"
        continue
        ;;
    esac
    if [[ -n "${seen_atoms[$cat_pkg]:-}" ]]; then
      continue
    fi
    seen_atoms["$cat_pkg"]=1
    cat="${cat_pkg%%/*}"
    pkg="${cat_pkg##*/}"

    # Extract the failed phase.  Prefer temp/environment (the file that
    # actually exists for ordinary failures); fall back to temp/die.env
    # (legacy).  No 2>/dev/null: a read error here is real signal.
    phase=""
    env_src=""
    if [[ -f "${temp_dir}/environment" ]]; then
      env_src="${temp_dir}/environment"
    elif [[ -f "${temp_dir}/die.env" ]]; then
      env_src="${temp_dir}/die.env"
    fi
    if [[ -n "$env_src" ]]; then
      # temp/environment is saved with `declare -p`, producing lines like
      #   declare -- EBUILD_PHASE="compile"
      # while die.env is produced by `{ set; export; }` which yields
      #   EBUILD_PHASE=compile
      # Accept both shapes.
      phase="$(grep -m1 -E '(^|[[:space:]])EBUILD_PHASE=' "$env_src" \
        | sed -E 's/.*EBUILD_PHASE=//; s/^"//; s/"$//' || true)"
    fi
    [[ -n "$phase" ]] || phase="unknown"

    echo "${cat}/${pkg}" >> "$list_file"

    build_log="${temp_dir}/build.log"
    dest="${failures_dir}/${cat}/${pkg}"
    mkdir -p "$dest"
    if [[ -f "$build_log" ]]; then
      cp "$build_log" "${dest}/build.log"
    fi
    # Save environment if it exists — useful for reproducing the failure.
    if [[ -f "${temp_dir}/environment" ]]; then
      cp "${temp_dir}/environment" "${dest}/environment"
    fi
    # Also save legacy die.env if Portage happened to write one.
    if [[ -f "${temp_dir}/die.env" ]]; then
      cp "${temp_dir}/die.env" "${dest}/die.env"
    fi

    # ::error annotation — appears at top of GitHub Actions UI, RED.
    echo "::error title=Package build failed::${cat}/${pkg} failed in phase '${phase}'. See _failures/${cat}/${pkg}/build.log in the build artifact."

    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
      {
        echo "<details><summary><strong>${cat}/${pkg}</strong> — failed in <code>${phase}</code></summary>"
        echo ""
        if [[ -f "${dest}/build.log" ]]; then
          echo "Last ${FAILURE_LOG_TAIL_LINES} lines of \`build.log\`:"
          echo ""
          echo '```'
          tail -n "${FAILURE_LOG_TAIL_LINES}" "${dest}/build.log"
          echo '```'
        else
          echo "_No \`build.log\` was preserved — only the saved \`environment\` is available._"
        fi
        echo ""
        echo "</details>"
        echo ""
      } >> "$GITHUB_STEP_SUMMARY"
    fi
    log "  Captured failure: ${cat}/${pkg} (phase: ${phase})"
  done

  # Compare against the previous attempt's failure list (saved in STATE_DIR
  # by the previous attempt) to detect atoms that fail repeatedly — those are
  # the ones a human needs to look at, and resuming further just burns CI.
  local repeated_count=0
  if [[ -f "$prev_list_file" ]]; then
    # comm -12 needs sorted input
    local cur_sorted prev_sorted
    cur_sorted="$(mktemp)"; prev_sorted="$(mktemp)"
    sort -u "$list_file" > "$cur_sorted"
    sort -u "$prev_list_file" > "$prev_sorted"
    comm -12 "$cur_sorted" "$prev_sorted" > "$repeated_file"
    rm -f "$cur_sorted" "$prev_sorted"
    repeated_count="$(wc -l < "$repeated_file" | tr -d ' ')"
  fi

  if [[ "$repeated_count" -gt 0 ]]; then
    log "WARNING: ${repeated_count} package(s) failed in this attempt AND the previous one:"
    while IFS= read -r atom; do log "    repeated: ${atom}"; done < "$repeated_file"
    echo "::error title=Repeated package failures::${repeated_count} package(s) failed in two consecutive attempts. Auto-resume should stop. Atoms: $(tr '\n' ' ' < "$repeated_file")"
  fi

  # Rotate the list so the next attempt's invocation can compare against ours.
  cp "$list_file" "$prev_list_file"

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      echo "failed_package_count=${#die_files[@]}"
      if [[ "$repeated_count" -gt 0 ]]; then
        echo "repeated_failures=true"
      else
        echo "repeated_failures=false"
      fi
    } >> "$GITHUB_OUTPUT"
  fi
}

# ---------- cache footprint diagnostics ----------
#
# The system-state cache (/var/db/pkg + /var/lib/portage + /var/cache/edb)
# plus the existing binpkgs and ccache caches together must stay under
# GitHub's 10 GiB per-repository cache cap.  Above that cap, actions/cache
# silently drops save attempts, which would break resume.
#
# We surface size as a WARNING here only — failing the build over a save
# we haven't yet attempted is overreach.  The authoritative coupled-cache
# check is the workflow-level XOR on `cache-matched-key` in build-packages.yml,
# which fires on the NEXT attempt if a save was actually dropped.

# Cache size at which we emit a warning to the step log; chosen to leave
# ~2 GiB headroom under GitHub's 10 GiB per-repository cap.
CACHE_TOTAL_WARN_BYTES=$(( 8 * 1024 * 1024 * 1024 ))

# Directories that are persisted across resume attempts via actions/cache.
# Keep this list aligned with the cache steps in build-packages.yml so the
# footprint measurement reflects what's actually being saved.
CACHED_DIRS=(
  /var/cache/binpkgs
  /var/cache/ccache
  /var/db/pkg
  /var/cache/edb
  /var/lib/portage
)

# Print a human-readable size for a directory; "0" if it doesn't exist.
_dir_size_bytes() {
  local d="$1"
  if [[ -d "$d" ]]; then
    du -sb "$d" | awk '{print $1+0}'
  else
    echo 0
  fi
}

measure_cache_footprint() {
  local phase="${1:-}"   # "before" | "after"
  log "Cache footprint (${phase}):"
  local total=0 d size human_total human_size
  for d in "${CACHED_DIRS[@]}"; do
    size="$(_dir_size_bytes "$d")"
    total=$(( total + size ))
    human_size="$(numfmt --to=iec --suffix=B "$size" || echo "${size}B")"
    log "  ${d}: ${human_size}"
    if [[ -n "${GITHUB_OUTPUT:-}" && "$phase" == "after" ]]; then
      # Sanitize path -> output key; only used for diagnostics.
      local k
      k="cache_size_$(echo "$d" | tr '/' '_' | tr -c 'A-Za-z0-9_' '_')"
      echo "${k}=${size}" >> "$GITHUB_OUTPUT"
    fi
  done
  human_total="$(numfmt --to=iec --suffix=B "$total" || echo "${total}B")"
  log "  TOTAL: ${human_total} (GHA per-repo cap: 10 GiB)"

  if [[ -n "${GITHUB_OUTPUT:-}" && "$phase" == "after" ]]; then
    echo "cache_total_bytes=${total}" >> "$GITHUB_OUTPUT"
  fi

  # Diagnostic-only: warn when the post-build footprint approaches GitHub's
  # 10 GiB per-repository cache cap.  We deliberately do NOT fail the build
  # here — a dropped save is recoverable (the next attempt's coupled-cache
  # invariant check in build-packages.yml is the authoritative gate; it
  # will fail RED if exactly one of the two caches restored).  Failing a
  # completed 5 h build over a save we haven't yet attempted would be
  # strictly worse than warning and letting the next attempt arbitrate.
  if [[ "$phase" == "after" && "$total" -gt "$CACHE_TOTAL_WARN_BYTES" ]]; then
    echo "::warning title=Cache footprint approaching GHA cap::Total cache size ${human_total} is within 2 GiB of GitHub's 10 GiB per-repository cap. If a save is silently dropped, the next attempt's coupled-cache check will fail RED."
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
  if command -v ccache >/dev/null; then
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
  if command -v ccache >/dev/null; then
    log "ccache statistics:"
    # Informational; tolerate non-zero exit but do not hide stderr.
    ccache --show-stats || log "  (ccache --show-stats failed; see stderr above)"
  fi
}

# ---------- build state ----------
# Portage's resume list lives in /var/cache/edb/mtimedb (key: "resume").
# emerge --resume reads it to continue where SIGTERM interrupted us.
MTIMEDB_PATH="/var/cache/edb/mtimedb"

restore_build_state() {
  [[ "$RESUME" == true ]] || return 0
  if [[ ! -d "$STATE_DIR" ]] || [[ -z "$(ls -A "$STATE_DIR")" ]]; then
    log "No saved build state found at ${STATE_DIR}, starting fresh"
    return 0
  fi
  log "Restoring build state from ${STATE_DIR}"

  # WORKDIRs:
  #   * new layout: STATE_DIR/portage/  (subdir, sits next to STATE_DIR/mtimedb)
  #   * legacy layout (pre-mtimedb support): STATE_DIR was a flat mirror of
  #     /var/tmp/portage with no subdirs.  Detect by absence of *both* the
  #     portage/ subdir and a mtimedb sibling.
  if [[ -d "${STATE_DIR}/portage" ]]; then
    mkdir -p /var/tmp/portage
    rsync -a --delete "${STATE_DIR}/portage/" /var/tmp/portage/
    log "  Restored /var/tmp/portage (WORKDIRs, new layout)"
  elif [[ ! -f "${STATE_DIR}/mtimedb" ]]; then
    mkdir -p /var/tmp/portage
    rsync -a --delete "${STATE_DIR}/" /var/tmp/portage/
    log "  Restored /var/tmp/portage (WORKDIRs, legacy flat layout)"
  fi

  # mtimedb (independent of WORKDIRs — restored whenever present):
  if [[ -f "${STATE_DIR}/mtimedb" ]]; then
    mkdir -p "$(dirname "$MTIMEDB_PATH")"
    cp "${STATE_DIR}/mtimedb" "$MTIMEDB_PATH"
    log "  Restored mtimedb (emerge --resume list)"
  fi
}

save_build_state() {
  log "Saving build state to ${STATE_DIR}"
  mkdir -p "${STATE_DIR}/portage"
  if [[ -d /var/tmp/portage ]] && [[ -n "$(ls -A /var/tmp/portage)" ]]; then
    rsync -a --delete /var/tmp/portage/ "${STATE_DIR}/portage/"
    log "  Saved /var/tmp/portage (WORKDIRs)"
  else
    log "  No intermediate build state found in /var/tmp/portage"
  fi
  if [[ -f "$MTIMEDB_PATH" ]]; then
    cp "$MTIMEDB_PATH" "${STATE_DIR}/mtimedb"
    log "  Saved mtimedb (emerge --resume list)"
  fi
}

# Returns 0 if mtimedb has a non-empty "resume" list, 1 if there is no list
# (or the file doesn't exist).  Any *other* failure (unreadable file,
# malformed JSON, etc.) is fatal — we deliberately do NOT swallow it: a
# silent "no resume list" misdiagnosis would throw away an in-flight
# build's progress without anyone noticing.  mtimedb has been plain JSON
# since Portage 2.1.x, so a parse failure here is a real problem worth
# stopping the job for.
has_resume_list() {
  [[ -f "$MTIMEDB_PATH" ]] || return 1
  local rc=0
  python3 - "$MTIMEDB_PATH" >/dev/null <<'PYEOF' || rc=$?
import json, sys, traceback
try:
    with open(sys.argv[1]) as f:
        db = json.load(f)
except Exception:
    # Print the full traceback to stderr so the CI log shows exactly what
    # went wrong, then exit with a distinct code so the bash caller can
    # tell "parse failure" apart from "no resume list".
    traceback.print_exc()
    sys.exit(2)
resume = db.get("resume") or db.get("resume_backup") or {}
sys.exit(0 if resume.get("mergelist") else 1)
PYEOF
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *) die "Failed to parse ${MTIMEDB_PATH} (python exit ${rc}); refusing to silently skip --resume" ;;
  esac
}

# ---------- vdb / on-disk consistency ----------
# Problem: CI restores /var/db/pkg (the VDB — Portage's "what is installed"
# database) from a system-state cache, but does NOT restore the actual
# installed files under /usr, /lib, etc. — those come from the freshly-
# extracted stage3 image. For any package that is NOT part of stage3 but
# was installed in a previous chain, the VDB claims it's installed while
# its files are absent from disk. Portage then either:
#   - excludes it from the emerge plan (breaking dependents at configure
#     time when their pkg-config / headers / libraries are missing — e.g.
#     mesa failing with "Dependency 'libglvnd' not found"), or
#   - schedules an [ebuild R] rebuild that can't bootstrap because the
#     self-hosted prior install isn't really there (e.g. dev-lang/go's
#     make.bash refusing to run without /usr/lib/go/bin/go).
#
# A previous fix maintained two hand-written allow-lists of (package,
# probe-path) tuples and removed VDB entries when a hardcoded probe was
# missing. That was a workaround that only handled packages we'd already
# been bitten by, and demanded a code change every time a new package hit
# the same pattern.
#
# Fix (general): every VDB entry already records the exact files it
# installed in /var/db/pkg/<cat>/<pf>/CONTENTS. We walk all VDB entries,
# pick the first `obj` (regular-file) line from each CONTENTS as a probe,
# and if the file is absent on disk we drop the stale VDB entry. emerge
# then re-resolves dependencies from scratch — pulling a binpkg from the
# binhost or rebuilding from source — for ANY package that's missing,
# without us having to enumerate them up front.
#
# Notes:
#   * We sample the first obj entry rather than scanning every file in
#     CONTENTS: in our cache+stage3 scenario the state is binary (all
#     files present, or all absent), so one probe is sufficient and keeps
#     the scan cheap on a several-thousand-entry VDB.
#   * Packages whose CONTENTS has no obj entries (e.g. virtuals,
#     metapackages) are left alone — there's nothing on disk to probe and
#     dropping them would force needless re-resolution.
verify_installed_deps() {
  local vdb_root="/var/db/pkg"
  [[ -d "$vdb_root" ]] || return 0

  local cat_dir pkg_dir contents probe pkg_atom removed=0
  shopt -s nullglob
  for cat_dir in "$vdb_root"/*/; do
    for pkg_dir in "$cat_dir"*/; do
      contents="${pkg_dir}CONTENTS"
      [[ -f "$contents" ]] || continue

      # CONTENTS obj-line format (portage):
      #   obj <absolute-path> <md5> <mtime>
      # Path may contain spaces, so we strip the trailing two
      # whitespace-delimited tokens (md5, mtime) rather than splitting on
      # whitespace blindly. Take only the first obj entry as a probe.
      probe="$(awk '$1=="obj" {
                      sub(/^obj /, "");
                      sub(/ [^ ]+ [^ ]+$/, "");
                      print;
                      exit
                    }' "$contents")"
      [[ -n "$probe" ]] || continue       # no obj entries — skip
      [[ -e "$probe" ]] && continue       # files present — VDB matches disk

      pkg_atom="${pkg_dir#"${vdb_root}"/}"
      pkg_atom="${pkg_atom%/}"
      log "Stale VDB entry: ${pkg_atom} — probe file ${probe} missing on disk"
      log "  Removing so emerge re-resolves and re-installs (or pulls a binpkg)."
      rm -rf -- "${pkg_dir%/}"
      removed=$(( removed + 1 ))
    done
  done
  shopt -u nullglob

  log "verify_installed_deps: removed ${removed} stale VDB entries"
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
     && gpg --homedir /etc/portage/gnupg --list-keys "$gentoo_key" >/dev/null; then
    log "Gentoo binpkg signing key ${gentoo_key} already trusted, skipping trust setup"
    return 0
  fi

  if command -v getuto >/dev/null; then
    log "Running getuto to import Gentoo binpkg signing keys"
    getuto
    log "  Portage binary-package trust established via getuto"
  else
    log "Warning: getuto not found; setting up Portage GnuPG keyring manually"
    mkdir -p /etc/portage/gnupg
    chmod 0700 /etc/portage/gnupg
    # Initialise an empty keyring so subsequent --recv-keys has somewhere to
    # write.  Suppress only stdout (the empty key list) — keep stderr visible
    # so a real GPG failure (corrupt keyring, bad perms) is loud.
    gpg --homedir /etc/portage/gnupg --list-keys >/dev/null || true
    # Try to receive the Gentoo release key from the official keyserver
    gpg --homedir /etc/portage/gnupg \
        --keyserver hkps://keys.gentoo.org \
        --recv-keys 534E4209AB49EEE1C19D96162C44695DB9F6043D \
      && log "  Imported Gentoo release key from keyserver" \
      || log "  Warning: could not fetch Gentoo release key from keyserver; binpkg signature verification will fail"
  fi

  # Portage verifies binary package GPG signatures as the 'portage' user,
  # not root.  The keyring must be owned by that user or gpg refuses to read
  # it ("unsafe ownership on homedir", "Permission denied").
  if [[ -d /etc/portage/gnupg ]]; then
    chown -R portage:portage /etc/portage/gnupg
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

# ---------- kernel symlink ----------
# Point /usr/src/linux at an installed kernel so any *-modules ebuild going
# through linux-mod-r1.eclass (e.g. app-emulation/virtualbox-modules) finds
# kernel sources during pkg_setup.  sys-kernel/gentoo-kernel-bin's own
# pkg_postinst already calls `eselect kernel set` via the dist-kernel
# eclass; this step is belt-and-suspenders for chained resume attempts
# where the kernel was installed in a previous attempt.
#
# No error suppression here: eselect is part of the stage3 base system,
# `eselect kernel list` exits 0 even when nothing is installed, and we
# want any unexpected stderr to land in the CI log.  When no kernel is
# installed yet, `eselect kernel list` prints only its header (no `[N]`
# entries) and we skip the `set` call.
ensure_kernel_symlink() {
  log "Checking for installed kernel sources"
  local kernel_list
  kernel_list=$(eselect --colour=no kernel list)
  printf '%s\n' "$kernel_list"
  if printf '%s\n' "$kernel_list" | grep -qE '^\s*\['; then
    log "Setting /usr/src/linux symlink"
    eselect kernel set 1
    log "  /usr/src/linux -> $(readlink /usr/src/linux)"
  else
    log "No kernel sources installed yet; skipping eselect kernel set"
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

  # Compute a single deadline shared between the optional `emerge --resume`
  # phase and the main emerge invocation, so a long-running resume can't
  # starve the main build (or vice-versa).  When --max-build-time is unset,
  # DEADLINE=0 disables the timer entirely.
  local deadline=0
  if [[ -n "$MAX_BUILD_TIME" ]]; then
    deadline=$(( SECONDS + MAX_BUILD_TIME * 60 ))
  fi

  # If we have a saved emerge resume list (from a previous SIGTERM), continue
  # it first.  --skipfirst drops the package that was actively building when
  # we were killed: its WORKDIR is almost certainly inconsistent after the
  # SIGKILL fallback, and trying to reuse it tends to fail confusingly.
  # If --resume has nothing to do (empty/stale list) we just fall through.
  #
  # emerge(1) only honours a small subset of options together with --resume
  # (see "USING RESUME" — most action-flags like --buildpkg/--usepkg are
  # baked into the saved mergelist already).  Pass only flags that affect
  # *how* the resume runs, not *what* it builds.
  if [[ "$RESUME" == true ]] && has_resume_list; then
    log "Found saved emerge resume list; continuing it before starting fresh emerge"
    local resume_flags=(--keep-going --verbose)
    # Capture the real exit code: `if ! cmd; then rc=$?` is a known bash
    # footgun — inside the then-block, $? is the status of the negated
    # condition (always 0), not of cmd.  Use `cmd || rc=$?` instead so the
    # 42 ("timed out, state saved") signal actually propagates.
    local rc=0
    run_emerge_with_deadline "$deadline" --resume --skipfirst "${resume_flags[@]}" || rc=$?
    if [[ $rc -eq 42 ]]; then
      return 42
    elif [[ $rc -ne 0 ]]; then
      log "  emerge --resume failed (rc=${rc}); falling through to full emerge to retry"
    fi
  fi

  run_emerge_with_deadline "$deadline" "${emerge_flags[@]}" "${packages[@]}"
}

# run_emerge_with_deadline <deadline_secs> <emerge args...>
#   deadline_secs == 0  -> no time limit (run to completion)
#   deadline_secs > 0   -> SIGTERM emerge at 90% of remaining time, save
#                          state, return 42; SIGKILL after a 60s grace.
# Returns emerge's own exit code, or 42 on a timed-out save-and-resume.
run_emerge_with_deadline() {
  local deadline="$1"; shift
  if [[ "$deadline" -eq 0 ]]; then
    emerge "$@"
    return $?
  fi

  local now=$SECONDS
  if [[ $deadline -le $now ]]; then
    log "Time budget exhausted before starting emerge; saving state and returning 42"
    save_build_state
    return 42
  fi

  local remaining=$(( deadline - now ))
  # Stop at 90% of the *remaining* budget so we always leave headroom for
  # save_build_state, ccache flush, artifact upload, etc.
  local warn_secs=$(( remaining * 9 / 10 ))

  setsid emerge "$@" &
  local emerge_pid=$!
  local start_time=$SECONDS

  # NOTE on `kill -0` / `kill -TERM` / `wait` below: we deliberately do NOT
  # suppress their stderr.  At most a single "No such process" / "not a
  # child of this shell" line can leak when emerge exits between two
  # successive probes — that's a *signal*, not noise: it means the timeout
  # path raced with a normal exit.  Suppressing it has previously hidden
  # real bugs (process group not propagated, wrong PID, kernel reaping
  # surprises).  Keep them visible.
  while kill -0 "$emerge_pid"; do
    sleep 30
    local elapsed=$(( SECONDS - start_time ))
    if [[ $elapsed -ge $warn_secs ]]; then
      log "Approaching time limit (${elapsed}s elapsed / ${remaining}s budget for this phase), stopping emerge"
      kill -TERM -- -${emerge_pid} || true
      local kill_wait=0
      while kill -0 "$emerge_pid" && [[ $kill_wait -lt 60 ]]; do
        sleep 5
        kill_wait=$(( kill_wait + 5 ))
      done
      if kill -0 "$emerge_pid"; then
        log "  Emerge did not exit after SIGTERM, sending SIGKILL to process group"
        kill -KILL -- -${emerge_pid} || true
      fi
      wait "$emerge_pid" || true
      save_build_state
      show_ccache_stats
      log "Build state saved; returning 42 (timed out, state saved)"
      return 42
    fi
  done

  wait "$emerge_pid"
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

# ---------- prune older versions ----------
# Keep only the newest version per (category, PN) in the binpkg directories.
# This is what stops the published Pages site from blowing past GitHub's 1 GB
# soft limit after a few rebuild rounds (every bumped ebuild leaves behind a
# stale gpkg that nothing on the binhost will ever serve again).
prune_old_binpkgs() {
  local script="${SCRIPT_DIR}/prune-old-binpkgs.py"
  # The pruner ships next to this script in the same repo.  If it's missing,
  # that's a packaging bug, not something to silently work around — without
  # it the Pages site will eventually exceed 1 GiB and become unreachable.
  [[ -f "$script" ]] || die "Pruner not found at ${script}"
  local dirs=()
  [[ -d /var/cache/binpkgs ]] && dirs+=(/var/cache/binpkgs)
  if [[ "$OUTPUT_DIR" != "/var/cache/binpkgs" && -d "$OUTPUT_DIR" ]]; then
    dirs+=("$OUTPUT_DIR")
  fi
  if (( ${#dirs[@]} == 0 )); then
    return 0
  fi
  log "Pruning older versions in: ${dirs[*]}"
  python3 "$script" "${dirs[@]}"
}

# ---------- main ----------
# Make sure that, if the runner cancels us (job-timeout / user-cancel /
# external SIGTERM), we still:
#   1. Capture any in-flight portage failures (.die_hooks markers) so the
#      next attempt can compare against them and so the artifact actually
#      contains the failing build.log instead of an empty _failures/
#      directory.  This was the missing piece in run 24636521882, where
#      dev-lang/go failed in 1.8 s and then the cancel path threw the
#      build.log away.
#   2. Move whatever finished gpkgs already exist into OUTPUT_DIR, so the
#      "Save binpkgs" cache step preserves real progress instead of an
#      empty tree.
# Idempotent helpers: collect_packages / sign_packages / report_failed_atoms
# are all safe to re-run from the EXIT trap after the normal happy path
# already invoked them — they short-circuit on empty inputs.
_on_exit() {
  local rc=$?
  # Disable the trap re-entry: if any of the cleanup helpers themselves
  # die, we still want a single exit, not a recursion loop.
  trap - EXIT INT TERM
  if [[ $rc -ne 0 && $rc -ne 42 ]]; then
    log "Caught unexpected exit (rc=${rc}); running failure capture before exiting"
    # Keep going past individual helper failures — partial capture is
    # always more useful than no capture.
    collect_packages       || log "  collect_packages failed during cleanup (rc=$?)"
    [[ "$SIGN" == true ]] && { sign_packages || log "  sign_packages failed during cleanup (rc=$?)"; }
    report_failed_atoms    || log "  report_failed_atoms failed during cleanup (rc=$?)"
  fi
  exit "$rc"
}
trap _on_exit EXIT
# SIGTERM/SIGINT: re-raise via 'exit' so EXIT trap runs with the conventional
# 128+signo exit code.
trap 'log "Caught SIGTERM"; exit 143' TERM
trap 'log "Caught SIGINT";  exit 130' INT

apply_profile
setup_ccache
sync_tree
setup_binpkg_trust
restore_build_state
verify_installed_deps
ensure_kernel_symlink
measure_cache_footprint "before"
show_ccache_stats

# Collect and sign whatever binpkgs were produced, even on a timed-out build,
# so partial results are published and later phases don't have to rebuild them.
BINPKGS_BEFORE="$(count_binpkgs)"
log "Binpkgs present before this attempt: ${BINPKGS_BEFORE}"
build_packages || BUILD_RC=$?
BUILD_RC=${BUILD_RC:-0}
BINPKGS_AFTER="$(count_binpkgs)"

collect_packages
prune_old_binpkgs
sign_packages
show_ccache_stats
report_failed_atoms
measure_cache_footprint "after"
emit_progress_summary "${BINPKGS_BEFORE}" "${BINPKGS_AFTER}"

if [[ $BUILD_RC -eq 42 ]]; then
  log "Build timed out (state saved); exiting 42 so the workflow can resume in the next phase."
  exit 42
elif [[ $BUILD_RC -ne 0 ]]; then
  die "emerge failed with exit code ${BUILD_RC}"
fi

log "Build complete."
