#!/usr/bin/env python3
"""List installed packages that were built against a provider's old subslot.

A package records the subslot of every provider it was built against, for
example ``dev-libs/openssl:0/3=``.  When the provider moves to a new subslot
(``0/4``) and the consumer is only ever reinstalled from an older binary, the
binary index keeps offering a build of the consumer that pins the old
subslot.  A machine then cannot resolve the pair: one version of a package
cannot provide both subslots, so installing the consumer next to the new
provider blocks.

Portage's ``--binpkg-changed-deps`` does not catch this: the comparison runs
the dependency through ``strip_slots()``, which turns ``foo:0/3=`` into
``foo:=`` and so forgets the subslot that changed
(``portage/dep/_slot_operator.py``).

The builder runs this after its tiers and rebuilds what it prints from
source.  The fresh ``BUILD_TIME`` replaces the stale entry in the index.

Usage: stale_subslots.py [--root ROOT]

Prints one ``category/package`` per line, sorted.  Portage is imported lazily
so the pure helpers can be tested outside a Gentoo system.
"""

from __future__ import annotations

import argparse
import sys


def split_slot(slot):
    """``"0/4"`` -> ``("0", "4")``; a slot without a subslot is its own."""
    main, sep, sub = slot.partition("/")
    return main, (sub if sep else main)


def provider_index(installed):
    """Map ``(cp, slot)`` to the set of subslots installed for it.

    ``installed`` is an iterable of ``(cp, slot, subslot)`` triples.
    """
    index = {}
    for cp, slot, subslot in installed:
        index.setdefault((cp, slot), set()).add(subslot)
    return index


def stale_dependencies(dependencies, index):
    """Dependencies (``(cp, slot, subslot)``) whose provider moved on.

    A dependency without an explicit subslot (``:=``) says nothing about
    what it was built against, and a provider that is not installed at all
    is somebody else's problem: this only looks for a provider that is
    installed at a *different* subslot than the one the consumer pins.
    """
    stale = []
    for cp, slot, subslot in dependencies:
        if slot is None or subslot is None:
            continue
        available = index.get((cp, slot))
        if available and subslot not in available:
            stale.append((cp, slot, subslot))
    return stale


def stale_consumers(installed):
    """Return the ``category/package`` names that need a rebuild.

    ``installed`` maps a CPV to ``{"cp", "slot", "subslot", "deps"}`` where
    ``deps`` is a list of ``(cp, slot, subslot)``.  Every installed package
    is a provider for its own ``(cp, slot)``; every dependency that pins a
    subslot other than an installed one makes its package stale.
    """
    index = provider_index(
        (record["cp"], record["slot"], record["subslot"])
        for record in installed.values())
    consumers = set()
    for record in installed.values():
        if stale_dependencies(record["deps"], index):
            consumers.add(record["cp"])
    return sorted(consumers)


def read_installed(vardb, portage):
    """Read the installed database into the shape :func:`stale_consumers` wants."""
    installed = {}
    for cpv in vardb.cpv_all():
        slot, use, eapi, rdep, dep = vardb.aux_get(
            cpv, ["SLOT", "USE", "EAPI", "RDEPEND", "DEPEND"])
        main_slot, subslot = split_slot(slot)
        dependencies = []
        for metadata in (rdep, dep):
            try:
                reduced = portage.dep.use_reduce(
                    metadata, uselist=use.split(), eapi=eapi, flat=True)
            except Exception:
                # Unparseable metadata must not stop the scan: a package with
                # a dep the parser cannot read is not one we can judge here.
                reduced = metadata.split()
            for token in reduced:
                if token in ("||", "(", ")"):
                    continue
                try:
                    atom = portage.dep.Atom(token)
                except Exception:
                    continue
                if atom.slot_operator and atom.sub_slot is not None:
                    dependencies.append((atom.cp, atom.slot, atom.sub_slot))
        installed[cpv] = {
            "cp": portage.cpv_getkey(cpv),
            "slot": main_slot,
            "subslot": subslot,
            "deps": dependencies,
        }
    return installed


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default="/",
                        help="root of the installed system (default: /)")
    args = parser.parse_args(argv)

    import portage  # only available inside the build container

    vardb = portage.db[args.root]["vartree"].dbapi
    for cp in stale_consumers(read_installed(vardb, portage)):
        print(cp)
    return 0


if __name__ == "__main__":
    sys.exit(main())
