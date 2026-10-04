#!/usr/bin/env python3
"""Publish locally built Gentoo binary packages to the binhost.

Storage model
    index   one Portage ``Packages`` file plus ``state.json``.  On GitHub this
            is a git branch (served to clients through
            raw.githubusercontent.com); for tests it is a plain directory.
    assets  the ``.gpkg.tar`` files.  On GitHub these are release assets, one
            release per package category; for tests a directory tree.

The index header carries ``URI: <asset base>`` and each stanza a
``PATH: <release tag>/<asset name>``, which is how Portage is told that the
packages do not live next to the index.

Ordering rule: an asset is uploaded before the index refers to it, and deleted
only after the index stopped referring to it.  A client therefore never sees
an index entry without its file.

Standard library only, so it runs on the CI host without Portage.
"""

from __future__ import annotations

import argparse
import base64
import contextlib
import fcntl
import hashlib
import http.client
import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pkgindex  # noqa: E402

STATE_SCHEMA = 1
INDEX_FILE = "Packages"
STATE_FILE = "state.json"
# GitHub allows 1000 assets per release; stop short of it and continue in an
# overflow release of the same category (pkgs-<category>.2, ...).
MAX_ASSETS_PER_RELEASE = 950
MAX_RELEASES_PER_CATEGORY = 20
BOT_NAME = "github-actions[bot]"
BOT_EMAIL = "41898282+github-actions[bot]@users.noreply.github.com"

EXIT_OK = 0
EXIT_ERROR = 1
EXIT_LEFTOVER = 3

BRANCH_README = """\
# Gentoo binhost index

This branch is written by the build workflow.  Do not edit it by hand.

- `Packages` is the Portage binary package index.  Point a `binrepos.conf`
  `sync-uri` at the raw URL of this branch.
- `state.json` is bookkeeping for the builder.

The package files themselves are assets of this repository's releases.
"""


def log(message):
    # stderr: stdout is reserved for the JSON that state-get/status print.
    print(f"[binhost] {message}", file=sys.stderr, flush=True)


class PublishError(Exception):
    """The publication cannot proceed; nothing inconsistent was committed."""


class RateLimited(Exception):
    """The storage backend asked us to stop sending requests for now."""


class Snapshot:
    def __init__(self, text, state, token):
        self.text = text
        self.state = state
        self.token = token


def new_state():
    return {"schema": STATE_SCHEMA, "superseded": []}


def load_state(raw):
    state = json.loads(raw) if raw else {}
    if state.get("schema", STATE_SCHEMA) != STATE_SCHEMA:
        raise PublishError(f"state.json has unsupported schema {state.get('schema')!r}")
    merged = new_state()
    merged.update(state)
    return merged


def dump_state(state):
    return json.dumps(state, indent=1, sort_keys=True) + "\n"


def add_superseded(state, paths, at):
    """Queue files for deletion by a later prune.  One entry per path; a path
    that is queued again starts its grace period again."""
    entries = {item["path"]: item["at"] for item in state.get("superseded", [])}
    for path in paths:
        entries[path] = at
    state["superseded"] = [{"path": path, "at": entries[path]} for path in sorted(entries)]


def digest(*texts):
    joined = "\0".join("" if text is None else text for text in texts)
    return hashlib.sha256(joined.encode()).hexdigest()


# --------------------------------------------------------------------------
# Directory backend (tests and local end-to-end runs)
# --------------------------------------------------------------------------
class DirStore:
    """Index in ``<root>/index``, assets in ``<root>/assets/<tag>/<name>``."""

    def __init__(self, root, uri):
        self.root = root
        self.uri = uri
        self.deadline = None
        self.index_dir = os.path.join(root, "index")
        self.assets_dir = os.path.join(root, "assets")

    def _read(self, name):
        path = os.path.join(self.index_dir, name)
        if not os.path.exists(path):
            return None
        with open(path, encoding="utf-8") as handle:
            return handle.read()

    def _token(self):
        text = self._read(INDEX_FILE)
        return None if text is None else digest(text, self._read(STATE_FILE))

    def load(self):
        return Snapshot(self._read(INDEX_FILE), load_state(self._read(STATE_FILE)),
                        self._token())

    def commit(self, token, files, message):
        if self._token() != token:
            return None
        os.makedirs(self.index_dir, exist_ok=True)
        for name, content in files.items():
            tmp = os.path.join(self.index_dir, f".{name}.tmp")
            with open(tmp, "w", encoding="utf-8") as handle:
                handle.write(content)
            os.replace(tmp, os.path.join(self.index_dir, name))
        log(f"index written: {message}")
        return self._token()

    def list_assets(self, tag):
        directory = os.path.join(self.assets_dir, tag)
        if not os.path.isdir(directory):
            return {}
        return {
            name: os.path.getsize(os.path.join(directory, name))
            for name in os.listdir(directory)
        }

    def upload(self, tag, name, path):
        directory = os.path.join(self.assets_dir, tag)
        os.makedirs(directory, exist_ok=True)
        tmp = os.path.join(directory, f".{name}.tmp")
        shutil.copyfile(path, tmp)
        os.replace(tmp, os.path.join(directory, name))

    def delete_asset(self, tag, name):
        with contextlib.suppress(FileNotFoundError):
            os.remove(os.path.join(self.assets_dir, tag, name))


# --------------------------------------------------------------------------
# GitHub backend
# --------------------------------------------------------------------------
class GitHubStore:
    """Index on a git branch, assets in per-category releases."""

    def __init__(self, repo, branch, token, workdir, *, api=None, uploads=None,
                 git_url=None, uri=None, pause=1.0):
        self.repo = repo
        self.branch = branch
        self.token = token
        self.workdir = workdir
        self.api = (api or "https://api.github.com").rstrip("/")
        self.uploads = (uploads or "https://uploads.github.com").rstrip("/")
        self.git_url = git_url or f"https://github.com/{repo}.git"
        self.uri = uri or f"https://github.com/{repo}/releases/download"
        # GitHub asks for at least one second between mutating requests.
        self.pause = pause
        # Epoch after which no further request is started (set by publish).
        self.deadline = None
        self._releases = {}
        self.requests = 0

    # ---- git -------------------------------------------------------------
    def _git(self, args, cwd=None, check=True):
        cmd = ["git"]
        if self.token and self.git_url.startswith("https://"):
            basic = base64.b64encode(f"x-access-token:{self.token}".encode()).decode()
            cmd += ["-c", f"http.extraheader=AUTHORIZATION: basic {basic}"]
        cmd += ["-c", f"user.name={BOT_NAME}", "-c", f"user.email={BOT_EMAIL}"]
        cmd += args
        env = dict(os.environ, GIT_TERMINAL_PROMPT="0")
        result = subprocess.run(cmd, cwd=cwd, env=env, text=True, capture_output=True)
        if check and result.returncode != 0:
            raise PublishError(f"git {args[0]} failed: {result.stderr.strip()}")
        return result

    def load(self):
        heads = self._git(["ls-remote", "--heads", self.git_url, self.branch]).stdout
        if not heads.strip():
            return Snapshot(None, new_state(), None)
        clone = tempfile.mkdtemp(prefix="index-", dir=self.workdir)
        self._git(["clone", "--quiet", "--depth", "1", "--single-branch",
                   "--branch", self.branch, self.git_url, clone])
        head = self._git(["rev-parse", "HEAD"], cwd=clone).stdout.strip()

        def read(name):
            path = os.path.join(clone, name)
            if not os.path.exists(path):
                return None
            with open(path, encoding="utf-8") as handle:
                return handle.read()

        return Snapshot(read(INDEX_FILE), load_state(read(STATE_FILE)),
                        {"dir": clone, "head": head})

    def commit(self, token, files, message):
        if token is None:
            clone = tempfile.mkdtemp(prefix="index-", dir=self.workdir)
            self._git(["init", "--quiet"], cwd=clone)
            self._git(["checkout", "--quiet", "--orphan", self.branch], cwd=clone)
            self._git(["remote", "add", "origin", self.git_url], cwd=clone)
            files = dict(files, **{"README.md": BRANCH_README})
        else:
            clone = token["dir"]
        for name, content in files.items():
            with open(os.path.join(clone, name), "w", encoding="utf-8") as handle:
                handle.write(content)
        # Clients try Packages.gz before Packages; a stale one would win.
        with contextlib.suppress(FileNotFoundError):
            os.remove(os.path.join(clone, INDEX_FILE + ".gz"))
        self._git(["add", "--all"], cwd=clone)
        if self._git(["diff", "--cached", "--quiet"], cwd=clone, check=False).returncode == 0:
            return token["head"] if token else None
        self._git(["commit", "--quiet", "-m", message], cwd=clone)
        push = self._git(["push", "--quiet", "origin", f"HEAD:refs/heads/{self.branch}"],
                         cwd=clone, check=False)
        if push.returncode != 0:
            stderr = push.stderr.lower()
            # Someone else pushed first.  "[remote rejected]" (a protected
            # branch, a hook) is not that and retrying would not help.
            if "[rejected]" in stderr and ("fetch first" in stderr
                                           or "non-fast-forward" in stderr):
                return None
            raise PublishError(f"git push failed: {push.stderr.strip()}")
        return self._git(["rev-parse", "HEAD"], cwd=clone).stdout.strip()

    # ---- REST ------------------------------------------------------------
    def _request(self, method, url, *, payload=None, upload=None, timeout=60):
        headers = {
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "gentoo-binhost-publisher",
        }
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        last_error = None
        for attempt in range(4):
            if self.deadline is not None:
                left = self.deadline - time.time()
                if left <= 0:
                    raise PublishError("the publish deadline passed")
                # A stalled connection must not outlive the deadline by much.
                timeout = max(30, min(timeout, left))
            data = None
            handle = None
            if payload is not None:
                data = json.dumps(payload).encode()
                headers["Content-Type"] = "application/json"
            elif upload is not None:
                handle = open(upload, "rb")
                data = handle
                headers["Content-Type"] = "application/octet-stream"
                headers["Content-Length"] = str(os.path.getsize(upload))
            request = urllib.request.Request(url, data=data, method=method, headers=headers)
            self.requests += 1
            try:
                with urllib.request.urlopen(request, timeout=timeout) as response:
                    body = response.read()
                    status = response.status
                try:
                    return status, (json.loads(body) if body else None)
                except ValueError:
                    raise PublishError(f"{method} {url}: unreadable answer") from None
            except urllib.error.HTTPError as error:
                body = error.read().decode(errors="replace")
                if error.code in (403, 429) and self._is_rate_limit(error, body):
                    raise RateLimited(body[:200]) from None
                if error.code >= 500:
                    last_error = f"HTTP {error.code}: {body[:200]}"
                else:
                    with contextlib.suppress(ValueError):
                        return error.code, json.loads(body)
                    return error.code, {"message": body[:200]}
            except (OSError, http.client.HTTPException) as error:
                # Everything the network can throw while sending or reading,
                # TLS errors and truncated answers included.
                last_error = f"{type(error).__name__}: {error}"
            finally:
                if handle is not None:
                    handle.close()
                if method != "GET" and self.pause:
                    time.sleep(self.pause)
            time.sleep(min(2 ** attempt, 8) * (1 if self.pause else 0))
        raise PublishError(f"{method} {url} failed after retries: {last_error}")

    @staticmethod
    def _is_rate_limit(error, body):
        headers = error.headers
        return (
            headers.get("retry-after") is not None
            or headers.get("x-ratelimit-remaining") == "0"
            or "rate limit" in body.lower()
        )

    def _release(self, tag, create):
        if tag in self._releases:
            return self._releases[tag]
        quoted = urllib.parse.quote(tag, safe="")
        status, body = self._request("GET", f"{self.api}/repos/{self.repo}/releases/tags/{quoted}")
        if status == 404:
            if not create:
                return None
            status, body = self._request(
                "POST", f"{self.api}/repos/{self.repo}/releases",
                payload={
                    "tag_name": tag,
                    # The tag only anchors the release.  On the index branch
                    # it does not pin a commit of the code's history.
                    "target_commitish": self.branch,
                    "name": tag,
                    "body": "Binary packages, managed by the build workflow. "
                            "Do not edit; files are referenced by the package index.",
                    "prerelease": True,
                    "make_latest": "false",
                },
            )
            if status == 422:
                # A retried request whose first attempt did get through.
                status, body = self._request(
                    "GET", f"{self.api}/repos/{self.repo}/releases/tags/{quoted}")
                if status != 200:
                    raise PublishError(f"cannot create release {tag}: {status} {body}")
            elif status != 201:
                raise PublishError(f"cannot create release {tag}: {status} {body}")
            else:
                log(f"created release {tag}")
        elif status != 200:
            raise PublishError(f"cannot read release {tag}: {status} {body}")
        if body.get("immutable"):
            raise PublishError(
                f"release {tag} is immutable; disable 'immutable releases' in the "
                "repository settings, assets must be added over time"
            )
        self._releases[tag] = {"id": body["id"], "assets": None}
        return self._releases[tag]

    def _assets(self, tag, create=False):
        release = self._release(tag, create)
        if release is None:
            return None
        if release["assets"] is None:
            assets = {}
            page = 1
            while True:
                status, body = self._request(
                    "GET",
                    f"{self.api}/repos/{self.repo}/releases/{release['id']}/assets"
                    f"?per_page=100&page={page}",
                )
                if status != 200:
                    raise PublishError(f"cannot list assets of {tag}: {status} {body}")
                for asset in body:
                    assets[asset["name"]] = asset
                if len(body) < 100:
                    break
                page += 1
            release["assets"] = assets
        return release["assets"]

    def list_assets(self, tag):
        assets = self._assets(tag)
        return {name: asset.get("size", 0) for name, asset in (assets or {}).items()}

    def upload(self, tag, name, path):
        assets = self._assets(tag, create=True)
        release = self._releases[tag]
        size = os.path.getsize(path)
        url = (f"{self.uploads}/repos/{self.repo}/releases/{release['id']}/assets"
               f"?name={urllib.parse.quote(name, safe='')}")
        for attempt in range(3):
            status, body = self._request("POST", url, upload=path, timeout=300 + size // 2**20)
            if status == 201:
                # GitHub renames assets containing characters it dislikes; the
                # index must only ever point at the name that really exists.
                if body.get("name") != name or body.get("size") != size:
                    self._request("DELETE",
                                  f"{self.api}/repos/{self.repo}/releases/assets/{body['id']}")
                    raise PublishError(
                        f"asset {tag}/{name} was stored as {body.get('name')!r} with "
                        f"{body.get('size')} bytes (expected {size}); removed it again"
                    )
                assets[name] = body
                return
            if status == 422:
                # A failed earlier attempt can leave the name reserved.
                release["assets"] = None
                assets = self._assets(tag)
                if name in assets:
                    self.delete_asset(tag, name)
                    continue
            raise PublishError(f"upload of {tag}/{name} failed: {status} {body}")
        raise PublishError(f"upload of {tag}/{name} kept colliding with an existing asset")

    def delete_asset(self, tag, name):
        assets = self._assets(tag)
        if not assets or name not in assets:
            return
        status, body = self._request(
            "DELETE", f"{self.api}/repos/{self.repo}/releases/assets/{assets[name]['id']}")
        if status not in (204, 404):
            raise PublishError(f"cannot delete asset {tag}/{name}: {status} {body}")
        del assets[name]


# --------------------------------------------------------------------------
# Publishing
# --------------------------------------------------------------------------
def read_lines(path):
    if not path or not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as handle:
        return [line.split("#", 1)[0].strip() for line in handle if line.split("#", 1)[0].strip()]


def read_merged(path):
    """``<cat>/<pf> <BUILD_TIME>`` lines written by the builder for every
    package that is really installed in its image."""
    if not path:
        return None
    merged = set()
    for line in read_lines(path):
        parts = line.split()
        if len(parts) == 2:
            merged.add((parts[0], parts[1]))
    return merged


def run_validator(command, text):
    """Let real Portage parse the candidate index before it goes live."""
    if not command:
        return
    with tempfile.NamedTemporaryFile("w", suffix="-Packages", delete=False,
                                     encoding="utf-8") as handle:
        handle.write(text)
        path = handle.name
    os.chmod(path, 0o644)
    try:
        argv = [part.replace("{}", path) for part in shlex.split(command)]
        result = subprocess.run(argv, text=True, capture_output=True)
        if result.returncode != 0:
            raise PublishError(
                "Portage rejected the candidate index:\n"
                + (result.stdout + result.stderr).strip()
            )
    finally:
        os.unlink(path)


def commit_index(store, snapshot, build, message, validate_cmd, tag_prefix, allow_shrink=False):
    """Apply ``build(remote_index, state) -> (index, state)`` and push it,
    re-applying on top of a concurrent update if the push is rejected."""
    for _ in range(4):
        remote = (pkgindex.parse(snapshot.text) if snapshot.text is not None
                  else pkgindex.empty(store.uri))
        index, state = build(remote, json.loads(json.dumps(snapshot.state)))
        if index is remote and snapshot.text is not None:
            # Only the builder state changed; leave the index byte-identical
            # so clients do not re-download it.
            text = snapshot.text
        else:
            previous = remote if snapshot.text is not None else None
            errors = pkgindex.validate(index, tag_prefix, previous=previous,
                                       allow_shrink=allow_shrink)
            if errors:
                raise PublishError(
                    "refusing to publish an invalid index:\n  " + "\n  ".join(errors))
            text = pkgindex.dump(index)
            run_validator(validate_cmd, text)
        head = store.commit(snapshot.token, {INDEX_FILE: text, STATE_FILE: dump_state(state)},
                            message)
        if head is not None:
            return index, head
        log("index changed underneath us; re-applying on top of the new one")
        snapshot = store.load()
    raise PublishError("could not push the index after repeated conflicts")


def pick_slot(store, stanza, base_tag, taken):
    """Where a new file goes: ``(tag, name)`` in the category's release, or
    in the first of its overflow releases that has room.  None if there is
    no room anywhere."""
    for number in range(1, MAX_RELEASES_PER_CATEGORY + 1):
        tag = pkgindex.overflow_tag(base_tag, number)
        name = pkgindex.asset_name(stanza)
        if f"{tag}/{name}" in taken:
            name = pkgindex.asset_name(stanza, unique=True)
            if f"{tag}/{name}" in taken:
                continue
        assets = store.list_assets(tag)
        if name in assets:
            # Leftover of an earlier attempt that never reached the index.
            store.delete_asset(tag, name)
            return tag, name
        if len(assets) < MAX_ASSETS_PER_RELEASE:
            return tag, name
    return None


def publish(store, args):
    result = {"published": [], "skipped": {}, "pending": [], "leftover": [],
              "rate_limited": False}
    local_path = os.path.join(args.pkgdir, INDEX_FILE)
    snapshot = store.load()
    remote = (pkgindex.parse(snapshot.text) if snapshot.text is not None
              else pkgindex.empty(store.uri))

    local = None
    if os.path.exists(local_path):
        with open(local_path, encoding="utf-8") as handle:
            local = pkgindex.parse(handle.read())

    merged = read_merged(args.merged)
    no_publish = set(read_lines(args.no_publish))
    have = remote.build_keys()
    # Names that must not be reused: files the index points at, and replaced
    # files that clients holding an older index may still ask for.
    taken = {pkg.get("PATH") for pkg in remote.packages}
    taken |= {item["path"] for item in snapshot.state.get("superseded", [])}
    additions = []
    deadline = float(args.deadline) if args.deadline else None
    store.deadline = deadline

    # PKGDIR can hold several builds of one package version (a rebuild within
    # the same run); only the newest one counts.
    newest = {}
    for stanza in (local.packages if local else []):
        known = newest.get(stanza["CPV"])
        if known is None or int(stanza.get("BUILD_TIME") or 0) > int(known.get("BUILD_TIME") or 0):
            newest[stanza["CPV"]] = stanza

    candidates = []
    for stanza in newest.values():
        cpv = stanza["CPV"]
        if pkgindex.build_key(stanza) in have:
            continue
        path = os.path.join(args.pkgdir, stanza.get("PATH", ""))
        if "bindist" in stanza.get("RESTRICT", "").split():
            result["skipped"][cpv] = "RESTRICT=bindist (not redistributable)"
        elif pkgindex.cp_of(cpv) in no_publish:
            result["skipped"][cpv] = "listed in the no-publish file"
        elif not os.path.isfile(path):
            result["skipped"][cpv] = "package file missing from PKGDIR"
        elif str(os.path.getsize(path)) != stanza.get("SIZE"):
            result["pending"].append(cpv)
        elif merged is not None and pkgindex.build_key(stanza) not in merged:
            # Built, but not (yet) installed in the builder: Portage writes
            # the binpkg before merging, and a package whose merge failed
            # must not be offered to anyone.
            result["pending"].append(cpv)
        else:
            candidates.append((stanza, path))
    candidates.sort(key=lambda item: int(item[0].get("BUILD_TIME", "0") or 0))

    for stanza, path in candidates:
        cpv = stanza["CPV"]
        if deadline is not None and time.time() > deadline:
            log("publish deadline reached; the rest stays for the next pass")
            break
        try:
            base_tag = pkgindex.release_tag(cpv, args.tag_prefix)
            slot = pick_slot(store, stanza, base_tag, taken)
            if slot is None:
                result["skipped"][cpv] = (
                    f"no room in release {base_tag} or its "
                    f"{MAX_RELEASES_PER_CATEGORY - 1} overflow releases"
                )
                continue
            tag, name = slot
            entry = pkgindex.localize(stanza, local.header, f"{tag}/{name}")
            problems = pkgindex.validate_stanza(entry, args.tag_prefix)
            if problems:
                result["skipped"][cpv] = "; ".join(problems)
                continue
            store.upload(tag, name, path)
        except RateLimited as limit:
            log(f"rate limited by the storage backend: {limit}")
            result["rate_limited"] = True
            break
        except pkgindex.PackageIndexError as error:
            result["skipped"][cpv] = str(error)
            continue
        except PublishError as error:
            # One bad upload must not cost the packages uploaded before it.
            result["skipped"][cpv] = f"upload failed: {error}"
            continue
        additions.append(entry)
        log(f"uploaded {cpv} -> {tag}/{name}")

    head = snapshot.token["head"] if isinstance(snapshot.token, dict) else snapshot.token
    index = remote
    if additions or snapshot.text is None:
        def build(current, state):
            fresh = [a for a in additions
                     if pkgindex.build_key(a) not in current.build_keys()]
            new_index, superseded = pkgindex.merge(
                current, fresh, local.header if local else None, store.uri)
            add_superseded(state, superseded, int(time.time()))
            return new_index, state

        index, head = commit_index(
            store, snapshot, build, f"Update package index (+{len(additions)})",
            args.validate_cmd, args.tag_prefix)
        result["published"] = [a["CPV"] for a in additions]

    published = set(result["published"])
    result["leftover"] = sorted(
        {s["CPV"] for s, _ in candidates} - published | set(result["pending"]))
    result["head"] = head
    result["timestamp"] = index.header.get("TIMESTAMP")
    result["packages"] = len(index.packages)
    if args.result:
        with open(args.result, "w", encoding="utf-8") as handle:
            json.dump(result, handle, indent=1, sort_keys=True)
    log(f"published {len(result['published'])}, skipped {len(result['skipped'])}, "
        f"left {len(result['leftover'])}; index now lists {result['packages']} package(s)")
    for cpv, reason in sorted(result["skipped"].items()):
        log(f"  skipped {cpv}: {reason}")
    if not args.final:
        return EXIT_OK
    # A build that was stopped leaves packages that are built but not
    # installed.  That is not a publishing problem; the next run builds them.
    excused = set(result["pending"]) if args.pending_ok else set()
    for cpv in sorted(excused):
        log(f"  not installed when the build stopped, left for the next run: {cpv}")
    unpublished = [cpv for cpv in result["leftover"] if cpv not in excused]
    for cpv in unpublished:
        log(f"  NOT PUBLISHED: {cpv}")
    return EXIT_LEFTOVER if unpublished else EXIT_OK


def delete_files(store, paths):
    """Delete files; returns the ones that could not be deleted."""
    for position, path in enumerate(paths):
        tag, _, name = path.partition("/")
        try:
            store.delete_asset(tag, name)
        except (RateLimited, PublishError) as error:
            log(f"could not delete {path}: {error}")
            return paths[position:]
        log(f"deleted {path}")
    return []


def requeue(store, paths, args):
    """Put files whose deletion failed back on the list, due immediately."""
    if not paths:
        return

    def build(current, state):
        add_superseded(state, paths, 0)
        return current, state

    commit_index(store, store.load(), build, "Keep track of files still to delete",
                 args.validate_cmd, args.tag_prefix)
    log(f"{len(paths)} file(s) stay queued for the next prune")


def evict(store, args):
    """Remove packages from the index.

    Their files are deleted by a later prune, like any replaced file: a
    client that fetched the index a moment ago may still ask for them.
    ``--now`` deletes them at once, for a file that must not stay available.
    """
    snapshot = store.load()
    if snapshot.text is None:
        raise PublishError("no index published yet")
    removed = []

    def build(current, state):
        if not any(pkg["CPV"] in args.cpv for pkg in current.packages):
            removed[:] = []
            return current, state
        index, paths = pkgindex.remove(current, args.cpv, store.uri)
        removed[:] = paths
        if not args.now:
            add_superseded(state, paths, int(time.time()))
        return index, state

    commit_index(store, snapshot, build, f"Remove {len(args.cpv)} package(s) from the index",
                 args.validate_cmd, args.tag_prefix, allow_shrink=True)
    for path in removed:
        log(f"removed {path} from the index")
    if not removed:
        log("nothing matched")
    if args.now:
        requeue(store, delete_files(store, removed), args)
    return EXIT_OK


def stored_files(store, snapshot):
    """``<tag>/<name>`` of every file in the releases the index or the
    deletion queue mention.  Empty if they cannot be listed right now."""
    paths = [pkg.get("PATH", "") for pkg in pkgindex.parse(snapshot.text).packages]
    paths += [item["path"] for item in snapshot.state.get("superseded", [])]
    found = set()
    try:
        for tag in sorted({path.partition("/")[0] for path in paths if "/" in path}):
            found |= {f"{tag}/{name}" for name in store.list_assets(tag)}
    except (RateLimited, PublishError) as error:
        log(f"could not list the stored files, not looking for unreferenced ones: {error}")
        return set()
    return found


def prune(store, args):
    """Drop packages whose ebuild left the tree, and delete files the index
    stopped referring to, both only after a grace period."""
    snapshot = store.load()
    if snapshot.text is None:
        return EXIT_OK
    now = int(time.time())
    gone_now = set(read_lines(args.gone)) if args.gone else None
    grace = args.grace_days * 86400
    doomed_paths = []
    stored = stored_files(store, snapshot)

    def build(current, state):
        doomed_paths.clear()
        first_seen = dict(state.get("gone", {}))
        if gone_now is not None:
            present = {p["CPV"] for p in current.packages}
            first_seen = {cpv: first_seen.get(cpv, now) for cpv in gone_now & present}
        # Without a fresh --gone list nothing is known about the tree, so
        # nothing may expire.
        expired = [] if gone_now is None else [
            cpv for cpv, since in first_seen.items() if now - since >= grace]
        index, removed = current, []
        if expired:
            index, removed = pkgindex.remove(current, expired, store.uri)
        for cpv in expired:
            first_seen.pop(cpv, None)
        referenced = {p["PATH"] for p in index.packages}
        keep = []
        for item in state.get("superseded", []):
            if item["path"] in referenced:
                continue
            if now - item["at"] >= grace:
                doomed_paths.append(item["path"])
            # A file stays on the list until it is really deleted (below).
            keep.append(item)
        state["superseded"] = keep
        # Files of packages dropped just now wait one more grace period:
        # clients may still hold the index that lists them.
        add_superseded(state, removed, now)
        # Files nothing refers to (an upload whose index update never
        # happened) are queued like replaced ones.
        queued = {item["path"] for item in state["superseded"]}
        add_superseded(state, sorted(stored - referenced - queued), now)
        state["gone"] = first_seen
        return index, state

    commit_index(store, snapshot, build, "Prune package index", args.validate_cmd,
                 args.tag_prefix, allow_shrink=True)
    failed = set(delete_files(store, doomed_paths))
    deleted = {path for path in doomed_paths if path not in failed}
    log(f"prune deleted {len(deleted)} file(s)")
    if failed:
        log(f"{len(failed)} file(s) stay queued for the next prune")
    if deleted:
        # Only now are they forgotten: had this run died while deleting, the
        # next prune would have found them still on the list.
        def forget(current, state):
            state["superseded"] = [item for item in state.get("superseded", [])
                                   if item["path"] not in deleted]
            return current, state

        commit_index(store, store.load(), forget, "Forget deleted package files",
                     args.validate_cmd, args.tag_prefix)
    return EXIT_OK


def state_get(store, args):
    state = store.load().state
    value = state.get(args.key) if args.key else state
    print(json.dumps(value, sort_keys=True))
    return EXIT_OK


def state_set(store, args):
    value = json.loads(args.json)
    snapshot = store.load()

    def build(current, state):
        if value is None:
            state.pop(args.key, None)
        else:
            state[args.key] = value
        return current, state

    commit_index(store, snapshot, build, f"Update builder state ({args.key})",
                 args.validate_cmd, args.tag_prefix)
    return EXIT_OK


def status(store, args):
    snapshot = store.load()
    if snapshot.text is None:
        print(json.dumps({"published": False}))
        return EXIT_OK
    index = pkgindex.parse(snapshot.text)
    head = snapshot.token["head"] if isinstance(snapshot.token, dict) else snapshot.token
    print(json.dumps({
        "published": True,
        "head": head,
        "packages": len(index.packages),
        "timestamp": index.header.get("TIMESTAMP"),
        "errors": pkgindex.validate(index, args.tag_prefix),
    }, sort_keys=True))
    return EXIT_OK


def init(store, args):
    snapshot = store.load()
    if snapshot.text is not None:
        log("index already exists")
        return EXIT_OK
    commit_index(store, snapshot, lambda current, state: (current, state),
                 "Create package index", args.validate_cmd, args.tag_prefix)
    log("created an empty index")
    return EXIT_OK


def build_parser():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--backend", choices=("github", "dir"), required=True)
    parser.add_argument("--root", help="dir backend: storage directory")
    parser.add_argument("--uri", help="base URL the assets are served from")
    parser.add_argument("--repo", help="github backend: owner/name")
    parser.add_argument("--branch", default="binhost", help="github backend: index branch")
    parser.add_argument("--tag-prefix", default="pkgs-",
                        help="release tag prefix; the category is appended")
    parser.add_argument("--api-url", help=argparse.SUPPRESS)
    parser.add_argument("--uploads-url", help=argparse.SUPPRESS)
    parser.add_argument("--git-url", help=argparse.SUPPRESS)
    parser.add_argument("--pause", type=float, default=1.0, help=argparse.SUPPRESS)
    parser.add_argument("--validate-cmd",
                        help="command run on every candidate index; {} is the file")
    parser.add_argument("--lock", help="lock file serialising publishers")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("init", help="create an empty index").set_defaults(func=init)

    pub = sub.add_parser("publish", help="upload new packages and update the index")
    pub.add_argument("--pkgdir", required=True)
    pub.add_argument("--merged", help="file listing '<cat>/<pf> <BUILD_TIME>' of installed packages")
    pub.add_argument("--no-publish", help="file listing category/package never to publish")
    pub.add_argument("--deadline", help="epoch after which no new upload starts")
    pub.add_argument("--result", help="write a JSON summary here")
    pub.add_argument("--final", action="store_true",
                     help="exit 3 if a built package could not be published")
    pub.add_argument("--pending-ok", action="store_true",
                     help="with --final: packages that are built but not installed "
                          "(the build was stopped) do not count as unpublished")
    pub.set_defaults(func=publish)

    ev = sub.add_parser("evict", help="remove packages from the index")
    ev.add_argument("cpv", nargs="+")
    ev.add_argument("--now", action="store_true",
                    help="also delete the files at once instead of leaving that to prune")
    ev.set_defaults(func=evict)

    pr = sub.add_parser("prune", help="delete superseded files and packages gone from the tree")
    pr.add_argument("--gone", help="file listing indexed CPVs whose ebuild no longer exists")
    pr.add_argument("--grace-days", type=int, default=14)
    pr.set_defaults(func=prune)

    get = sub.add_parser("state-get", help="print builder state as JSON")
    get.add_argument("key", nargs="?")
    get.set_defaults(func=state_get)

    put = sub.add_parser("state-set", help="set one builder state key")
    put.add_argument("key")
    put.add_argument("json", help="JSON value; null removes the key")
    put.set_defaults(func=state_set)

    sub.add_parser("status", help="summarise the published index").set_defaults(func=status)
    return parser


def make_store(args, workdir):
    if args.backend == "dir":
        if not args.root or not args.uri:
            raise PublishError("--backend dir needs --root and --uri")
        return DirStore(args.root, args.uri.rstrip("/"))
    if not args.repo:
        raise PublishError("--backend github needs --repo")
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    return GitHubStore(args.repo, args.branch, token, workdir, api=args.api_url,
                       uploads=args.uploads_url, git_url=args.git_url, uri=args.uri,
                       pause=args.pause)


def main(argv=None):
    args = build_parser().parse_args(argv)
    lock = None
    try:
        if args.lock:
            # One publisher at a time: a tick must never race the final pass.
            lock = open(args.lock, "w")
            fcntl.flock(lock, fcntl.LOCK_EX)
        with tempfile.TemporaryDirectory(prefix="binhost-") as workdir:
            return args.func(make_store(args, workdir), args)
    except PublishError as error:
        print(f"[binhost] ERROR: {error}", file=sys.stderr)
        return EXIT_ERROR
    except pkgindex.PackageIndexError as error:
        print(f"[binhost] ERROR: {error}", file=sys.stderr)
        return EXIT_ERROR
    finally:
        if lock is not None:
            lock.close()


if __name__ == "__main__":
    sys.exit(main())
