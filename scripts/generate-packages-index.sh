#!/usr/bin/env bash
# scripts/generate-packages-index.sh
#
# Regenerate the Packages index file for a binhost directory.
# Portage needs this file to find available binary packages.
#
# Usage:
#   generate-packages-index.sh <packages-dir>
#
# Example:
#   generate-packages-index.sh /var/www/binhost/amd64/23.0/desktop/plasma/openrc/x86-64-v3

set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[generate-packages-index.sh] $*"; }

PACKAGES_DIR="${1:-}"
[[ -n "$PACKAGES_DIR" ]] || die "Usage: $0 <packages-dir>"
[[ -d "$PACKAGES_DIR" ]] || die "Directory not found: ${PACKAGES_DIR}"

INDEX_FILE="${PACKAGES_DIR}/Packages"

log "Generating Packages index in: ${PACKAGES_DIR}"

# Use emaint if available (Gentoo container); otherwise fall back to a pure
# Python implementation that reproduces the parts of `emaint binhost --fix`
# that we actually need (the publish runner is ubuntu-latest, so neither
# emaint nor a fully-configured Portage installation is available there).
#
# The previous "elif python3 -c 'import portage'" branch invoked
# `bintree.inject_sequence(bintree.dbapi.cpv_all())`, but that method does
# not exist on `binarytree` (AttributeError) — it only ever silently worked
# because pip's standalone `portage` distribution is not installed on the
# publish runner, so the branch was never taken.  Removed to avoid
# masquerading as a working code path.
if command -v emaint &>/dev/null; then
  log "Using emaint binhost to generate index"
  PKGDIR="$PACKAGES_DIR" emaint binhost --fix
else
  log "Generating Packages index manually"

  # Manual fallback: generate the Packages index in pure Python so we can
  # parse <PF>-<BUILD_ID> filenames correctly (FEATURES="binpkg-multi-instance"
  # is enabled in this binhost's make.conf, which gives a 3-deep layout
  # <cat>/<pn>/<pf>-<build_id>.gpkg.tar).
  #
  # Validate every relative path against the canonical binhost layout
  #   <category>/<pn>/<pn>-<version>[-<build_id>].gpkg.tar
  # before emitting it.  Without this check, a single junk file at e.g.
  # ${PACKAGES_DIR}/tmp/artifacts/acct-group/cuse/cuse-0-1.gpkg.tar (which
  # has been observed leaking in from a buggy "Organise packages" step in
  # publish-to-pages.yml that fell through to the absolute artifact path)
  # ends up in the Packages index and Portage clients then die hard with
  #   portage.exception.InvalidData: tmp/artifacts/acct-group/cuse/cuse-0-1
  # the moment they try to populate from this binhost — taking down every
  # downstream build (including app-emulation/virtualbox-modules).  We also
  # have to emit CPV in the canonical "<category>/<PF>" (one-slash) form;
  # the previous shell-only fallback used "<cat>/<pn>/<pf>-<build_id>"
  # which Portage's _pkg_str() rejects with the same InvalidData crash.
  PACKAGES_DIR="$PACKAGES_DIR" INDEX_FILE="$INDEX_FILE" python3 - <<'PYEOF'
import hashlib
import os
import re
import sys
import time

PACKAGES_DIR = os.environ["PACKAGES_DIR"]
INDEX_FILE = os.environ["INDEX_FILE"]

# Gentoo category convention.
_CAT_RE = re.compile(r"^[a-z][a-z0-9-]*$")
# PMS-ish PF parser: <PN>-<PV>[-r<REV>]
# PV starts with a digit per PMS §3.2.
_PF_RE = re.compile(
    r"^(?P<pn>[A-Za-z0-9_+][A-Za-z0-9._+-]*?)"
    r"-(?P<pv>\d[A-Za-z0-9._+]*(?:_(?:alpha|beta|pre|rc|p)\d*)*)"
    r"(?:-r(?P<rev>\d+))?$"
)
# BUILD_ID is the trailing "-<digits>" added by FEATURES=binpkg-multi-instance.
_BUILD_ID_RE = re.compile(r"-(\d+)$")


def parse_basename(pn_dir, basename):
    """Return (pf, build_id_or_None) for ``basename`` (without .gpkg.tar)
    if it parses as a valid PF (optionally followed by -<BUILD_ID>),
    AND the parsed PN matches ``pn_dir``.  Otherwise return (None, None).
    """
    candidates = [(basename, None)]
    m = _BUILD_ID_RE.search(basename)
    if m:
        candidates.append((basename[: m.start()], m.group(1)))
    for pf, build_id in candidates:
        m = _PF_RE.match(pf)
        if m and m.group("pn") == pn_dir:
            return pf, build_id
    return None, None


def hash_file(path):
    # Portage uses MD5/SHA1 here strictly for binpkg integrity verification,
    # not for any security boundary, so request the FIPS-friendly variants.
    h_md5 = hashlib.md5(usedforsecurity=False)
    h_sha1 = hashlib.sha1(usedforsecurity=False)
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h_md5.update(chunk)
            h_sha1.update(chunk)
    return h_md5.hexdigest(), h_sha1.hexdigest()


# Collect all candidate gpkg paths under PACKAGES_DIR.
entries = []
invalid = []
for dirpath, _dirs, files in os.walk(PACKAGES_DIR):
    for fn in files:
        if not fn.endswith(".gpkg.tar"):
            continue
        full = os.path.join(dirpath, fn)
        rel = os.path.relpath(full, PACKAGES_DIR)
        parts = rel.split(os.sep)
        # Canonical layout is <cat>/<pn>/<basename>.gpkg.tar (3 parts).
        if len(parts) != 3:
            invalid.append((rel, "wrong directory depth"))
            continue
        cat, pn_dir, basename_full = parts
        if not _CAT_RE.match(cat):
            invalid.append((rel, f"invalid category {cat!r}"))
            continue
        stem = basename_full[: -len(".gpkg.tar")]
        pf, build_id = parse_basename(pn_dir, stem)
        if pf is None:
            invalid.append(
                (rel, f"basename {basename_full!r} does not parse as <pn>-<pv>[-r<rev>][-<build_id>] for parent PN {pn_dir!r}")
            )
            continue
        entries.append((cat, pn_dir, pf, build_id, full, rel))

# Sort deterministically for reproducible output.
entries.sort(key=lambda e: (e[0], e[1], e[2], int(e[3]) if e[3] else 0))

with open(INDEX_FILE, "w") as out:
    # Header — VERSION must be 0; see lib/portage/dbapi/bintree.py
    # (self._pkgindex_version = 0 and `int(version) <= self._pkgindex_version`).
    # VERSION: 1/2 are silently rejected with
    # "Binhost package index version is not supported: 'N'".
    out.write("ARCH: amd64\n")
    out.write("VERSION: 0\n")
    out.write(f"TIMESTAMP: {int(time.time())}\n")
    out.write("REPO: gentoo-binhost\n")
    out.write("\n")

    for cat, pn, pf, build_id, full, rel in entries:
        size = os.path.getsize(full)
        md5, sha1 = hash_file(full)
        # CPV is "<category>/<PF>" — exactly one slash.
        # PATH preserves the on-disk layout so clients can fetch the file.
        out.write(f"CPV: {cat}/{pf}\n")
        out.write(f"PATH: {rel}\n")
        if build_id is not None:
            out.write(f"BUILD_ID: {build_id}\n")
        out.write(f"SIZE: {size}\n")
        out.write(f"MD5: {md5}\n")
        out.write(f"SHA1: {sha1}\n")
        out.write("\n")

print(
    f"[generate-packages-index.sh] Wrote {len(entries)} package "
    f"entr{'y' if len(entries) == 1 else 'ies'} to {INDEX_FILE}",
    file=sys.stderr,
)
if invalid:
    print(
        f"[generate-packages-index.sh] WARNING: skipped {len(invalid)} "
        f"malformed binpkg path(s):",
        file=sys.stderr,
    )
    for rel, why in invalid:
        print(f"  - {rel}: {why}", file=sys.stderr)
PYEOF

  log "Packages index written to ${INDEX_FILE}"
fi

log "Done."
