#!/usr/bin/env python3
"""Prune older versions from a binhost-style package directory.

For each (category, PN) found under the given root(s), keep only the
single newest version (by Gentoo PMS version comparison) and delete
older ``*.gpkg.tar`` files along with their matching ``.asc``
signatures.

Why this exists
---------------
GitHub Pages enforces a soft 1 GB site-size limit. Every bumped ebuild
that gets rebuilt leaves behind a stale ``.gpkg.tar`` in the cached
binhost layout — nothing on the binhost will ever serve those again, but
they keep the site growing until publish silently fails. Pruning to one
version per atom keeps the published site stable in size.

We deliberately re-implement PMS version comparison in pure Python so
this script can run in the publish job (ubuntu-latest, no Portage) as
well as inside the build container.
"""

from __future__ import annotations

import os
import re
import sys
from collections import defaultdict
from typing import Iterable

# ---------------------------------------------------------------------------
# Pure-Python PMS version comparison
# ---------------------------------------------------------------------------
# Reference: PMS (Package Manager Specification) §3.2 "Version comparison".
# Suffix order: _alpha < _beta < _pre < _rc < (none) < _p
_SUFFIX_ORDER = {"alpha": -4, "beta": -3, "pre": -2, "rc": -1, "p": 1}
# Sentinel for "no suffix" — sorts greater than any negative-ordered suffix
# (alpha/beta/pre/rc) and less than any positive-ordered one (_p).
_NO_SUFFIX_SENTINEL = (0, 0)
_VER_RE = re.compile(
    r"^(?P<main>\d+(?:\.\d+)*)"
    r"(?P<letter>[a-z])?"
    r"(?P<suffixes>(?:_(?:alpha|beta|pre|rc|p)\d*)*)"
    r"(?:-r(?P<rev>\d+))?$"
)


def _parse_version(ver: str) -> tuple | None:
    """Return a comparable tuple for ``ver``, or None if unparseable."""
    m = _VER_RE.match(ver)
    if not m:
        return None
    main = tuple(int(x) for x in m.group("main").split("."))
    letter = m.group("letter") or ""
    suffix_text = m.group("suffixes") or ""
    rev = int(m.group("rev") or 0)

    suffixes: list[tuple[int, int]] = []
    if suffix_text:
        for s in re.findall(r"_([a-z]+)(\d*)", suffix_text):
            kind, num = s
            order = _SUFFIX_ORDER.get(kind)
            if order is None:
                return None
            suffixes.append((order, int(num) if num else 0))
    else:
        suffixes.append(_NO_SUFFIX_SENTINEL)

    return (main, letter, tuple(suffixes), rev)


def _vercmp(a: str, b: str) -> int:
    """Return -1/0/1 for PMS comparison of ``a`` vs ``b``."""
    pa = _parse_version(a)
    pb = _parse_version(b)
    if pa is None or pb is None:
        # Unparseable: fall back to lexical comparison so we never silently
        # claim equality of two visibly different versions.
        return (a > b) - (a < b)
    return (pa > pb) - (pa < pb)


# ---------------------------------------------------------------------------
# Filename → (category, PN, version) split
# ---------------------------------------------------------------------------
# Matches the part *after* the category dir, so input is e.g. "qtbase-6.7.0"
# or "qtbase-6.7.0-r1". The PN may itself contain hyphens and digits, so we
# anchor on "-<digit>" to find the version boundary.
_PN_PV_RE = re.compile(r"^(?P<pn>.+?)-(?P<pv>\d[^-]*(?:-r\d+)?)$")


def _split_pn_pv(stem: str) -> tuple[str, str] | None:
    m = _PN_PV_RE.match(stem)
    if not m:
        return None
    return m.group("pn"), m.group("pv")


# ---------------------------------------------------------------------------
# Pruning
# ---------------------------------------------------------------------------
def prune(root: str) -> tuple[int, int]:
    """Prune ``root`` in place. Returns (files_removed, bytes_freed)."""
    if not os.path.isdir(root):
        return 0, 0

    # (category, pn) -> list of (version, full_path)
    groups: dict[tuple[str, str], list[tuple[str, str]]] = defaultdict(list)
    for dirpath, _dirnames, filenames in os.walk(root):
        for fn in filenames:
            if not fn.endswith(".gpkg.tar"):
                continue
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, root)
            parts = rel.split(os.sep)
            if len(parts) < 2:
                continue
            category = parts[0]
            stem = fn[: -len(".gpkg.tar")]
            split = _split_pn_pv(stem)
            if split is None:
                continue
            pn, pv = split
            groups[(category, pn)].append((pv, full))

    removed_files = 0
    removed_bytes = 0
    for (cat, pn), entries in groups.items():
        if len(entries) < 2:
            continue
        # Find newest by PMS vercmp.
        newest = entries[0]
        for cand in entries[1:]:
            if _vercmp(cand[0], newest[0]) > 0:
                newest = cand
        for pv, path in entries:
            if path == newest[1]:
                continue
            try:
                sz = os.path.getsize(path)
                os.remove(path)
                removed_files += 1
                removed_bytes += sz
                asc = path + ".asc"
                if os.path.exists(asc):
                    os.remove(asc)
            except OSError as e:
                print(f"[prune] failed to remove {path}: {e}", file=sys.stderr)
    return removed_files, removed_bytes


def main(argv: Iterable[str]) -> int:
    args = list(argv)
    if not args:
        print("Usage: prune-old-binpkgs.py <dir> [<dir>...]", file=sys.stderr)
        return 2
    total_files = 0
    total_bytes = 0
    for root in args:
        files, byts = prune(root)
        total_files += files
        total_bytes += byts
        print(
            f"[prune] {root}: removed {files} stale package(s), "
            f"freed {byts / 1024 / 1024:.1f} MiB"
        )
    print(
        f"[prune] total: removed {total_files} stale package(s), "
        f"freed {total_bytes / 1024 / 1024:.1f} MiB"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
