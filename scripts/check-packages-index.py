#!/usr/bin/env python3
"""Validate a Portage Packages index on stdin.

Exits 0 if every CPV entry in the index is well-formed.
Exits 1 and prints each offending CPV to stderr if any entry is invalid.

A valid CPV has the form <category>/<PF> — exactly one slash — where
  category matches [a-z][a-z0-9-]* and
  PF      matches <PN>-<PV>[-r<REV>], i.e. the version starts with a digit.

Called by build-packages.yml "Install build tools" to guard against a
corrupt own-binhost Packages index before passing it to emerge.  A single
malformed CPV (e.g. "tmp/artifacts/acct-group/cuse/cuse-0-1", written by a
prior buggy publish run that deposited files at a non-canonical path) will
crash emerge with:
  portage.exception.InvalidData: tmp/artifacts/acct-group/cuse/cuse-0-1
which prevents the entire build chain from starting.
"""

import re
import sys

_CPV_RE = re.compile(
    r"^[a-z][a-z0-9-]*/[A-Za-z0-9_+][A-Za-z0-9._+-]*-\d[A-Za-z0-9._+-]*$"
)

bad = []
for line in sys.stdin:
    if line.startswith("CPV: "):
        cpv = line[5:].rstrip()
        if cpv.count("/") != 1 or not _CPV_RE.match(cpv):
            bad.append(cpv)

if bad:
    for cpv in bad:
        print(f"Malformed CPV in Packages index: {cpv!r}", file=sys.stderr)
    sys.exit(1)
