#!/usr/bin/env bash
# End-to-end check of the whole pipeline, with a directory served over HTTP
# standing in for GitHub.  Each phase runs in its own fresh Gentoo stage3
# container; they share one state directory mounted at /state.
#
#   e2e.sh build     build the smoke tier, sign, publish
#   e2e.sh rebuild   a second run must find nothing to build
#   e2e.sh consume   a clean machine must install the published binaries,
#                    and must refuse them once the key is no longer trusted
#
# The time limit, for packages that take longer than one run (run after
# `build`, with the compiler cache directory shared between the two):
#
#   e2e.sh deadline  start a slow build and let the deadline interrupt it
#   e2e.sh resume    a fresh container must finish it from the compiler cache
#   e2e.sh drain     packages finished next to a build that the deadline cuts
#                    off must still be installed and published (needs two CPUs)
#
# How to start the containers is in docs/TESTING.md.
set -euo pipefail

PHASE="${1:-}"
REPO="/repo"
STATE="/state"
PORT=8099
BINHOST_URI="http://127.0.0.1:${PORT}/index"
ASSET_URI="http://127.0.0.1:${PORT}/assets"
STORE="${STATE}/store"
KEYS="${STATE}/keys"
TAG_PREFIX="pkgs-"

log() { echo "[e2e] $*"; }
fail() { echo "[e2e] FAIL: $*" >&2; exit 1; }

binhost() {
  python3 "${REPO}/scripts/binhost.py" --backend dir --root "$STORE" --uri "$ASSET_URI" \
    --tag-prefix "$TAG_PREFIX" "$@"
}

serve() {
  python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$STORE" >/dev/null 2>&1 &
  for _ in $(seq 1 50); do
    python3 -c "import urllib.request; urllib.request.urlopen('${BINHOST_URI}/Packages')" \
      2>/dev/null && return 0
    sleep 0.2
  done
  fail "the test binhost did not come up on port ${PORT}"
}

# A throwaway signing key with a passphrase, to exercise the harder path.
make_keys() {
  [[ -f "${KEYS}/secret.asc" ]] && return 0
  mkdir -p "$KEYS"
  local home
  home="$(mktemp -d)"
  chmod 700 "$home"
  echo "e2e-passphrase" > "${KEYS}/passphrase"
  gpg --homedir "$home" --batch --pinentry-mode loopback --passphrase-file "${KEYS}/passphrase" \
      --quick-generate-key "Binhost end-to-end test" ed25519 sign never
  gpg --homedir "$home" --batch --armor --export > "${KEYS}/public.asc"
  gpg --homedir "$home" --batch --pinentry-mode loopback --passphrase-file "${KEYS}/passphrase" \
      --armor --export-secret-keys > "${KEYS}/secret.asc"
  rm -rf "$home"
}

builder() {
  local out="$1" rc=0
  bash "${REPO}/scripts/container-build.sh" --tiers smoke \
    --binhost-uri "$BINHOST_URI" --trust-key "${KEYS}/public.asc" \
    --sign-key "${KEYS}/secret.asc" --sign-passphrase "${KEYS}/passphrase" \
    --deadline "$(( $(date +%s) + 5400 ))" --out "$out" || rc=$?
  cat "${out}/result.env"
  (( rc == 0 )) || fail "the builder exited ${rc}"
}

# The slow tier: cmake, with a USE flag no binhost builds it with, so that
# it is compiled here.  On one CPU that takes well over the six minutes the
# deadline phase allows.
SLOW_SECONDS="${SLOW_SECONDS:-360}"
slow_builder() {
  local out="$1" seconds="$2"; shift 2
  mkdir -p /etc/portage/package.use
  echo "dev-build/cmake -ncurses" > /etc/portage/package.use/zz-e2e-slow
  SLOW_RC=0
  bash "${REPO}/scripts/container-build.sh" --tiers slow --tiers-dir "${REPO}/tests/tiers" \
    --binhost-uri "$BINHOST_URI" --trust-key "${KEYS}/public.asc" \
    --sign-key "${KEYS}/secret.asc" --sign-passphrase "${KEYS}/passphrase" \
    --deadline "$(( $(date +%s) + seconds ))" --min-window 120 --out "$out" "$@" || SLOW_RC=$?
  cat "${out}/result.env"
}

# How long the drain phase gives the builder: setting up, then building long
# enough for the short packages to finish.
DRAIN_TEST_SECONDS="${DRAIN_TEST_SECONDS:-600}"

result() { sed -n "s/^$2=//p" "$1/result.env"; }

case "$PHASE" in
  build)
    mkdir -p "$STORE"
    make_keys
    binhost init
    serve
    builder "${STATE}/out-build"
    [[ "$(result "${STATE}/out-build" status)" == complete ]] || fail "status is not complete"
    [[ "$(result "${STATE}/out-build" failed)" == 0 ]] || fail "a package failed to build"
    [[ "$(result "${STATE}/out-build" unresolved)" == 0 ]] || fail "a root did not resolve"

    # Fetched packages must not be mixed into PKGDIR, or they would be
    # republished as if they had been built here.
    if [[ -d /var/cache/binhost ]]; then
      log "fetched binaries are kept in: $(find /var/cache/binhost -maxdepth 1 -mindepth 1 -printf '%f ')"
    fi

    binhost --validate-cmd "python3 ${REPO}/scripts/portage-index.py check {}" \
      publish --pkgdir /var/cache/binpkgs --merged "${STATE}/out-build/merged.txt" \
      --final --result "${STATE}/publish.json"
    python3 - "${STATE}/publish.json" <<'PY' || fail "the smoke packages were not all published"
import json, sys
published = json.load(open(sys.argv[1]))["published"]
print("[e2e] published:", " ".join(published))
wanted = ("app-misc/hello-", "app-misc/jq-", "dev-libs/oniguruma-")
sys.exit(0 if all(any(cpv.startswith(w) for cpv in published) for w in wanted) else 1)
PY
    python3 "${REPO}/scripts/pkgindex.py" validate "${STORE}/index/Packages" --tag-prefix "$TAG_PREFIX"

    # Signatures are inside the gpkg; an unsigned one has no *.sig members.
    while IFS= read -r asset; do
      tar -tf "$asset" | grep -q '\.sig$' || fail "${asset} is not signed"
    done < <(find "${STORE}/assets" -name '*.gpkg.tar')
    cp "${STORE}/index/Packages" "${STATE}/Packages.after-build"
    log "build phase passed"
    ;;

  rebuild)
    serve
    builder "${STATE}/out-rebuild"
    [[ "$(result "${STATE}/out-rebuild" planned)" == 0 ]] \
      || fail "the second run wants to compile again: $(cat "${STATE}/out-rebuild/planned.txt")"
    [[ "$(result "${STATE}/out-rebuild" built)" == 0 ]] || fail "the second run built packages"
    binhost publish --pkgdir /var/cache/binpkgs --final --result "${STATE}/publish-2.json"
    cmp -s "${STORE}/index/Packages" "${STATE}/Packages.after-build" \
      || fail "the index changed although nothing was built"
    log "rebuild phase passed: nothing to do, index untouched"
    ;;

  consume)
    serve
    mapfile -t cpvs < <(python3 -c "
import json
print('\n'.join(sorted(json.load(open('${STATE}/publish.json'))['published'])))")
    bash "${REPO}/scripts/consumer-smoke.sh" --binhost-uri "$BINHOST_URI" \
      --trust-key "${KEYS}/public.asc" --tree-date "$(cat "${STATE}/out-build/tree-date")" \
      --install "${#cpvs[@]}" "${cpvs[@]}"
    hello | grep -q 'Hello, world' || fail "the installed hello does not run"
    echo '{"ok": true}' | jq -e .ok >/dev/null || fail "the installed jq does not run"

    # Without trust in the binhost key the same package must be refused.
    fpr="$(gpg --batch --with-colons --show-keys "${KEYS}/public.asc" | awk -F: '$1 == "fpr" { print $10; exit }')"
    gpg --homedir /etc/portage/gnupg --batch --yes --delete-keys "$fpr"
    rm -rf /var/cache/binhost/own-binhost
    hello_cpv="$(printf '%s\n' "${cpvs[@]}" | grep '^app-misc/hello-')"
    if emerge --oneshot --nodeps --usepkgonly --getbinpkg --color=n "=${hello_cpv}" \
         > "${STATE}/untrusted.log" 2>&1; then
      cat "${STATE}/untrusted.log"
      fail "a package signed by an untrusted key was installed"
    fi
    # It has to have failed for that reason, not for some other one.
    grep -q 'GnuPG verification failed' "${STATE}/untrusted.log" || {
      cat "${STATE}/untrusted.log"
      fail "the install failed, but not because of the signature"
    }
    log "consume phase passed: binaries used and verified, untrusted key refused"
    ;;

  deadline)
    [[ -f "${KEYS}/secret.asc" ]] || fail "run the build phase first"
    serve
    slow_builder "${STATE}/out-deadline" "$SLOW_SECONDS"
    (( SLOW_RC == 42 )) || fail "expected the builder to stop at the deadline (exit 42), got ${SLOW_RC}"
    [[ "$(result "${STATE}/out-deadline" status)" == deadline ]] || fail "status is not deadline"
    [[ "$(result "${STATE}/out-deadline" failed)" == 0 ]] \
      || fail "the interrupted package was reported as a build failure"
    grep -q 'dev-build/cmake' <<< "$(result "${STATE}/out-deadline" interrupted)" \
      || fail "the interrupted package is not reported: $(result "${STATE}/out-deadline" interrupted)"
    stored="$(result "${STATE}/out-deadline" ccache_stored)"
    (( stored > 0 )) || fail "nothing reached the compiler cache before the deadline"
    binhost publish --pkgdir /var/cache/binpkgs --merged "${STATE}/out-deadline/merged.txt" --final
    python3 - "${STORE}/index/Packages" <<'PY' || fail "an unfinished package was published"
import sys
sys.exit(1 if "CPV: dev-build/cmake-" in open(sys.argv[1]).read() else 0)
PY
    log "deadline phase passed: interrupted after ${stored} compiled file(s), nothing half-built published"
    ;;

  resume)
    [[ -f "${STATE}/out-deadline/result.env" ]] || fail "run the deadline phase first"
    serve
    slow_builder "${STATE}/out-resume" 5400 --tree-date "$(cat "${STATE}/out-deadline/tree-date")"
    (( SLOW_RC == 0 )) || fail "the builder exited ${SLOW_RC}"
    [[ "$(result "${STATE}/out-resume" status)" == complete ]] || fail "status is not complete"
    [[ "$(result "${STATE}/out-resume" failed)" == 0 ]] || fail "the package failed to build"
    stored="$(result "${STATE}/out-deadline" ccache_stored)"
    hits="$(result "${STATE}/out-resume" ccache_hits)"
    # A fresh container has to get back (nearly) everything the interrupted
    # run compiled; otherwise a package longer than one run never finishes.
    (( hits * 10 >= stored * 8 )) \
      || fail "only ${hits} compiler cache hit(s) for ${stored} file(s) compiled before the deadline"
    binhost --validate-cmd "python3 ${REPO}/scripts/portage-index.py check {}" \
      publish --pkgdir /var/cache/binpkgs --merged "${STATE}/out-resume/merged.txt" \
      --final --result "${STATE}/publish-resume.json"
    grep -q 'dev-build/cmake-' "${STATE}/publish-resume.json" || fail "cmake was not published"
    log "resume phase passed: ${hits} cache hit(s) for ${stored} file(s) compiled before the interruption"
    ;;

  drain)
    [[ -f "${KEYS}/secret.asc" ]] || fail "run the build phase first"
    serve
    # Compiled here whatever the binhosts offer; cmake with one job, so that
    # it is still building at the deadline on any machine.
    mkdir -p /etc/portage/package.use /etc/portage/env /etc/portage/package.env
    printf '%s\n' "dev-build/cmake -ncurses" "app-editors/nano minimal" "sys-apps/sed -nls" \
      > /etc/portage/package.use/zz-e2e-drain
    echo 'MAKEOPTS="-j1"' > /etc/portage/env/e2e-one-job.conf
    echo "dev-build/cmake e2e-one-job.conf" > /etc/portage/package.env/zz-e2e-drain
    DRAIN_RC=0
    bash "${REPO}/scripts/container-build.sh" --tiers drain --tiers-dir "${REPO}/tests/tiers" \
      --binhost-uri "$BINHOST_URI" --trust-key "${KEYS}/public.asc" \
      --sign-key "${KEYS}/secret.asc" --sign-passphrase "${KEYS}/passphrase" \
      --deadline "$(( $(date +%s) + DRAIN_TEST_SECONDS ))" --min-window 120 \
      --out "${STATE}/out-drain" 2>&1 | tee "${STATE}/drain.log" || DRAIN_RC=$?
    cat "${STATE}/out-drain/result.env"
    (( DRAIN_RC == 42 )) || fail "expected the builder to stop at the deadline (exit 42), got ${DRAIN_RC}"
    grep -q 'dev-build/cmake' <<< "$(result "${STATE}/out-drain" interrupted)" \
      || fail "cmake was not the package cut off: $(result "${STATE}/out-drain" interrupted)"
    grep -q 'finished package(s) before stopping' "${STATE}/drain.log" \
      || fail "no package was waiting to be installed at the deadline; the test did not exercise anything"
    # Without --pending-ok: nothing may be left built but not installed.
    binhost publish --pkgdir /var/cache/binpkgs --merged "${STATE}/out-drain/merged.txt" \
      --final --result "${STATE}/publish-drain.json" \
      || fail "packages that were finished at the deadline were not installed and published"
    for name in app-editors/nano- sys-apps/sed-; do
      grep -q "\"${name}" "${STATE}/publish-drain.json" || fail "${name}* was not published"
    done
    grep -q '"dev-build/cmake-' "${STATE}/publish-drain.json" && fail "an unfinished package was published"
    log "drain phase passed: packages finished next to a running build were installed and published"
    ;;

  *)
    echo "Usage: $0 build|rebuild|consume|deadline|resume|drain" >&2
    exit 1
    ;;
esac
