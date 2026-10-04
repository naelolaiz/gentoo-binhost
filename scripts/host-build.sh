#!/usr/bin/env bash
# host-build.sh — one build run on a CI host.
#
#   host-build.sh run       start the build container, publish packages while
#                           it works and when it stops, record whether a
#                           follow-up run is needed
#   host-build.sh salvage   after an aborted `run`: stop the container and
#                           publish whatever was finished
#
# The host does everything that needs credentials (releases, the index
# branch); the container only compiles.  The token never enters it.
#
# Environment:
#   REPO             owner/name of this repository
#   GH_TOKEN         token with contents: write
#   GPG_PRIVATE_KEY  armored secret key that signs the packages
#   GPG_PASSPHRASE   its passphrase, if it has one
#   INDEX_BRANCH     branch holding the package index
#   TAG_PREFIX       prefix of the release tags holding the package files
#   WORK             scratch directory (packages, compiler cache, logs)
#   JOB_START        epoch at which the job started
#   BUDGET_MINUTES   minutes after JOB_START at which building stops
#   TIERS            tiers to build; empty means all
#   ALLOW_CONTINUE   "true" if this run may request a follow-up run
#
# Results go to $GITHUB_OUTPUT (key=value) and $GITHUB_STEP_SUMMARY.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=config/binhost.conf
. "${REPO_ROOT}/config/binhost.conf"

log() { echo "[host] $*"; }
die() { echo "::error::$*" >&2; exit 1; }

MODE="${1:-run}"
: "${REPO:?}" "${GH_TOKEN:?}" "${INDEX_BRANCH:?}" "${TAG_PREFIX:?}" "${WORK:?}"
CONTAINER="binhost-builder"
OUT="${WORK}/out"
# A chain of runs that keeps hitting the time limit ends after this many runs
# in a row that published nothing (one package that does not get finished),
# and after this many runs altogether (the tree it is pinned to is stale).
MAX_IDLE=4
MAX_STREAK=40
# How long a continuation keeps the tree and image of the run it continues.
PIN_SECONDS=$(( 48 * 3600 ))
TICK_SECONDS=300

binhost() {
  python3 "${SCRIPT_DIR}/binhost.py" --backend github --repo "$REPO" --branch "$INDEX_BRANCH" \
    --tag-prefix "$TAG_PREFIX" --lock "${WORK}/publish.lock" "$@"
}

# Every index is parsed by Portage itself before it is pushed.
validator() {
  echo "docker run --rm -v {}:/Packages:ro -v ${SCRIPT_DIR}:/scripts:ro" \
       "-v ${WORK}/tree:/var/db/repos/gentoo:ro ${IMAGE_REF}" \
       "python3 /scripts/portage-index.py check /Packages"
}

publish() {
  local rc=0
  rm -f "${OUT}/publish-last.json"
  binhost --validate-cmd "$(validator)" publish --pkgdir "${WORK}/pkgdir" \
    --merged "${OUT}/merged.txt" --no-publish "${REPO_ROOT}/config/no-publish.txt" \
    --result "${OUT}/publish-last.json" "$@" || rc=$?
  if [[ -f "${OUT}/publish-last.json" ]]; then
    python3 - "${OUT}/publish-last.json" "${OUT}/published.txt" "${OUT}/head" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
with open(sys.argv[2], "a") as handle:
    for cpv in result.get("published", []):
        handle.write(cpv + "\n")
if result.get("head"):
    open(sys.argv[3], "w").write(result["head"])
PY
  fi
  return "$rc"
}

output() { echo "$1=$2" >> "${GITHUB_OUTPUT:-/dev/null}"; }
# Empty when the container died without leaving a result (killed, out of
# memory): the caller then treats the run as failed instead of stopping here.
result() {
  [[ -f "${OUT}/result.env" ]] || return 0
  sed -n "s/^$1=//p" "${OUT}/result.env" | head -1
}
state_field() {
  python3 -c 'import json, sys
record = json.loads(sys.argv[1] or "null") or {}
print(record.get(sys.argv[2], ""))' "$1" "$2"
}

salvage() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  [[ -f "${WORK}/image-ref" ]] || { log "nothing was started; nothing to salvage"; return 0; }
  IMAGE_REF="$(cat "${WORK}/image-ref")"
  publish --final --pending-ok --deadline "$(( $(date +%s) + 600 ))" \
    || echo "::error::Some finished packages could not be published; the next run rebuilds them"
}

if [[ "$MODE" == salvage ]]; then
  salvage
  exit 0
fi
[[ "$MODE" == run ]] || die "Usage: host-build.sh run|salvage"

: "${GPG_PRIVATE_KEY:?The GPG_PRIVATE_KEY secret is not set. Machines verify package signatures, so the builder cannot publish without it (see keys/README.md).}"
: "${JOB_START:?}"
BUDGET_MINUTES="${BUDGET_MINUTES:-285}"
# Below half an hour, setting up and the ten minutes a build must have left
# to be started at all leave no time to build anything.
[[ "$BUDGET_MINUTES" =~ ^[0-9]+$ ]] && (( BUDGET_MINUTES >= 30 && BUDGET_MINUTES <= 300 )) \
  || die "BUDGET_MINUTES must be a number between 30 and 300, got '${BUDGET_MINUTES}'"
DEADLINE=$(( JOB_START + BUDGET_MINUTES * 60 ))
TIERS="${TIERS:-}"

mkdir -p "${WORK}"/{pkgdir,ccache,portage-tmp,tree,distfiles,secrets} "$OUT"
: > "${OUT}/published.txt"

# ── What the previous run left for this one ─────────────────────────────
binhost init
record="$(binhost state-get continue)"
pin_tree=""
pin_image=""
streak=0
idle=0
updated="$(state_field "$record" updated)"
if [[ -n "$updated" ]] && (( $(date +%s) - updated < PIN_SECONDS )); then
  pin_tree="$(state_field "$record" tree_date)"
  pin_image="$(state_field "$record" image)"
  streak="$(state_field "$record" streak)"
  [[ "$streak" =~ ^[0-9]+$ ]] || streak=0
  idle="$(state_field "$record" idle)"
  [[ "$idle" =~ ^[0-9]+$ ]] || idle=0
  # A continuation finishes what the interrupted run was building, whatever
  # this run was asked for.
  recorded_tiers="$(state_field "$record" tiers)"
  if [[ -n "$TIERS" && -n "$recorded_tiers" ]]; then
    TIERS="$(tr ' ' '\n' <<< "${TIERS} ${recorded_tiers}" | sort -u | xargs)"
  elif [[ -n "$TIERS" ]]; then
    TIERS=""
  fi
  log "Continuing an interrupted run (${streak} so far): tree ${pin_tree}, image ${pin_image}"
fi

# ── Image ───────────────────────────────────────────────────────────────
image="$STAGE3_IMAGE"
if [[ -n "$pin_image" ]]; then
  if docker pull --quiet "$pin_image" >/dev/null; then
    image="$pin_image"
  else
    echo "::warning::The image of the interrupted run is gone; starting from the current one. Its compiler cache may not apply."
    pin_tree=""
  fi
fi
[[ "$image" == "$pin_image" ]] || docker pull --quiet "$image" >/dev/null
IMAGE_REF="$(docker image inspect --format '{{index .RepoDigests 0}}' "$image")"
echo "$IMAGE_REF" > "${WORK}/image-ref"
log "Image: ${IMAGE_REF}"

# The builder reads the index at the exact commit it starts from, so it
# never sees a half-propagated copy.
head_sha="$(git ls-remote "https://github.com/${REPO}.git" "refs/heads/${INDEX_BRANCH}" | cut -f1)"
[[ -n "$head_sha" ]] || die "Branch ${INDEX_BRANCH} does not exist after init"
echo "$head_sha" > "${OUT}/head"
binhost_uri="https://raw.githubusercontent.com/${REPO}/${head_sha}"

# ── Start building ──────────────────────────────────────────────────────
( umask 077
  printf '%s\n' "$GPG_PRIVATE_KEY" > "${WORK}/secrets/signing-key.asc"
  [[ -z "${GPG_PASSPHRASE:-}" ]] || printf '%s' "$GPG_PASSPHRASE" > "${WORK}/secrets/passphrase" )
args=(--tiers "$TIERS" --binhost-uri "$binhost_uri"
      --trust-key /repo/keys/binhost-signing-key.asc
      --sign-key /run/binhost-secrets/signing-key.asc
      --deadline "$DEADLINE" --out /out)
[[ -z "${GPG_PASSPHRASE:-}" ]] || args+=(--sign-passphrase /run/binhost-secrets/passphrase)
[[ -z "$pin_tree" ]] || args+=(--tree-date "$pin_tree")

docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run --detach --name "$CONTAINER" --init --privileged \
  -v "${REPO_ROOT}:/repo:ro" \
  -v "${WORK}/pkgdir:/var/cache/binpkgs" \
  -v "${WORK}/ccache:/var/cache/ccache" \
  -v "${WORK}/portage-tmp:/var/tmp/portage" \
  -v "${WORK}/tree:/var/db/repos/gentoo" \
  -v "${WORK}/distfiles:/var/cache/distfiles" \
  -v "${OUT}:/out" \
  -v "${WORK}/secrets:/run/binhost-secrets:ro" \
  "$IMAGE_REF" bash /repo/scripts/container-build.sh "${args[@]}" >/dev/null
docker logs --follow "$CONTAINER" &

# ── Publish while it builds ─────────────────────────────────────────────
waited=0
stopped=false
while [[ "$(docker inspect --format '{{.State.Running}}' "$CONTAINER")" == true ]]; do
  sleep 20
  waited=$(( waited + 20 ))
  # The container stops itself at the deadline.  If it is still running
  # twenty minutes later, stop it from here while there is time left to
  # publish.  It then reports the run as cut off by the deadline, unless it
  # had to be killed, which counts as a failed container.
  if [[ "$stopped" == false ]] && (( $(date +%s) >= DEADLINE + 1200 )); then
    echo "::warning::The build container overran its deadline; stopping it"
    docker stop -t 150 "$CONTAINER" >/dev/null || true
    stopped=true
  fi
  if [[ -f "${OUT}/bootstrap.done" && -n "$(ls -A "${WORK}/secrets")" ]]; then
    # The key is imported; the copy on disk has served its purpose.
    rm -f "${WORK}/secrets"/*
  fi
  if (( waited >= TICK_SECONDS )) && [[ -f "${OUT}/bootstrap.done" ]]; then
    waited=0
    publish --deadline "$(( DEADLINE + 300 ))" \
      || echo "::warning::Publishing during the build failed; it is retried when the build stops"
  fi
done
wait || true
rm -f "${WORK}/secrets"/*
container_rc="$(docker inspect --format '{{.State.ExitCode}}' "$CONTAINER")"
docker rm "$CONTAINER" >/dev/null

# ── Publish the rest ────────────────────────────────────────────────────
status="$(result status)"
case "$container_rc" in
  0|42) ;;
  *) status="error" ;;
esac
[[ -n "$status" ]] || status="error"

publish_rc=0
final_opts=(--final --deadline "$(( $(date +%s) + 900 ))")
# A build that was stopped leaves packages that are built but not installed;
# only after a complete run does that mean something went wrong.
[[ "$status" == complete ]] || final_opts+=(--pending-ok)
publish "${final_opts[@]}" || publish_rc=$?

# Also when some packages could not be published (exit 3): pruning is what
# makes room again, and it only touches files the index no longer refers to.
if [[ "$status" == complete && ( "$publish_rc" == 0 || "$publish_rc" == 3 ) && -f "${OUT}/gone.txt" ]]; then
  binhost --validate-cmd "$(validator)" prune --gone "${OUT}/gone.txt" --grace-days 14 \
    || echo "::warning::Pruning failed; it is tried again by the next complete run"
fi

published="$(sort -u "${OUT}/published.txt" | grep -c . || true)"
failed="$(result failed)"; failed="${failed:-0}"
unresolved="$(result unresolved)"; unresolved="${unresolved:-0}"
ccache_stored="$(result ccache_stored)"; ccache_stored="${ccache_stored:-0}"
tree_date="$(result tree_date)"

# ── Does another run have to follow? ────────────────────────────────────
# Only when this one ran out of time and got somewhere: it published
# something, or it compiled something new (which the compiler cache keeps for
# the next run).  A run that did neither would only repeat itself.  A run
# that published nothing may be in the middle of one long package; several
# of those in a row mean the package does not get finished this way.
next="false"
stop_reason=""
stop_note=""
if (( published > 0 )); then idle=0; else idle=$(( idle + 1 )); fi
if [[ "$status" == deadline ]]; then
  if [[ "${ALLOW_CONTINUE:-false}" != true ]]; then
    stop_reason="follow-up runs are only started from the default branch"
  elif (( published == 0 && ccache_stored == 0 )); then
    stop_reason="the run reached the time limit without finishing or compiling anything new"
  elif (( idle >= MAX_IDLE )); then
    stop_reason="${MAX_IDLE} runs in a row reached the time limit without publishing a package (interrupted: $(result interrupted))"
  elif (( streak + 1 >= MAX_STREAK )); then
    # Not a problem to report: the chain did its work, its tree is just old.
    stop_note="${MAX_STREAK} runs in a row reached the time limit; the next daily run starts again from a current tree"
  else
    next="true"
  fi
fi
if [[ "$next" == true ]]; then
  binhost state-set continue "$(python3 -c 'import json, sys, time
print(json.dumps({"tiers": sys.argv[1], "tree_date": sys.argv[2], "image": sys.argv[3],
                  "streak": int(sys.argv[4]) + 1, "idle": int(sys.argv[5]),
                  "updated": int(time.time())}))' \
    "$TIERS" "$tree_date" "$IMAGE_REF" "$streak" "$idle")"
elif [[ -n "$updated" && "$status" != error ]]; then
  # The chain is over.  After a failed container the record stays: whatever
  # runs next continues with the same tree, until the record expires.
  binhost state-set continue null
fi

# ── Report ──────────────────────────────────────────────────────────────
problems="${OUT}/problems.md"
: > "$problems"
[[ "$status" != error ]] \
  || echo "- The build container failed (exit ${container_rc}) before or outside of building packages." >> "$problems"
[[ "$publish_rc" == 0 ]] \
  || echo "- Some finished packages could not be published; the next run rebuilds them." >> "$problems"
[[ -z "$stop_reason" ]] || echo "- Building stopped: ${stop_reason}." >> "$problems"
if (( failed > 0 )); then
  echo "- ${failed} package(s) failed to build:" >> "$problems"
  awk -F'\t' 'NR <= 40 { printf "  - `%s` in phase `%s`%s\n", $1, $2, ($3 == "resource" ? " (out of memory or disk, not the package)" : "") }
              END { if (NR > 40) printf "  - ... and %d more, see failures.tsv in the logs artifact\n", NR - 40 }' \
    "${OUT}/failures.tsv" >> "$problems"
fi
if (( unresolved > 0 )); then
  echo "- ${unresolved} root(s) could not be resolved:" >> "$problems"
  awk -F'\t' 'NR <= 40 { printf "  - `%s` (%s)\n", $1, $2 }
              END { if (NR > 40) printf "  - ... and %d more, see unresolved.tsv in the logs artifact\n", NR - 40 }' \
    "${OUT}/unresolved.tsv" >> "$problems"
fi
healthy="true"
[[ ! -s "$problems" ]] || healthy="false"

# A few of the published packages for the install check: smallest first.
verify_cpvs="$(python3 - "${OUT}/published.txt" "${WORK}/pkgdir/Packages" "$SCRIPT_DIR" <<'PY'
import os, sys
sys.path.insert(0, sys.argv[3])
import pkgindex
published = {line.strip() for line in open(sys.argv[1]) if line.strip()}
sizes = {}
if os.path.exists(sys.argv[2]):
    for pkg in pkgindex.parse(open(sys.argv[2]).read()).packages:
        sizes[pkg["CPV"]] = int(pkg.get("SIZE", "0") or 0)
print(" ".join(sorted(published, key=lambda cpv: (sizes.get(cpv, 1 << 62), cpv))[:8]))
PY
)"

output status "$status"
# Whether this run covered every tier (a clean partial run proves nothing
# about the tiers it did not look at).
output all_tiers "$([[ -z "$TIERS" ]] && echo true || echo false)"
output continue "$next"
output healthy "$healthy"
output published "$published"
output verify_cpvs "$verify_cpvs"
output head "$(cat "${OUT}/head")"
output tree_date "$tree_date"
output image "$IMAGE_REF"
{
  echo "problems<<BINHOST_EOF"
  cat "$problems"
  echo "BINHOST_EOF"
} >> "${GITHUB_OUTPUT:-/dev/null}"

{
  echo "## Build ${status}"
  echo ""
  echo "| | |"
  echo "|---|---|"
  echo "| Tiers | ${TIERS:-all} |"
  echo "| Published this run | ${published} |"
  echo "| Planned to compile | $(result planned) |"
  echo "| Failed / unresolved | ${failed} / ${unresolved} |"
  echo "| Compiler cache | $(result ccache_hits) hits, ${ccache_stored} new |"
  echo "| Tree snapshot | ${tree_date} |"
  echo "| Image | \`${IMAGE_REF}\` |"
  echo "| Toolchain | $(result gcc), $(result glibc) |"
  echo "| Index | \`${INDEX_BRANCH}\` at \`$(cat "${OUT}/head")\` |"
  echo "| Follow-up run | ${next} |"
  [[ -z "$stop_note" ]] || echo "| Chain ended | ${stop_note} |"
  if [[ -n "$(result interrupted)" ]]; then
    echo "| Interrupted | $(result interrupted) |"
  fi
  if [[ -s "$problems" ]]; then
    echo ""
    echo "### Needs attention"
    cat "$problems"
  fi
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

[[ -z "$stop_note" ]] || echo "::notice::Chain ended: ${stop_note}"
log "status=${status} published=${published} failed=${failed} unresolved=${unresolved} next=${next}"
[[ "$status" != error && "$publish_rc" == 0 ]] || exit 1
