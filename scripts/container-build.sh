#!/usr/bin/env bash
# container-build.sh — build package tiers inside a fresh Gentoo stage3
# container.
#
# The container is first configured like any machine that installs from the
# binhost (scripts/setup-consumer.sh).  Everything the binhosts already offer
# is then installed as a binary and only what is missing or newer in the tree
# gets compiled.  Finished packages land in PKGDIR (/var/cache/binpkgs), where
# the host-side publisher (scripts/binhost.py) picks them up.  No state is
# carried in this container: what has been published is the progress.
#
# Usage:
#   container-build.sh --binhost-uri <url> --trust-key <public-key.asc>
#                      --sign-key <secret-key.asc> [options]
#
# Options:
#   --tiers "<names>"        tiers to build (packages/tiers/NN-<name>.txt);
#                            default: all, in file name order
#   --tiers-dir <dir>        read the tier files from here instead (tests)
#   --min-window <seconds>   least time before the deadline that a build may
#                            still be started with (default 600; tests)
#   --sign-passphrase <file> passphrase of the signing key, if it has one
#   --deadline <epoch>       stop building at this time (exit 42)
#   --tree-date <YYYYMMDD>   use this tree snapshot instead of the newest
#   --out <dir>              reports for the host (default /out)
#   --plan-only              resolve and report what would be built, then stop
#
# Exit status: 0 every requested tier was processed, 42 stopped at the
# deadline, anything else means the build environment itself is broken.
# A package that fails to build is not a failure of the run: it is reported
# and everything that does not depend on it is still built.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=config/binhost.conf
. "${REPO_ROOT}/config/binhost.conf"

log() { echo "[build] $*"; }
die() { echo "::error::$*" >&2; exit 1; }

TIERS=""
TIERS_DIR="${REPO_ROOT}/packages/tiers"
# Do not start an emerge that cannot get anywhere before the deadline.
MIN_WINDOW=600
BINHOST_URI=""
TRUST_KEY=""
SIGN_KEY=""
SIGN_PASSPHRASE=""
DEADLINE=0
TREE_DATE=""
OUT="/out"
PLAN_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tiers)           TIERS="$2";           shift 2 ;;
    --tiers-dir)       TIERS_DIR="$2";       shift 2 ;;
    --min-window)      MIN_WINDOW="$2";      shift 2 ;;
    --binhost-uri)     BINHOST_URI="$2";     shift 2 ;;
    --trust-key)       TRUST_KEY="$2";       shift 2 ;;
    --sign-key)        SIGN_KEY="$2";        shift 2 ;;
    --sign-passphrase) SIGN_PASSPHRASE="$2"; shift 2 ;;
    --deadline)        DEADLINE="$2";        shift 2 ;;
    --tree-date)       TREE_DATE="$2";       shift 2 ;;
    --out)             OUT="$2";             shift 2 ;;
    --plan-only)       PLAN_ONLY=true;       shift ;;
    --help|-h)         sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -n "$BINHOST_URI" ]] || die "--binhost-uri is required"
[[ -n "$TRUST_KEY" ]] || die "--trust-key is required"
[[ "$DEADLINE" =~ ^[0-9]+$ ]] || die "--deadline must be an epoch, got: ${DEADLINE}"
[[ "$MIN_WINDOW" =~ ^[0-9]+$ ]] || die "--min-window must be a number of seconds, got: ${MIN_WINDOW}"
if [[ "$PLAN_ONLY" != true ]]; then
  [[ -f "$SIGN_KEY" ]] || die "--sign-key file not found: clients verify signatures, so unsigned packages are useless"
fi

PORTAGE_TMP="/var/tmp/portage"
PKGDIR="/var/cache/binpkgs"
CCACHE_DIR="/var/cache/ccache"
export CCACHE_DIR
SIGN_HOME="/root/.gnupg-binhost"
# Longest a single dependency calculation may take.
PLAN_TIMEOUT=600
# Seconds of failed dependency calculations after which the roots of a tier
# that still do not resolve are given up for this run.
RESOLVE_BUDGET=1800
RESOLVE_SPENT=0
FAILURE_LOG_TAIL_LINES=80

STATUS="complete"
TIMEOUT_FIRED_AT=0
FAILED_COUNT=0
# Every failure met, counting a package again when it fails a second time.
FAILURES_SEEN=0
# category/package of what failed to build in this run (for lack of memory
# or disk: failed twice).  They are kept out of every later dependency
# calculation: trying again within the same run would fail the same way,
# after the same hours.
FAILED_CPS=()
EXCLUDE_OPTS=()
UNRESOLVED_COUNT=0
PLAN_SEQ=0
PLAN_ATOMS=()
TIER=""
REPORTER_PID=""

mkdir -p "$OUT" "$OUT/failures" "$OUT/plans"
: > "$OUT/failures.tsv"
: > "$OUT/unresolved.tsv"
: > "$OUT/planned.txt"

# ── Reports for the host ────────────────────────────────────────────────

# Every package that is really installed here, with its build time.  The
# publisher only offers a package to others once it shows up in this list:
# Portage writes the binary before merging it, and a package whose merge
# failed must not be handed out.
write_merged() {
  # The background reporter and the main script both write this file.
  local tmp="${OUT}/.merged.${BASHPID}.tmp" file dir
  : > "$tmp"
  for file in /var/db/pkg/*/*/BUILD_TIME; do
    [[ -f "$file" ]] || continue
    dir="${file%/BUILD_TIME}"
    echo "${dir#/var/db/pkg/} $(tr -d '[:space:]' < "$file")" >> "$tmp"
  done
  mv "$tmp" "${OUT}/merged.txt"
}

# A failed build keeps its work directory until emerge is done with its whole
# list, which can be hours and tens of GB later; meanwhile the packages after
# it fail for lack of space.  Reporting it only needs the log and the marker.
free_failed_builds() {
  [[ -d "$PORTAGE_TMP" ]] || return 0
  local marker dir
  while IFS= read -r -d '' marker; do
    dir="${marker%/.die_hooks}"
    rm -rf "${dir}/work" "${dir}/image" "${dir}/homedir"
  done < <(find "$PORTAGE_TMP" -mindepth 3 -maxdepth 3 -type f -name .die_hooks -print0 2>/dev/null)
}

start_reporter() {
  (
    tick=0
    while sleep 60; do
      write_merged || true
      free_failed_builds || true
      tick=$(( tick + 1 ))
      if (( tick % 10 == 0 )); then
        echo "[build] status: $(df -h --output=avail / | tail -1 | tr -d ' ') free on /," \
             "$(awk '/MemAvailable/ { printf "%d MiB", $2 / 1024 }' /proc/meminfo) memory available," \
             "$(find "$PKGDIR" -name '*.gpkg.tar' 2>/dev/null | wc -l) package(s) built"
      fi
    done
  ) &
  REPORTER_PID=$!
}

write_result() {
  local built=0 ccache_stored=0 ccache_hits=0 interrupted=""
  [[ -d "$PKGDIR" ]] && built="$(find "$PKGDIR" -name '*.gpkg.tar' | wc -l)"
  if command -v ccache >/dev/null; then
    ccache_stored="$(ccache --print-stats | awk '$1 == "cache_miss" { print $2 }')"
    ccache_hits="$(ccache --print-stats \
      | awk '$1 == "direct_cache_hit" || $1 == "preprocessed_cache_hit" { n += $2 } END { print n + 0 }')"
  fi
  if [[ "$STATUS" == deadline && -d "$PORTAGE_TMP" ]]; then
    # Whatever still has a build directory was cut off mid-build.
    interrupted="$(find "$PORTAGE_TMP" -mindepth 2 -maxdepth 2 -type d \
      ! -path '*/._unmerge_/*' -printf '%P\n' 2>/dev/null | sort | tr '\n' ' ')"
  fi
  {
    echo "status=${STATUS}"
    echo "built=${built}"
    echo "failed=${FAILED_COUNT}"
    echo "unresolved=${UNRESOLVED_COUNT}"
    echo "planned=$(sort -u "$OUT/planned.txt" | grep -c . || true)"
    echo "ccache_stored=${ccache_stored:-0}"
    echo "ccache_hits=${ccache_hits:-0}"
    echo "interrupted=${interrupted% }"
    echo "tree_date=$(cat "$OUT/tree-date" 2>/dev/null || true)"
    echo "portage=$(python3 -c 'import portage; print(portage.VERSION)' 2>/dev/null || true)"
    echo "gcc=$(portageq best_version / sys-devel/gcc 2>/dev/null || true)"
    echo "glibc=$(portageq best_version / sys-libs/glibc 2>/dev/null || true)"
  } > "$OUT/result.env"
}

on_exit() {
  local rc=$?
  trap - EXIT TERM
  if [[ -n "$REPORTER_PID" ]]; then
    kill "$REPORTER_PID" 2>/dev/null || true
    wait "$REPORTER_PID" 2>/dev/null || true
  fi
  if (( rc != 0 && rc != 42 )); then
    STATUS="error"
  fi
  write_merged || true
  write_result || true
  exit "$rc"
}
trap on_exit EXIT
# The host stops the container if it overruns its deadline by a wide margin.
# Leave like a run that reached the deadline, so that it is continued.
trap 'STATUS="deadline"; exit 42' TERM

deadline_near() {
  (( DEADLINE > 0 )) && [[ "$PLAN_ONLY" != true ]] \
    && (( $(date +%s) + MIN_WINDOW >= DEADLINE ))
}

# ── Builder-only configuration ──────────────────────────────────────────

write_builder_conf() {
  local nproc_val
  nproc_val="$(nproc)"
  cat >> /etc/portage/make.conf <<EOF

# ── Added by scripts/container-build.sh: settings of the builder only ──
# buildpkg: every package compiled here becomes a binary package.
# -news: nobody reads news in a throwaway container.
FEATURES="\${FEATURES} buildpkg ccache -news"
BINPKG_FORMAT="gpkg"
BINPKG_COMPRESS="zstd"
# -l keeps two packages building side by side from oversubscribing the CPUs.
MAKEOPTS="-j${nproc_val} -l${nproc_val}"
# --with-bdeps=y: machines that set it also compare build-time dependencies
# when deciding whether a binary still matches, so the builder must too.
EMERGE_DEFAULT_OPTS="--load-average=${nproc_val} --with-bdeps=y --quiet-build=y --color=n"
CCACHE_DIR="${CCACHE_DIR}"
# The container has no local /etc changes to protect; without this, updated
# config files would pile up as ._cfg* and silently stay unapplied.
CONFIG_PROTECT="-*"
EOF
}

# The builder keeps the toolchain of its stage3 (stable keywords).  Machines
# that install from the binhost run the same or a newer glibc and libstdc++,
# and binaries built against older ones run there; the reverse breaks at
# run time without Portage noticing.  It also keeps the compiler identical
# between runs, which the compiler cache depends on.
pin_toolchain() {
  local atom best mask="/etc/portage/package.mask/zz-builder-toolchain"
  : > "$mask"
  for atom in sys-libs/glibc sys-devel/gcc sys-devel/binutils; do
    best="$(portageq best_version / "$atom")"
    [[ -n "$best" ]] || die "${atom} is not installed in this stage3"
    echo ">${best}" >> "$mask"
  done
  log "Toolchain held at: $(tr '\n' ' ' < "$mask")"
}

setup_signing() {
  install -d -m 0700 "$SIGN_HOME"
  local fpr sign_extra=()
  if [[ -n "$SIGN_PASSPHRASE" ]]; then
    install -m 0600 "$SIGN_PASSPHRASE" "${SIGN_HOME}/passphrase"
    sign_extra=(--pinentry-mode loopback --passphrase-file "${SIGN_HOME}/passphrase")
  fi
  gpg --homedir "$SIGN_HOME" --batch --quiet "${sign_extra[@]}" --import "$SIGN_KEY"
  fpr="$(gpg --homedir "$SIGN_HOME" --batch --with-colons --list-secret-keys \
    | awk -F: '$1 == "fpr" { print $10; exit }')"
  [[ -n "$fpr" ]] || die "The signing key file contains no secret key"

  {
    echo "FEATURES=\"\${FEATURES} binpkg-signing\""
    echo "BINPKG_GPG_SIGNING_GPG_HOME=\"${SIGN_HOME}\""
    echo "BINPKG_GPG_SIGNING_KEY=\"0x${fpr}\""
  } >> /etc/portage/make.conf
  if (( ${#sign_extra[@]} > 0 )); then
    # Portage's default command plus the two options gpg needs to read the
    # passphrase without a terminal.
    echo "BINPKG_GPG_SIGNING_BASE_COMMAND=\"/usr/bin/flock /run/lock/portage-binpkg-gpg.lock /usr/bin/gpg --sign --armor ${sign_extra[*]} [PORTAGE_CONFIG]\"" \
      >> /etc/portage/make.conf
  fi
  # The default signing command locks a file under /run/lock.
  mkdir -p /run/lock

  # Sign something and verify it the way Portage will: a wrong passphrase or
  # a public key in keys/ that does not belong to the secret key must stop
  # the run here, not after hours of building packages nobody can install.
  local probe status
  probe="$(mktemp -d)"
  echo "binhost signing self-test" > "${probe}/data"
  gpg --homedir "$SIGN_HOME" --batch --no-tty --local-user "0x${fpr}" "${sign_extra[@]}" \
      --sign --armor --output "${probe}/data.asc" "${probe}/data" \
    || die "Cannot sign with the configured key (wrong or missing passphrase?)"
  status="$(gpg --homedir /etc/portage/gnupg --batch --no-tty --status-fd 1 \
              --verify "${probe}/data.asc" 2>/dev/null || true)"
  rm -rf "$probe"
  if ! grep -q 'GOODSIG' <<< "$status" || ! grep -qE 'TRUST_(FULLY|ULTIMATE)' <<< "$status"; then
    die "Packages signed with key ${fpr} would be rejected by clients: it is not the key published in ${TRUST_KEY}, or that key has expired"
  fi
  log "Signing with key ${fpr}"
}

install_ccache() {
  if ! command -v ccache >/dev/null; then
    log "Installing ccache"
    # A stable binary from a binhost is enough.  If it does not run (a
    # binary linked against a library version this image does not have),
    # build it instead.
    if ! ACCEPT_KEYWORDS="amd64" FEATURES="-ccache -buildpkg" emerge --oneshot --quiet \
           --usepkgonly --getbinpkg --binpkg-respect-use=n --with-bdeps=n dev-util/ccache \
       || ! ccache --version >/dev/null 2>&1; then
      echo "::warning::No usable ccache binary; building it"
      FEATURES="-ccache" emerge --oneshot --quiet --usepkg=n dev-util/ccache
      ccache --version >/dev/null
    fi
  fi
  mkdir -p "$CCACHE_DIR"
  ccache --max-size="$CCACHE_MAX_SIZE" >/dev/null
  # content: the cache must survive the compiler being reinstalled from the
  # same binary package in the next container (its mtime changes).
  ccache --set-config=compiler_check=content
  ccache --set-config=compression=true
  ccache --set-config=compression_level=1
  ccache --set-config=hash_dir=false
  ccache --set-config=sloppiness=pch_defines,time_macros,include_file_mtime,include_file_ctime
  ccache --zero-stats >/dev/null
  # Compiles run as the portage user.
  chown -R portage:portage "$CCACHE_DIR"
  chmod 2775 "$CCACHE_DIR"
  log "ccache: $(ccache --version | head -1), limit ${CCACHE_MAX_SIZE}," \
      "$(du -sh "$CCACHE_DIR" | cut -f1) restored"
}

# Packages in our index whose ebuild left the tree: input for pruning.
list_gone() {
  local index="${OUT}/remote-Packages"
  if python3 - "$BINHOST_URI" "$index" <<'PY'
import sys
import urllib.request
with urllib.request.urlopen(sys.argv[1].rstrip("/") + "/Packages", timeout=60) as response:
    data = response.read()
with open(sys.argv[2], "wb") as handle:
    handle.write(data)
PY
  then
    if python3 "${SCRIPT_DIR}/portage-index.py" gone "$index" > "${OUT}/gone.txt.tmp"; then
      mv "${OUT}/gone.txt.tmp" "${OUT}/gone.txt"
    else
      echo "::warning::Could not compare the index with the tree; nothing will be pruned this run"
    fi
  else
    die "Cannot read our own index at ${BINHOST_URI}/Packages; refusing to build without knowing what is already published"
  fi
}

bootstrap() {
  bash "${SCRIPT_DIR}/setup-consumer.sh" --binhost-uri "$BINHOST_URI" --trust-key "$TRUST_KEY" \
    ${TREE_DATE:+--tree-date "$TREE_DATE"} --date-file "${OUT}/tree-date"
  write_builder_conf
  pin_toolchain
  list_gone
  if [[ "$PLAN_ONLY" != true ]]; then
    setup_signing
    install_ccache
  fi
  emerge --info > "${OUT}/emerge-info.txt" 2>&1 || true
  touch "${OUT}/bootstrap.done"
}

# ── Resolving ───────────────────────────────────────────────────────────

BASE_OPTS=(--oneshot --usepkg --getbinpkg --backtrack=100 --verbose-conflicts)
# What `emerge -uDN` does on a real machine: bring the whole dependency tree
# of the roots up to date and in line with the configured USE flags.
DEEP_OPTS=(--update --deep --newuse)
RESOLVE_OPTS=("${BASE_OPTS[@]}" "${DEEP_OPTS[@]}")

# plan <roots...>: resolve without installing anything.  On success
# PLAN_ATOMS holds the exact versions that have to be compiled and
# PLAN_MERGES the number of packages that would be installed in total.
plan() {
  PLAN_SEQ=$(( PLAN_SEQ + 1 ))
  PLAN_LOG="${OUT}/plans/${TIER}-${PLAN_SEQ}.log"
  PLAN_ATOMS=()
  PLAN_MERGES=0
  local rc=0
  echo "# emerge --pretend ${RESOLVE_OPTS[*]} ${EXCLUDE_OPTS[*]} $*" > "$PLAN_LOG"
  # Portage normally answers within two minutes; on some conflicts it keeps
  # backtracking far longer.  Treat that like any other set it cannot
  # resolve, so the roots get split and the rest is still built.
  # In the background, so that a stop signal from the host is acted on at
  # once and not after the calculation.
  timeout --signal=TERM --kill-after=30 "$PLAN_TIMEOUT" \
    emerge --pretend "${RESOLVE_OPTS[@]}" "${EXCLUDE_OPTS[@]}" "$@" >> "$PLAN_LOG" 2>&1 &
  wait "$!" || rc=$?
  if (( rc == 124 || rc == 137 )); then
    echo "!!! No answer from the dependency resolver after ${PLAN_TIMEOUT} seconds; gave up." >> "$PLAN_LOG"
    return 1
  fi
  # Never plan blind: without the indexes everything looks unbuilt.
  if grep -qE 'Error fetching binhost package info|index version is not supported|has no TIMESTAMP field' "$PLAN_LOG"; then
    cat "$PLAN_LOG"
    die "A binhost index could not be read (see above); not building without it"
  fi
  # "... changes are necessary to proceed": Portage could only resolve by
  # changing the configuration (a USE flag, a keyword, a licence).
  if (( rc != 0 )) || grep -qE '^\[blocks B|changes are necessary to proceed' "$PLAN_LOG"; then
    return 1
  fi
  mapfile -t PLAN_ATOMS < <(sed -nE 's/^\[ebuild[^]]*\] +([^ :]+).*/=\1/p' "$PLAN_LOG")
  PLAN_MERGES="$(grep -cE '^\[(ebuild|binary)' "$PLAN_LOG" || true)"
  return 0
}

# Some packages need each other to build (ffmpeg needs openal, which needs
# pipewire, which needs ffmpeg).  On a machine that has them installed this
# never shows; in a fresh container Portage refuses to order them and names
# a USE flag that would break the loop.  Apply that suggestion for one build
# only: once the packages exist they are rebuilt with the configured flags,
# so what gets published matches the machines' configuration.
#
# The intermediate build is installed but not turned into a binary package:
# a package built with flags nobody configured must never be published.
CYCLE_USE="/etc/portage/package.use/zz-builder-cycle-breakers"
CYCLE_ENV="/etc/portage/package.env/zz-builder-cycle-breakers"

forget_cycles() { rm -f "$CYCLE_USE" "$CYCLE_ENV"; }

# Returns 0 when the roots resolve with temporary flags, 1 when they do not,
# 42 when the deadline is too close to keep trying.
break_cycles() {
  local suggestion
  mkdir -p /etc/portage/env /etc/portage/package.env
  echo 'FEATURES="-buildpkg"' > /etc/portage/env/binhost-no-buildpkg.conf
  for _ in 1 2 3 4 5 6 7 8; do
    grep -q 'Error: circular dependencies' "$PLAN_LOG" || return 1
    deadline_near && return 42
    # The first suggestion under "It might be possible to break this cycle":
    #   - media-video/pipewire-1.6.9 (Change USE: -ffmpeg)
    suggestion="$(awk '/It might be possible to break this cycle/ { on = 1; next }
                       on && /^- / { print; exit }' "$PLAN_LOG" \
      | sed -nE 's/^- ([^ :]+) \(Change USE: ([^)]+)\)$/=\1 \2/p')"
    [[ -n "$suggestion" ]] || return 1
    suggestion="${suggestion// +/ }"
    echo "$suggestion" >> "$CYCLE_USE"
    echo "${suggestion%% *} binhost-no-buildpkg.conf" >> "$CYCLE_ENV"
    log "${TIER}: build-time dependency cycle; for this build only: ${suggestion}"
    plan "$@" && return 0
  done
  return 1
}

# resolve <roots...>: plan, breaking dependency cycles if that is all that
# stands in the way.  Sets CYCLE_BROKEN.  Returns like break_cycles.
resolve() {
  local rc=0
  CYCLE_BROKEN=false
  forget_cycles
  plan "$@" && return 0
  break_cycles "$@" || rc=$?
  if (( rc == 0 )); then
    CYCLE_BROKEN=true
    return 0
  fi
  forget_cycles
  return "$rc"
}

# record_unresolved <root> [<reason>]: without a reason, the root's own
# dependency calculation (the last one made) is the explanation.
record_unresolved() {
  local root="$1" why="see ${PLAN_LOG#"${OUT}/"}"
  UNRESOLVED_COUNT=$(( UNRESOLVED_COUNT + 1 ))
  if (( $# > 1 )); then
    printf '%s\t%s\n' "$root" "$2" >> "$OUT/unresolved.tsv"
    echo "::error title=Not resolved: ${root}::${2}"
    return 0
  fi
  # "masked by: exclude option": it needs a package that failed earlier.
  if grep -q 'masked by: exclude option' "$PLAN_LOG"; then
    why="needs a package that failed to build in this run; ${why}"
  fi
  printf '%s\t%s\n' "$root" "$why" >> "$OUT/unresolved.tsv"
  echo "::error title=Cannot resolve ${root}::Portage found no way to install ${root}: ${why} in the logs artifact"
  echo "::group::emerge --pretend ${root}"
  tail -n 60 "$PLAN_LOG"
  echo "::endgroup::"
}

# ── Building ────────────────────────────────────────────────────────────

# How many packages are built (their binary is in PKGDIR), not installed, and
# still held by emerge for installing.
pending_merges() {
  [[ -f "${PKGDIR}/Packages" ]] || { echo 0; return 0; }
  local cpv built installed pending=0
  # The newest build of each version; an older one is never installed.
  while read -r cpv built; do
    installed=""
    if [[ -f "/var/db/pkg/${cpv}/BUILD_TIME" ]]; then
      installed="$(tr -d '[:space:]' < "/var/db/pkg/${cpv}/BUILD_TIME")"
    fi
    # Emerge keeps the build directory of a package until it is installed.
    # Without one (or with a failure marker in it) nothing will install this
    # binary any more: its merge failed, or it was replaced or removed.
    if [[ "$installed" != "$built" && -d "${PORTAGE_TMP}/${cpv}" \
          && ! -e "${PORTAGE_TMP}/${cpv}/.die_hooks" ]]; then
      pending=$(( pending + 1 ))
    fi
  done < <(awk '
    /^CPV: /        { cpv = $2 }
    /^BUILD_TIME: / { built = $2 }
    /^$/            { if (cpv != "" && built + 0 > newest[cpv] + 0) newest[cpv] = built; cpv = ""; built = "" }
    END             { if (cpv != "" && built + 0 > newest[cpv] + 0) newest[cpv] = built
                      for (cpv in newest) print cpv, newest[cpv] }' "${PKGDIR}/Packages")
  echo "$pending"
}

# Portage installs a finished package only at a moment when nothing else is
# building (FEATURES=merge-wait, and always for the base system), and when it
# is told to stop it drops the ones still waiting: built and signed, but
# never installed and therefore never published.  SIGUSR2 makes it install
# what is waiting.  One signal moves one base-system package, so keep asking
# until nothing is left or the time is up.  Only sent once a build has
# finished: before that emerge has no handler for the signal and would die.
DRAIN_SECONDS=240
drain_merges() {
  local pid="$1" waited=0 pending
  while kill -0 "$pid" 2>/dev/null && (( waited < DRAIN_SECONDS )); do
    pending="$(pending_merges)"
    if (( pending == 0 )); then
      # Installed, but emerge may still be finishing the last one off.
      if (( waited > 0 )); then sleep 10; fi
      return 0
    fi
    (( waited > 0 )) || log "Deadline reached; installing ${pending} finished package(s) before stopping"
    kill -USR2 "$pid" 2>/dev/null || true
    sleep 5
    waited=$(( waited + 5 ))
  done
  return 0
}

run_emerge_with_deadline() {
  if (( DEADLINE == 0 )); then
    emerge "$@"
    return $?
  fi
  if (( $(date +%s) + MIN_WINDOW >= DEADLINE )); then
    log "Not enough time left to start another build"
    return 42
  fi

  setsid emerge "$@" &
  local emerge_pid=$!
  while kill -0 "$emerge_pid" 2>/dev/null; do
    sleep 15
    if (( $(date +%s) >= DEADLINE )); then
      # From here on a build that dies was cut off, not broken.
      TIMEOUT_FIRED_AT=$(date +%s)
      drain_merges "$emerge_pid"
      log "Deadline reached, stopping emerge"
      kill -TERM -- -"${emerge_pid}" 2>/dev/null || true
      local waited=0
      while kill -0 "$emerge_pid" 2>/dev/null && (( waited < 90 )); do
        sleep 5
        waited=$(( waited + 5 ))
      done
      if kill -0 "$emerge_pid" 2>/dev/null; then
        log "emerge did not exit after SIGTERM, sending SIGKILL to its process group"
        kill -KILL -- -"${emerge_pid}" 2>/dev/null || true
      fi
      wait "$emerge_pid" 2>/dev/null || true
      return 42
    fi
  done
  wait "$emerge_pid"
}

# Copy the log of every package that died and report it.  Packages that
# were merely cut off by the deadline are not failures.
collect_failures() {
  [[ -d "$PORTAGE_TMP" ]] || return 0
  local markers=() marker
  while IFS= read -r -d '' marker; do markers+=("$marker"); done < <(
    find "$PORTAGE_TMP" -mindepth 3 -maxdepth 3 -type f -name .die_hooks -print0
    find "$PORTAGE_TMP" -mindepth 4 -maxdepth 4 -type f -path '*/temp/die.env' -print0
  )
  (( ${#markers[@]} > 0 )) || return 0

  local cat_pf temp_dir phase class dest env_src cp_name
  local -A seen=()
  for marker in "${markers[@]}"; do
    cat_pf="${marker#"${PORTAGE_TMP}"/}"
    case "$marker" in
      */temp/die.env) cat_pf="${cat_pf%/temp/die.env}" ;;
      *)              cat_pf="${cat_pf%/.die_hooks}" ;;
    esac
    [[ -z "${seen[$cat_pf]:-}" ]] || continue
    seen["$cat_pf"]=1
    temp_dir="${PORTAGE_TMP}/${cat_pf}/temp"

    if (( TIMEOUT_FIRED_AT > 0 )) && (( $(stat -c %Y "$marker") >= TIMEOUT_FIRED_AT - 2 )); then
      log "  ${cat_pf}: interrupted by the deadline, not a failure"
      continue
    fi

    phase=""
    env_src=""
    [[ -f "${temp_dir}/environment" ]] && env_src="${temp_dir}/environment"
    [[ -z "$env_src" && -f "${temp_dir}/die.env" ]] && env_src="${temp_dir}/die.env"
    if [[ -n "$env_src" ]]; then
      phase="$(grep -m1 -E '(^|[[:space:]])EBUILD_PHASE=' "$env_src" \
        | sed -E 's/.*EBUILD_PHASE=//; s/^"//; s/"$//' || true)"
    fi
    if [[ -z "$phase" && -f "${temp_dir}/build.log" ]]; then
      phase="$(grep -m1 -oE 'failed \([a-z_-]+ phase\)' "${temp_dir}/build.log" \
        | sed -E 's/^failed \(([a-z_-]+) phase\)$/\1/' || true)"
    fi
    [[ -n "$phase" ]] || phase="unknown"

    # Out of disk or memory says nothing about the package.
    class="build"
    if [[ -f "${temp_dir}/build.log" ]] && grep -qE \
         'No space left on device|Killed signal terminated program|terminated with signal 9|signal: 9, SIGKILL|[Oo]ut of memory|Cannot allocate memory|virtual memory exhausted' \
         "${temp_dir}/build.log"; then
      class="resource"
    fi

    FAILURES_SEEN=$(( FAILURES_SEEN + 1 ))
    if cut -f1 "$OUT/failures.tsv" | grep -qxF "$cat_pf"; then
      # Already reported in this run; it was tried again because it had run
      # out of memory or disk.  Once more is enough.
      cp_name="$(qatom -F '%{CATEGORY}/%{PN}' "=${cat_pf}")"
      if [[ " ${FAILED_CPS[*]} " != *" ${cp_name} "* ]]; then
        FAILED_CPS+=("$cp_name")
        EXCLUDE_OPTS+=("--exclude=${cp_name}")
      fi
      rm -rf "${PORTAGE_TMP:?}/${cat_pf}"
      continue
    fi
    dest="${OUT}/failures/${cat_pf}"
    mkdir -p "$dest"
    [[ -f "${temp_dir}/build.log" ]] && cp "${temp_dir}/build.log" "${dest}/build.log"
    FAILED_COUNT=$(( FAILED_COUNT + 1 ))
    printf '%s\t%s\t%s\n' "$cat_pf" "$phase" "$class" >> "$OUT/failures.tsv"
    # Not again in this run: later calculations leave it out, and whatever
    # needs it is reported as unresolvable instead of being started.  A
    # package that ran out of memory or disk gets one more try, by a later
    # tier that needs it, under other conditions (see above).
    if [[ "$class" == build ]]; then
      cp_name="$(qatom -F '%{CATEGORY}/%{PN}' "=${cat_pf}")"
      FAILED_CPS+=("$cp_name")
      EXCLUDE_OPTS+=("--exclude=${cp_name}")
    fi

    echo "::error title=Package build failed::${cat_pf} failed in phase '${phase}' (${class}). Log: failures/${cat_pf}/build.log in the logs artifact."
    if [[ -f "${dest}/build.log" ]]; then
      echo "::group::${cat_pf} build.log tail"
      tail -n "$FAILURE_LOG_TAIL_LINES" "${dest}/build.log"
      echo "::endgroup::"
    fi
    # Reported; free the space and keep the marker from being seen again.
    rm -rf "${PORTAGE_TMP:?}/${cat_pf}"
  done
}

# run_planned <mode> <roots...>: carry out the plan that was just resolved.
#   atoms  pass only the versions that need compiling, so nothing that is
#          already available as a binary gets installed unless one of them
#          depends on it
#   roots  pass the roots themselves, installing binaries too (system update)
run_planned() {
  local mode="$1"; shift
  local targets=()
  if [[ "$mode" == roots ]]; then
    (( PLAN_MERGES > 0 )) && targets=("$@")
  else
    targets=("${PLAN_ATOMS[@]}")
  fi
  if (( ${#targets[@]} == 0 )); then
    log "${TIER}: nothing to do for ${#} root(s)"
    return 0
  fi
  (( ${#PLAN_ATOMS[@]} > 0 )) && printf '%s\n' "${PLAN_ATOMS[@]}" >> "$OUT/planned.txt"
  log "${TIER}: ${#PLAN_ATOMS[@]} package(s) to compile, ${PLAN_MERGES} to install in total"
  if [[ "$PLAN_ONLY" == true ]]; then
    (( ${#PLAN_ATOMS[@]} > 0 )) && printf '  %s\n' "${PLAN_ATOMS[@]}"
    return 0
  fi

  local rc=0 seen_before=$FAILURES_SEEN
  run_emerge_with_deadline --keep-going --jobs="$TIER_JOBS" "${RESOLVE_OPTS[@]}" \
    "${EXCLUDE_OPTS[@]}" "${targets[@]}" || rc=$?
  collect_failures
  write_merged
  (( rc == 42 )) && return 42
  if (( rc != 0 && FAILURES_SEEN == seen_before )); then
    # emerge gave up for a reason other than a package that failed to
    # compile (a binary that would not install, a late resolver error).
    UNRESOLVED_COUNT=$(( UNRESOLVED_COUNT + 1 ))
    printf '%s\t%s\n' "$*" "emerge exited ${rc} without a package build failure; see the job log" \
      >> "$OUT/unresolved.tsv"
    echo "::error title=emerge stopped (${TIER})::emerge exited ${rc} without a package build failure while building for: $*"
  fi
  return 0
}

# Bring the container's own packages in line with the configuration before
# the first compile of a run: the stage3 is built with the profile defaults,
# and leftovers of those (another Python target, older library versions)
# conflict with what the tiers pull in.  Binaries are used where they exist,
# so after the first run this is a few minutes of installing.  Skipped
# entirely on a run that has nothing to compile.
SYSTEM_UPDATED=false
update_system() {
  SYSTEM_UPDATED=true
  local saved_tier="$TIER" saved_jobs="$TIER_JOBS" saved_opts=("${RESOLVE_OPTS[@]}") rc=0
  TIER="system"
  TIER_JOBS=2
  RESOLVE_OPTS=("${BASE_OPTS[@]}" "${DEEP_OPTS[@]}")
  log "── updating the container's base system ──"
  build_roots roots @world || rc=$?
  TIER="$saved_tier"
  TIER_JOBS="$saved_jobs"
  RESOLVE_OPTS=("${saved_opts[@]}")
  return "$rc"
}

# build_roots <mode> <roots...>: build what the roots need.  If Portage
# cannot resolve them together, split the list so one unresolvable root does
# not block the others.
build_roots() {
  local mode="$1"; shift
  local rc=0

  # Resolving takes time too; do not keep planning past the deadline.
  deadline_near && return 42

  local resolve_started
  resolve_started=$(date +%s)
  resolve "$@" || rc=$?
  (( rc == 42 )) && return 42
  if (( rc != 0 )); then RESOLVE_SPENT=$(( RESOLVE_SPENT + $(date +%s) - resolve_started )); fi

  # The base system is updated once per run, before the first compile.  Also
  # when the roots do not resolve: leftovers of the stage3's configuration
  # may be exactly what is in the way.
  if [[ "$mode" == atoms && "$TIER_SYSTEM_UPDATE" == true && "$SYSTEM_UPDATED" == false \
        && "$PLAN_ONLY" != true ]] && { (( rc != 0 )) || (( ${#PLAN_ATOMS[@]} > 0 )); }; then
    rc=0
    update_system || rc=$?
    (( rc == 42 )) && return 42
    # What is installed changed, so the plan has to be made again.
    rc=0
    resolve_started=$(date +%s)
    resolve "$@" || rc=$?
    (( rc == 42 )) && return 42
    if (( rc != 0 )); then RESOLVE_SPENT=$(( RESOLVE_SPENT + $(date +%s) - resolve_started )); fi
  fi

  if (( rc != 0 )); then
    local root
    if (( $# == 1 )); then
      record_unresolved "$1"
      return 0
    fi
    # Failing calculations add up: one broken package that many roots need
    # makes each of them fail.  Past the budget the rest of the tier is
    # given up for this run, so that the tiers after it still get their turn.
    if (( RESOLVE_SPENT >= RESOLVE_BUDGET )); then
      for root in "$@"; do
        record_unresolved "$root" "not examined: resolving tier ${TIER} already took $(( RESOLVE_SPENT / 60 )) minutes of failed attempts"
      done
      return 0
    fi
    # Portage names the root whose dependency it could not satisfy:
    #   (dependency required by "kde-apps/kdenlive" [argument])
    #   # required by media-libs/mesa[abi_x86_32] (argument)
    # Try the others without it, and then that root alone (it may only fail
    # in this company); that takes fewer calculations than halving the list.
    local culprits=() rest=() named_roots=() culprit named
    mapfile -t culprits < <(
      sed -nE -e 's/^\(dependency required by "([^"]+)" \[argument\]\)$/\1/p' \
              -e 's/^# required by (.+) \(argument\)$/\1/p' "$PLAN_LOG" | sort -u)
    if (( ${#culprits[@]} > 0 )); then
      for root in "$@"; do
        named=false
        for culprit in "${culprits[@]}"; do
          if [[ "$root" == "$culprit" ]]; then named=true; fi
        done
        if [[ "$named" == true ]]; then
          named_roots+=("$root")
        else
          rest+=("$root")
        fi
      done
      if (( ${#named_roots[@]} > 0 )); then
        log "${TIER}: ${#named_roots[@]} root(s) named by Portage are tried on their own; ${#rest[@]} remain together"
        if (( ${#rest[@]} > 0 )); then
          rc=0
          build_roots "$mode" "${rest[@]}" || rc=$?
          (( rc == 42 )) && return 42
        fi
        for root in "${named_roots[@]}"; do
          rc=0
          build_roots "$mode" "$root" || rc=$?
          (( rc == 42 )) && return 42
        done
        return 0
      fi
    fi
    log "${TIER}: ${#} roots do not resolve together; splitting"
    local half=$(( $# / 2 ))
    rc=0
    build_roots "$mode" "${@:1:half}" || rc=$?
    (( rc == 42 )) && return 42
    build_roots "$mode" "${@:half+1}" || rc=$?
    (( rc == 42 )) && return 42
    return 0
  fi

  local cycle_broken="$CYCLE_BROKEN"
  run_planned "$mode" "$@" || rc=$?
  forget_cycles
  (( rc == 42 )) && return 42

  if [[ "$cycle_broken" == true && "$PLAN_ONLY" != true ]]; then
    # The packages of the cycle exist now; build them as configured.  This
    # is the build that produces their binary packages.
    deadline_near && return 42
    log "${TIER}: rebuilding the packages of the dependency cycle with their configured USE flags"
    if plan "$@"; then
      run_planned "$mode" "$@" || rc=$?
      (( rc == 42 )) && return 42
    else
      echo "::warning title=Dependency cycle (${TIER})::Could not rebuild the packages of a build-time dependency cycle with their configured USE flags; they are not published and machines will compile them. See ${PLAN_LOG#"${OUT}/"} in the logs artifact."
    fi
  fi
  return 0
}

read_roots() {
  local -n _roots=$1
  local line
  _roots=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(xargs <<< "$line")"
    [[ -n "$line" ]] && _roots+=("$line")
  done < "$2"
  return 0
}

# ── Main ────────────────────────────────────────────────────────────────

tier_selected() {
  local wanted
  [[ -z "$TIERS" ]] && return 0
  for wanted in $TIERS; do
    [[ "$wanted" == "$1" ]] && return 0
  done
  return 1
}

shopt -s nullglob
tier_files=()
for file in "${TIERS_DIR}"/*.txt; do
  name="$(basename "$file" .txt)"
  if tier_selected "${name#[0-9][0-9]-}"; then
    tier_files+=("$file")
  fi
done
shopt -u nullglob
(( ${#tier_files[@]} > 0 )) || die "No tier matches '${TIERS}' in ${TIERS_DIR}"

bootstrap
[[ "$PLAN_ONLY" == true ]] || start_reporter

for file in "${tier_files[@]}"; do
  TIER="$(basename "$file" .txt)"
  TIER="${TIER#[0-9][0-9]-}"
  # Per-tier settings are "#@ key=value" lines in the tier file.
  #   jobs=1            build one package at a time: two multi-gigabyte
  #                     builds side by side exhaust memory and disk
  #   shallow=yes       build just the listed packages and what they lack,
  #                     without updating their dependencies or the base
  #                     system: the smoke tier only checks the pipeline and
  #                     has to stay quick
  TIER_JOBS="$(sed -nE 's/^#@ jobs=([0-9]+)$/\1/p' "$file" | head -1)"
  TIER_JOBS="${TIER_JOBS:-2}"
  TIER_SYSTEM_UPDATE=true
  RESOLVE_OPTS=("${BASE_OPTS[@]}" "${DEEP_OPTS[@]}")
  if grep -qx '#@ shallow=yes' "$file"; then
    TIER_SYSTEM_UPDATE=false
    RESOLVE_OPTS=("${BASE_OPTS[@]}")
  fi
  roots=()
  read_roots roots "$file"
  if (( ${#roots[@]} == 0 )); then
    log "${TIER}: no packages listed"
    continue
  fi
  log "── tier ${TIER}: ${#roots[@]} root(s), --jobs=${TIER_JOBS} ──"
  RESOLVE_SPENT=0
  rc=0
  build_roots atoms "${roots[@]}" || rc=$?
  if (( rc == 42 )); then
    STATUS="deadline"
    break
  fi
done

log "Finished with status ${STATUS}: ${FAILED_COUNT} failed, ${UNRESOLVED_COUNT} unresolved"
[[ "$STATUS" == deadline ]] && exit 42
exit 0
