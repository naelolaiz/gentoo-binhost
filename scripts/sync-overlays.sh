#!/usr/bin/env bash
# scripts/sync-overlays.sh — add the ebuild repositories listed in
# config/overlays.conf
#
# Usage:
#   sync-overlays.sh
#
# Each repository is downloaded as an archive of the head of its default
# branch (a stage3 has no git), unpacked to /var/db/repos/<name> and
# registered in /etc/portage/repos.conf/<name>.conf.  The entry has no
# sync-type, so `emerge --sync` leaves it alone.
#
# Skips a repository that is already there, so it is safe to call more than
# once.  A repository that cannot be fetched stops the caller: without it
# its packages do not resolve, and the builder would take the ones it has
# published for packages that left the tree, and prune them.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONF="${REPO_ROOT}/config/overlays.conf"
REPOS_DIR="/var/db/repos"

log() { echo "[sync-overlays.sh] $*"; }
die() { echo "::error::$*" >&2; exit 1; }

[[ -f "$CONF" ]] || { log "No ${CONF}; nothing to add"; exit 0; }

# fetch <GitHub URL> <directory>: unpack the archive of the default branch's
# head into <directory> and print the commit it was made from.
fetch() {
  python3 - "$1" "$2" <<'PY'
import io, os, sys, tarfile, time, urllib.request

url, dest = sys.argv[1], sys.argv[2]
archive = url.rstrip("/") + "/archive/HEAD.tar.gz"
for attempt in range(1, 4):
    try:
        with urllib.request.urlopen(archive, timeout=120) as response:
            data = response.read()
        break
    except OSError as error:
        print(f"{archive}: {error} (attempt {attempt})", file=sys.stderr)
        if attempt == 3:
            sys.exit(1)
        time.sleep(5 * attempt)

tmp = dest + ".tmp"
os.makedirs(tmp)
with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tar:
    members = []
    for member in tar.getmembers():
        # GitHub puts everything under one <repo>-<commit>/ directory.
        top, _, rest = member.name.partition("/")
        if not rest:
            continue
        member.name = rest
        members.append(member)
    extract = {"filter": "data"} if hasattr(tarfile, "data_filter") else {}
    tar.extractall(tmp, members=members, **extract)
    commit = tar.pax_headers.get("comment", "unknown commit")
os.rename(tmp, dest)
print(commit)
PY
}

mkdir -p /etc/portage/repos.conf
while read -r name url extra || [[ -n "${name:-}" ]]; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  [[ "$name" =~ ^[A-Za-z0-9_-]+$ && "$url" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ \
     && -z "$extra" ]] \
    || die "${CONF}: expected '<name> https://github.com/<owner>/<repo>', got: ${name} ${url} ${extra}"
  location="${REPOS_DIR}/${name}"
  if [[ -f "${location}/profiles/repo_name" ]]; then
    log "${name}: already present at ${location}"
  else
    rm -rf "$location" "${location}.tmp"
    commit="$(fetch "$url" "$location")" || die "Cannot download the ${name} repository from ${url}"
    log "${name}: ${url} at ${commit}"
  fi
  actual="$(cat "${location}/profiles/repo_name" 2>/dev/null || true)"
  [[ "$actual" == "$name" ]] || die "${url} is the repository '${actual}', not '${name}'"
  cat > "/etc/portage/repos.conf/${name}.conf" <<EOF
[${name}]
location = ${location}
EOF
done < "$CONF"
