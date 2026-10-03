#!/usr/bin/env python3
"""Parse, merge and validate Portage binhost ``Packages`` indexes.

The published index is assembled from stanzas that Portage itself wrote into
the builder's ``PKGDIR/Packages``.  Stanzas are carried over verbatim: the only
keys this module ever writes are ``PATH`` (packages live in release assets, not
next to the index) and the two keys Portage elides when they equal the header
(``CHOST``/``REPO``), which are made explicit so a stanza keeps its meaning
when it is moved under a different header.

Package metadata (SLOT, USE, IUSE, dependencies, BUILD_TIME, ...) is never
synthesised here.  An earlier index generator did that and produced an index
no Portage client could use.

Pure standard library; no Portage import, so it runs on any CI host.
"""

from __future__ import annotations

import argparse
import re
import sys
import time

GPKG_SUFFIX = ".gpkg.tar"

# Keys Portage drops from a stanza when they equal the header value
# (lib/portage/dbapi/bintree.py: _pkgindex_inherited_keys, written through
# the "repository" -> "REPO" translation).
INHERITED_KEYS = ("CHOST", "REPO")

# Header keys this module owns.  Everything else is copied from the builder.
MANAGED_HEADER_KEYS = ("VERSION", "TIMESTAMP", "PACKAGES", "URI")

# Header keys that describe one particular builder run and would be wrong for
# stanzas merged in from earlier runs.
DROPPED_HEADER_KEYS = ("REPO_REVISIONS", "TTL", "DOWNLOAD_TIMESTAMP")

_CPV_RE = re.compile(
    r"^[A-Za-z0-9_][A-Za-z0-9+_.-]*/[A-Za-z0-9_][A-Za-z0-9+_.-]*-[0-9][A-Za-z0-9._-]*$"
)
_ASSET_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
_TAG_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
_INT_KEYS = ("BUILD_ID", "BUILD_TIME", "MTIME", "SIZE")
_HEX = {"MD5": 32, "SHA1": 40}


class PackageIndexError(Exception):
    """Raised for an index that cannot be parsed or merged safely."""


class Index:
    """A ``Packages`` file: one header mapping and a list of stanzas.

    Both are plain insertion-ordered dicts of str -> str.
    """

    def __init__(self, header=None, packages=None):
        self.header = dict(header or {})
        self.packages = [dict(p) for p in (packages or [])]

    def by_cpv(self):
        return {p["CPV"]: p for p in self.packages if "CPV" in p}

    def build_keys(self):
        return {build_key(p) for p in self.packages if "CPV" in p}


def build_key(stanza):
    """Identity of one build of one package."""
    return (stanza.get("CPV", ""), stanza.get("BUILD_TIME", ""))


def _parse_block(lines):
    block = {}
    for line in lines:
        key, sep, value = line.partition(":")
        if not sep or not key:
            # Portage's own reader skips lines without a "KEY:" prefix.
            continue
        # Portage writes "KEY: value"; an empty value is written as "KEY:".
        block[key] = value[1:] if value.startswith(" ") else value
    return block


def parse(text):
    """Parse index text into an :class:`Index`.

    The first block is the header; every later block is a package stanza.
    """
    blocks = []
    current = []
    for raw in text.splitlines():
        line = raw.rstrip("\r")
        if line.strip():
            current.append(line)
        elif current:
            blocks.append(current)
            current = []
    if current:
        blocks.append(current)
    if not blocks:
        raise PackageIndexError("empty index: no header")
    header = _parse_block(blocks[0])
    if "CPV" in header:
        raise PackageIndexError("index has no header (first block is a package)")
    packages = [_parse_block(b) for b in blocks[1:]]
    for pkg in packages:
        if "CPV" not in pkg:
            raise PackageIndexError(f"stanza without CPV: {sorted(pkg)[:4]}")
    return Index(header, packages)


def dump(index):
    """Serialise an :class:`Index`.

    Exactly one blank line separates blocks: Portage stops reading at the
    first empty stanza, so a doubled blank line would silently truncate the
    index for every client.
    """
    out = []
    for key, value in index.header.items():
        out.append(f"{key}: {value}" if value != "" else f"{key}:")
    out.append("")
    for pkg in index.packages:
        for key, value in pkg.items():
            out.append(f"{key}: {value}" if value != "" else f"{key}:")
        out.append("")
    # Every block, including the last, ends with a blank line (as Portage
    # writes it).
    return "\n".join(out) + "\n"


def sanitize(name):
    """Map a Gentoo name onto the alphabet GitHub keeps unchanged in asset
    and tag names (``[A-Za-z0-9._-]``).  ``+`` is the only other character
    Gentoo allows in category/package names."""
    return re.sub(r"[^A-Za-z0-9._-]", "_", name.replace("+", "_p_"))


def release_tag(cpv, tag_prefix):
    return tag_prefix + sanitize(cpv.split("/", 1)[0])


def asset_name(stanza, unique=False):
    """Asset file name for a stanza taken from the builder's PKGDIR.

    The default keeps Portage's own basename (``<PF>-<BUILD_ID>.gpkg.tar``):
    a gpkg stores its members under that basename, and Portage warns on every
    install when the file name differs.  ``unique=True`` adds BUILD_TIME and
    is only used when that name is already taken by another published build.
    """
    path = stanza.get("PATH", "")
    base = path.rsplit("/", 1)[-1]
    if not base.endswith(GPKG_SUFFIX):
        raise PackageIndexError(
            f"{stanza.get('CPV')}: PATH {path!r} is not a {GPKG_SUFFIX} file "
            "(the binhost only serves BINPKG_FORMAT=gpkg)"
        )
    stem = sanitize(base[: -len(GPKG_SUFFIX)])
    if unique:
        stem = f"{stem}.{stanza['BUILD_TIME']}"
    return stem + GPKG_SUFFIX


def localize(stanza, local_header, remote_path):
    """Return a self-contained copy of a PKGDIR stanza for the published index."""
    out = dict(stanza)
    out["PATH"] = remote_path
    for key in INHERITED_KEYS:
        if key not in out and local_header.get(key):
            out[key] = local_header[key]
    return out


def merge(remote, additions, local_header, uri, now=None):
    """Merge new stanzas into the remote index.

    ``additions`` is a list of stanzas already passed through
    :func:`localize`.  One stanza is kept per CPV; an addition replaces the
    published build of the same CPV.

    Returns ``(index, superseded_paths)`` where ``superseded_paths`` are the
    PATHs of replaced builds whose asset is no longer referenced.
    """
    now = int(time.time() if now is None else now)
    merged = remote.by_cpv()
    superseded = []
    for stanza in additions:
        old = merged.get(stanza["CPV"])
        if old is not None and old.get("PATH") != stanza["PATH"]:
            superseded.append(old["PATH"])
        merged[stanza["CPV"]] = stanza
    packages = [merged[cpv] for cpv in sorted(merged)]
    header = make_header(remote.header, local_header, uri, len(packages), now)
    return Index(header, packages), superseded


def remove(remote, cpvs, uri, now=None):
    """Drop the given CPVs.  Returns ``(index, removed_paths)``."""
    now = int(time.time() if now is None else now)
    doomed = set(cpvs)
    kept = [p for p in remote.packages if p["CPV"] not in doomed]
    removed = [p["PATH"] for p in remote.packages if p["CPV"] in doomed]
    header = make_header(remote.header, None, uri, len(kept), now)
    return Index(header, kept), removed


def make_header(remote_header, local_header, uri, count, now):
    """Header for a merged index.

    The builder's newest header wins (it describes the current build config);
    VERSION/TIMESTAMP/PACKAGES/URI are owned here.  TIMESTAMP must strictly
    increase or clients keep serving their cached copy.
    """
    base = dict(local_header) if local_header else dict(remote_header)
    for key in DROPPED_HEADER_KEYS + MANAGED_HEADER_KEYS:
        base.pop(key, None)
    try:
        previous = int(remote_header.get("TIMESTAMP", "0"))
    except ValueError:
        previous = 0
    header = {
        "VERSION": "0",
        "TIMESTAMP": str(max(int(now), previous + 1)),
        "PACKAGES": str(count),
        "URI": uri,
    }
    header.update(base)
    return header


def empty(uri, now=None):
    """A valid index with no packages (first publication)."""
    return Index(make_header({}, None, uri, 0, int(time.time() if now is None else now)), [])


def validate(index, tag_prefix, previous=None, allow_shrink=False):
    """Return a list of problems; empty means the index is publishable."""
    errors = []
    header = index.header

    if header.get("VERSION") != "0":
        errors.append(f"header VERSION must be 0, got {header.get('VERSION')!r}")
    timestamp = header.get("TIMESTAMP", "")
    if not timestamp.isdigit():
        errors.append(f"header TIMESTAMP missing or not an integer: {timestamp!r}")
    if not header.get("URI", "").startswith(("https://", "http://")):
        errors.append(f"header URI missing or not http(s): {header.get('URI')!r}")
    if header.get("PACKAGES") != str(len(index.packages)):
        errors.append(
            f"header PACKAGES={header.get('PACKAGES')!r} but index has "
            f"{len(index.packages)} stanza(s)"
        )
    for key in DROPPED_HEADER_KEYS:
        if key in header:
            errors.append(f"header must not carry {key}")

    if previous is not None:
        old_ts = previous.header.get("TIMESTAMP", "")
        if timestamp.isdigit() and old_ts.isdigit() and int(timestamp) <= int(old_ts):
            errors.append(f"TIMESTAMP {timestamp} does not increase over {old_ts}")
        if not allow_shrink and len(index.packages) < len(previous.packages):
            errors.append(
                f"index shrank from {len(previous.packages)} to "
                f"{len(index.packages)} package(s) outside a prune/evict"
            )

    seen_cpv = set()
    seen_path = set()
    for pkg in index.packages:
        cpv = pkg.get("CPV", "")
        errors.extend(validate_stanza(pkg, tag_prefix))
        if cpv in seen_cpv:
            errors.append(f"{cpv}: duplicate CPV")
        seen_cpv.add(cpv)
        path = pkg.get("PATH", "")
        if path in seen_path:
            errors.append(f"{cpv}: PATH {path!r} is used by another package")
        seen_path.add(path)
    return errors


def validate_stanza(pkg, tag_prefix):
    """Problems with one published stanza, independent of the rest."""
    cpv = pkg.get("CPV", "")
    where = cpv or "<stanza without CPV>"
    if not _CPV_RE.match(cpv):
        return [f"{where}: CPV is not <category>/<package>-<version>"]
    errors = []
    path = pkg.get("PATH", "")
    tag, sep, asset = path.partition("/")
    if (
        not sep
        or not _TAG_RE.match(tag)
        or not _ASSET_RE.match(asset)
        or not asset.endswith(GPKG_SUFFIX)
    ):
        errors.append(f"{where}: PATH {path!r} is not <tag>/<asset>{GPKG_SUFFIX}")
    elif tag != release_tag(cpv, tag_prefix):
        errors.append(
            f"{where}: PATH tag {tag!r} does not match {release_tag(cpv, tag_prefix)!r}"
        )
    for key in _INT_KEYS:
        if not pkg.get(key, "").isdigit():
            errors.append(f"{where}: {key} missing or not an integer")
    if pkg.get("SIZE", "").isdigit() and int(pkg["SIZE"]) <= 0:
        errors.append(f"{where}: SIZE must be positive")
    if not any(key in pkg for key in _HEX):
        errors.append(f"{where}: no MD5 or SHA1 digest")
    for key, length in _HEX.items():
        value = pkg.get(key)
        if value is not None and not re.fullmatch(rf"[0-9a-f]{{{length}}}", value):
            errors.append(f"{where}: {key} is not {length} hex digits")
    return errors


_PF_RE = re.compile(r"^(?P<pn>.+?)-(?P<pv>\d[A-Za-z0-9._]*)(?:-r\d+)?$")


def cp_of(cpv):
    """``category/PN`` of a CPV (``category/PN-version[-rN]``)."""
    category, _, pf = cpv.partition("/")
    match = _PF_RE.match(pf)
    return f"{category}/{match.group('pn') if match else pf}"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    check = sub.add_parser("validate", help="validate a published Packages file")
    check.add_argument("file")
    check.add_argument("--tag-prefix", required=True)
    args = parser.parse_args(argv)

    with open(args.file, encoding="utf-8") as handle:
        try:
            index = parse(handle.read())
        except PackageIndexError as exc:
            print(f"{args.file}: {exc}", file=sys.stderr)
            return 1
    errors = validate(index, args.tag_prefix)
    for error in errors:
        print(f"{args.file}: {error}", file=sys.stderr)
    if not errors:
        print(f"{args.file}: OK ({len(index.packages)} package(s))")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
