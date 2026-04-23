#!/usr/bin/env python3
"""wipe-caches.py — delete every GitHub Actions cache whose key starts with
one of the given prefixes, for use by the build workflow's `fresh: true`
dispatch option.

Invoked from .github/workflows/build-packages.yml when the workflow is
dispatched with `fresh: true` on attempt 1.  Triple-guarded there so it
cannot fire on schedule or on resume.

Pure stdlib by design: the build container is a Gentoo stage3 without jq,
and a `curl | python3` pipe through `mapfile` would let JSON-parse errors be
silently swallowed by process substitution.  `urllib.urlopen` raises
HTTPError on 4xx/5xx, which exits the interpreter non-zero and fails the
step — no `|| true`, no `2>/dev/null`, no swallowing.

Usage:
    GH_TOKEN=<token> REPO=<owner/name> wipe-caches.py <prefix> [<prefix> ...]
"""
from __future__ import annotations

import json
import os
import sys
import urllib.parse
import urllib.request


def api(method: str, path: str, token: str) -> bytes:
    req = urllib.request.Request(
        f"https://api.github.com{path}",
        method=method,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    with urllib.request.urlopen(req) as resp:
        return resp.read()


def delete_prefix(repo: str, prefix: str, token: str) -> int:
    """Delete every cache whose key starts with ``prefix``.

    Always re-fetch page 1 until empty: each iteration deletes every cache
    it sees, so subsequent fetches naturally shift forward.  Avoids the
    "delete-while-paginating" off-by-page bug where incrementing ``page``
    skips items.
    """
    deleted = 0
    while True:
        qs = urllib.parse.urlencode({"key": prefix, "per_page": "100"})
        body = api("GET", f"/repos/{repo}/actions/caches?{qs}", token)
        data = json.loads(body)
        caches = data.get("actions_caches", []) or []
        if not caches:
            break
        for c in caches:
            cid = c["id"]
            key = c["key"]
            ref = c.get("ref", "?")
            print(f"[fresh] DELETE id={cid} key={key} ref={ref}", flush=True)
            api("DELETE", f"/repos/{repo}/actions/caches/{cid}", token)
            deleted += 1
    print(f"[fresh] deleted {deleted} cache(s) with prefix {prefix!r}", flush=True)
    return deleted


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("Usage: wipe-caches.py <prefix> [<prefix> ...]", file=sys.stderr)
        return 2
    token = os.environ["GH_TOKEN"]
    repo = os.environ["REPO"]
    prefixes = argv[1:]
    grand_total = 0
    for prefix in prefixes:
        grand_total += delete_prefix(repo, prefix, token)
    print(
        f"[fresh] cache wipe complete — {grand_total} cache(s) deleted total",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
