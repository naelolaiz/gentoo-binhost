#!/usr/bin/env python3
"""Index checks that need a real Portage; run inside a Gentoo container.

    portage-index.py check <Packages>
        Read the index with Portage's own reader and apply the checks a
        client applies before it trusts an entry.  A corrupt entry once made
        every client abort, so no index goes live without passing this.

    portage-index.py gone <Packages>
        Print the indexed packages whose ebuild is no longer in the tree.
"""

import sys

import portage
from portage.binpkg import get_binpkg_format
from portage.exception import PortageException
from portage.versions import _pkg_str


def read_index(path):
    bintree = portage.db[portage.root]["bintree"]
    index = bintree._new_pkgindex()
    with open(path, encoding="utf-8") as handle:
        index.read(handle)
    return bintree, index


def check(path):
    bintree, index = read_index(path)
    errors = []

    if not bintree._pkgindex_version_supported(index):
        errors.append(f"index VERSION {index.header.get('VERSION')!r} is not supported")
    if not index.header.get("TIMESTAMP"):
        errors.append("index has no TIMESTAMP")
    if not index.header.get("URI"):
        errors.append("index has no URI header")

    # Portage stops reading at the first empty stanza; make sure it saw
    # everything that is in the file.
    with open(path, encoding="utf-8") as handle:
        expected = sum(1 for line in handle if line.startswith("CPV: "))
    if expected != len(index.packages):
        errors.append(f"file has {expected} CPV entries but Portage read {len(index.packages)}")

    for entry in index.packages:
        cpv = entry.get("CPV")
        try:
            _pkg_str(cpv, metadata=entry, settings=bintree.settings, db=bintree.dbapi)
        except PortageException as error:
            errors.append(f"{cpv}: not a valid package: {error}")
            continue
        try:
            fmt = get_binpkg_format(entry.get("PATH"), remote=True)
        except PortageException as error:
            errors.append(f"{cpv}: {error}")
            continue
        if fmt != "gpkg":
            errors.append(f"{cpv}: PATH {entry.get('PATH')!r} is {fmt}, not gpkg")
        for key in ("BUILD_ID", "BUILD_TIME", "SIZE", "_mtime_"):
            try:
                int(entry[key])
            except (KeyError, ValueError):
                errors.append(f"{cpv}: {key} missing or not an integer")

    for error in errors:
        print(error, file=sys.stderr)
    if not errors:
        print(f"Portage accepts the index: {len(index.packages)} package(s)")
    return 1 if errors else 0


def gone(path):
    _, index = read_index(path)
    portdb = portage.db[portage.root]["porttree"].dbapi
    for entry in index.packages:
        cpv = entry.get("CPV")
        if cpv and not portdb.cpv_exists(cpv):
            print(cpv)
    return 0


def main(argv):
    if len(argv) != 3 or argv[1] not in ("check", "gone"):
        print(__doc__, file=sys.stderr)
        return 2
    return check(argv[2]) if argv[1] == "check" else gone(argv[2])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
