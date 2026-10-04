import http.server
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import unittest.mock
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "scripts"))

import binhost  # noqa: E402
import pkgindex  # noqa: E402

URI = "http://binhost.test/assets"


def make_pkgdir(root, mutate=None):
    """A PKGDIR as Portage leaves it: Packages plus the files it lists."""
    with open(os.path.join(HERE, "fixtures", "pkgdir-Packages"), encoding="utf-8") as handle:
        index = pkgindex.parse(handle.read())
    if mutate:
        mutate(index)
    os.makedirs(root, exist_ok=True)
    for stanza in index.packages:
        path = os.path.join(root, stanza["PATH"])
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as handle:
            handle.write(b"x" * int(stanza["SIZE"]))
    with open(os.path.join(root, "Packages"), "w", encoding="utf-8") as handle:
        handle.write(pkgindex.dump(index))
    return index


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="binhost-test-")
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.pkgdir = os.path.join(self.tmp, "pkgdir")
        self.result = os.path.join(self.tmp, "result.json")

    def read_result(self):
        with open(self.result, encoding="utf-8") as handle:
            return json.load(handle)


class DirBackend(Base):
    def setUp(self):
        super().setUp()
        self.root = os.path.join(self.tmp, "store")

    def run_cli(self, *args):
        return binhost.main(["--backend", "dir", "--root", self.root, "--uri", URI, *args])

    def publish(self, *extra):
        return self.run_cli("publish", "--pkgdir", self.pkgdir, "--result", self.result, *extra)

    def index(self):
        with open(os.path.join(self.root, "index", "Packages"), encoding="utf-8") as handle:
            return pkgindex.parse(handle.read())

    def state(self):
        with open(os.path.join(self.root, "index", "state.json"), encoding="utf-8") as handle:
            return json.load(handle)

    def test_init_creates_a_valid_empty_index(self):
        self.assertEqual(self.run_cli("init"), 0)
        index = self.index()
        self.assertEqual(index.packages, [])
        self.assertEqual(pkgindex.validate(index, "pkgs-"), [])
        self.assertEqual(self.run_cli("init"), 0)

    def test_publish_uploads_then_indexes(self):
        make_pkgdir(self.pkgdir)
        self.assertEqual(self.publish("--final"), 0)
        index = self.index()
        self.assertEqual(len(index.packages), 3)
        self.assertEqual(index.header["URI"], URI)
        self.assertEqual(pkgindex.validate(index, "pkgs-"), [])
        for pkg in index.packages:
            asset = os.path.join(self.root, "assets", pkg["PATH"])
            self.assertEqual(os.path.getsize(asset), int(pkg["SIZE"]))
        self.assertEqual(sorted(self.read_result()["published"]),
                         ["app-misc/hello-2.12.2", "dev-libs/oniguruma-6.9.10",
                          "x11-libs/gtk+-3.24.50"])

    def test_second_publish_changes_nothing(self):
        make_pkgdir(self.pkgdir)
        self.publish()
        before = self.index().header["TIMESTAMP"]
        self.assertEqual(self.publish("--final"), 0)
        self.assertEqual(self.read_result()["published"], [])
        self.assertEqual(self.index().header["TIMESTAMP"], before)

    def test_only_merged_packages_are_published(self):
        make_pkgdir(self.pkgdir)
        merged = os.path.join(self.tmp, "merged.txt")
        with open(merged, "w", encoding="utf-8") as handle:
            handle.write("app-misc/hello-2.12.2 1790000010\n")
            handle.write("dev-libs/oniguruma-6.9.10 1\n")  # other build installed
        self.assertEqual(self.publish("--merged", merged), 0)
        self.assertEqual(self.read_result()["published"], ["app-misc/hello-2.12.2"])
        self.assertEqual(self.publish("--merged", merged, "--final"), binhost.EXIT_LEFTOVER)
        self.assertEqual(self.read_result()["leftover"],
                         ["dev-libs/oniguruma-6.9.10", "x11-libs/gtk+-3.24.50"])

    def test_non_redistributable_packages_stay_private(self):
        def restrict(index):
            index.packages[0]["RESTRICT"] = "bindist mirror"
        make_pkgdir(self.pkgdir, restrict)
        deny = os.path.join(self.tmp, "no-publish.txt")
        with open(deny, "w", encoding="utf-8") as handle:
            handle.write("# never ship\nx11-libs/gtk+\n")
        self.assertEqual(self.publish("--no-publish", deny, "--final"), 0)
        self.assertEqual([p["CPV"] for p in self.index().packages], ["dev-libs/oniguruma-6.9.10"])
        skipped = self.read_result()["skipped"]
        self.assertIn("bindist", skipped["app-misc/hello-2.12.2"])
        self.assertIn("no-publish", skipped["x11-libs/gtk+-3.24.50"])

    def test_truncated_file_is_not_published(self):
        make_pkgdir(self.pkgdir)
        with open(os.path.join(self.pkgdir, "app-misc/hello/hello-2.12.2-1.gpkg.tar"), "wb"):
            pass
        self.assertEqual(self.publish("--final"), binhost.EXIT_LEFTOVER)
        self.assertNotIn("app-misc/hello-2.12.2", self.index().by_cpv())

    def test_rebuild_with_same_build_id_gets_a_new_name(self):
        make_pkgdir(self.pkgdir)
        self.publish()

        def rebuilt(index):
            index.packages[:] = [dict(index.packages[0], BUILD_TIME="1790005555", SIZE="20")]
        shutil.rmtree(self.pkgdir)
        make_pkgdir(self.pkgdir, rebuilt)
        self.assertEqual(self.publish("--final"), 0)
        hello = self.index().by_cpv()["app-misc/hello-2.12.2"]
        self.assertEqual(hello["PATH"], "pkgs-app-misc/hello-2.12.2-1.1790005555.gpkg.tar")
        self.assertEqual(hello["SIZE"], "20")
        # The replaced file stays until prune: clients may still hold the old index.
        old = os.path.join(self.root, "assets", "pkgs-app-misc", "hello-2.12.2-1.gpkg.tar")
        self.assertTrue(os.path.exists(old))
        self.assertEqual([s["path"] for s in self.state()["superseded"]],
                         ["pkgs-app-misc/hello-2.12.2-1.gpkg.tar"])
        self.assertEqual(self.run_cli("prune", "--grace-days", "0"), 0)
        self.assertFalse(os.path.exists(old))
        self.assertEqual(self.state()["superseded"], [])
        self.assertEqual(len(self.index().packages), 3)

    def test_unreferenced_leftover_is_replaced(self):
        leftover = os.path.join(self.root, "assets", "pkgs-app-misc")
        os.makedirs(leftover)
        with open(os.path.join(leftover, "hello-2.12.2-1.gpkg.tar"), "wb") as handle:
            handle.write(b"stale-bytes-from-a-failed-run")
        make_pkgdir(self.pkgdir)
        self.assertEqual(self.publish("--final"), 0)
        hello = self.index().by_cpv()["app-misc/hello-2.12.2"]
        self.assertEqual(hello["PATH"], "pkgs-app-misc/hello-2.12.2-1.gpkg.tar")
        self.assertEqual(os.path.getsize(os.path.join(self.root, "assets", hello["PATH"])), 11)

    def test_validator_veto_keeps_the_old_index(self):
        make_pkgdir(self.pkgdir)
        code = self.publish("--final")
        self.assertEqual(code, 0)
        before = self.index().header["TIMESTAMP"]
        self.assertEqual(self.run_cli("--validate-cmd", "sh -c 'echo nope; exit 1' {}",
                                      "evict", "app-misc/hello-2.12.2"), 1)
        self.assertEqual(self.index().header["TIMESTAMP"], before)
        self.assertEqual(len(self.index().packages), 3)

    def test_validator_receives_the_candidate(self):
        make_pkgdir(self.pkgdir)
        seen = os.path.join(self.tmp, "seen")
        self.assertEqual(
            binhost.main(["--backend", "dir", "--root", self.root, "--uri", URI,
                          "--validate-cmd", f"cp {{}} {seen}",
                          "publish", "--pkgdir", self.pkgdir]), 0)
        with open(seen, encoding="utf-8") as handle:
            self.assertEqual(len(pkgindex.parse(handle.read()).packages), 3)

    def test_evict_leaves_the_file_to_prune(self):
        make_pkgdir(self.pkgdir)
        self.publish()
        asset = os.path.join(self.root, "assets", "pkgs-app-misc", "hello-2.12.2-1.gpkg.tar")
        self.assertEqual(self.run_cli("evict", "app-misc/hello-2.12.2"), 0)
        self.assertNotIn("app-misc/hello-2.12.2", self.index().by_cpv())
        # A client that fetched the index a moment ago may still ask for it.
        self.assertTrue(os.path.exists(asset))
        self.assertEqual([s["path"] for s in self.state()["superseded"]],
                         ["pkgs-app-misc/hello-2.12.2-1.gpkg.tar"])
        # The package is still in PKGDIR, so the next pass offers it again,
        # under a name that does not clash with the file awaiting deletion.
        self.assertEqual(self.publish("--final"), 0)
        self.assertEqual(self.index().by_cpv()["app-misc/hello-2.12.2"]["PATH"],
                         "pkgs-app-misc/hello-2.12.2-1.1790000010.gpkg.tar")
        self.assertEqual(self.run_cli("prune", "--grace-days", "0"), 0)
        self.assertFalse(os.path.exists(asset))

    def test_evict_now_deletes_at_once(self):
        make_pkgdir(self.pkgdir)
        self.publish()
        self.assertEqual(self.run_cli("evict", "--now", "app-misc/hello-2.12.2"), 0)
        self.assertFalse(os.path.exists(
            os.path.join(self.root, "assets", "pkgs-app-misc", "hello-2.12.2-1.gpkg.tar")))
        self.assertEqual(self.state()["superseded"], [])

    def test_evict_of_an_unknown_package_changes_nothing(self):
        make_pkgdir(self.pkgdir)
        self.publish()
        before = self.index().header["TIMESTAMP"]
        self.assertEqual(self.run_cli("evict", "app-misc/nothing-1"), 0)
        self.assertEqual(self.index().header["TIMESTAMP"], before)

    def test_prune_drops_packages_gone_from_the_tree_after_grace(self):
        make_pkgdir(self.pkgdir)
        self.publish()
        asset = os.path.join(self.root, "assets", "pkgs-app-misc", "hello-2.12.2-1.gpkg.tar")
        gone = os.path.join(self.tmp, "gone.txt")
        with open(gone, "w", encoding="utf-8") as handle:
            handle.write("app-misc/hello-2.12.2\n")
        self.assertEqual(self.run_cli("prune", "--gone", gone, "--grace-days", "14"), 0)
        self.assertEqual(len(self.index().packages), 3)
        self.assertIn("app-misc/hello-2.12.2", self.state()["gone"])
        # Back in the tree: the clock resets.
        open(gone, "w").close()
        self.run_cli("prune", "--gone", gone, "--grace-days", "14")
        self.assertEqual(self.state()["gone"], {})
        with open(gone, "w", encoding="utf-8") as handle:
            handle.write("app-misc/hello-2.12.2\n")
        self.run_cli("prune", "--gone", gone, "--grace-days", "0")
        self.assertNotIn("app-misc/hello-2.12.2", self.index().by_cpv())
        # The file outlives its index entry by one more grace period.
        self.assertTrue(os.path.exists(asset))
        self.run_cli("prune", "--grace-days", "0")
        self.assertFalse(os.path.exists(asset))

    def test_second_rebuild_does_not_touch_a_file_still_in_its_grace_period(self):
        make_pkgdir(self.pkgdir)
        self.publish()
        original = os.path.join(self.root, "assets", "pkgs-app-misc", "hello-2.12.2-1.gpkg.tar")
        for build_time, size in (("1790005555", "20"), ("1790006666", "30")):
            def rebuilt(index, build_time=build_time, size=size):
                index.packages[:] = [dict(index.packages[0], BUILD_TIME=build_time, SIZE=size)]
            shutil.rmtree(self.pkgdir)
            make_pkgdir(self.pkgdir, rebuilt)
            self.assertEqual(self.publish("--final"), 0)
        self.assertEqual(self.index().by_cpv()["app-misc/hello-2.12.2"]["PATH"],
                         "pkgs-app-misc/hello-2.12.2-1.1790006666.gpkg.tar")
        self.assertEqual(os.path.getsize(original), 11)
        self.assertEqual(sorted(s["path"] for s in self.state()["superseded"]),
                         ["pkgs-app-misc/hello-2.12.2-1.1790005555.gpkg.tar",
                          "pkgs-app-misc/hello-2.12.2-1.gpkg.tar"])

    def test_only_the_newest_build_of_a_version_counts(self):
        # A rebuild within one run leaves two builds of the version in PKGDIR;
        # only the second is installed.
        def twice(index):
            older = dict(index.packages[0])
            newer = dict(older, BUILD_ID="2", BUILD_TIME="1790000099", SIZE="15",
                         PATH="app-misc/hello/hello-2.12.2-2.gpkg.tar")
            index.packages[:] = [older, newer]
        make_pkgdir(self.pkgdir, twice)
        merged = os.path.join(self.tmp, "merged.txt")
        with open(merged, "w", encoding="utf-8") as handle:
            handle.write("app-misc/hello-2.12.2 1790000099\n")
        self.assertEqual(self.publish("--merged", merged, "--final"), 0)
        hello = self.index().by_cpv()["app-misc/hello-2.12.2"]
        self.assertEqual(hello["PATH"], "pkgs-app-misc/hello-2.12.2-2.gpkg.tar")
        self.assertEqual(self.read_result()["leftover"], [])

    def test_nothing_built_is_not_an_error(self):
        os.makedirs(self.pkgdir)
        self.assertEqual(self.publish("--final"), 0)
        self.assertEqual(self.index().packages, [])

    def test_deadline_in_the_past_uploads_nothing(self):
        make_pkgdir(self.pkgdir)
        self.assertEqual(self.publish("--final", "--deadline", "1"), binhost.EXIT_LEFTOVER)
        self.assertEqual(self.index().packages, [])
        self.assertEqual(len(self.read_result()["leftover"]), 3)

    def test_prune_without_tree_knowledge_expires_nothing(self):
        make_pkgdir(self.pkgdir)
        self.publish()
        before = self.index().header["TIMESTAMP"]
        self.assertEqual(self.run_cli("prune", "--grace-days", "0"), 0)
        self.assertEqual(len(self.index().packages), 3)
        self.assertEqual(self.index().header["TIMESTAMP"], before)

    def test_state_round_trip_leaves_the_index_untouched(self):
        make_pkgdir(self.pkgdir)
        self.publish()
        before = self.index().header["TIMESTAMP"]
        self.assertEqual(self.run_cli("state-set", "continue", '{"tree_date": "20261002"}'), 0)
        self.assertEqual(self.state()["continue"], {"tree_date": "20261002"})
        self.assertEqual(self.index().header["TIMESTAMP"], before)
        self.assertEqual(self.run_cli("state-set", "continue", "null"), 0)
        self.assertNotIn("continue", self.state())

    def test_built_but_not_installed_is_excused_only_on_request(self):
        # What a build that was stopped leaves behind.
        make_pkgdir(self.pkgdir)
        merged = os.path.join(self.tmp, "merged.txt")
        with open(merged, "w", encoding="utf-8") as handle:
            handle.write("app-misc/hello-2.12.2 1790000010\n")
        self.assertEqual(self.publish("--merged", merged, "--final"), binhost.EXIT_LEFTOVER)
        self.assertEqual(self.publish("--merged", merged, "--final", "--pending-ok"), 0)
        self.assertEqual([p["CPV"] for p in self.index().packages], ["app-misc/hello-2.12.2"])
        self.assertEqual(self.read_result()["pending"],
                         ["dev-libs/oniguruma-6.9.10", "x11-libs/gtk+-3.24.50"])

    def second_package(self, index):
        index.packages.append(dict(index.packages[0], CPV="app-misc/jq-1.8.2",
                                   BUILD_TIME="1790000020",
                                   PATH="app-misc/jq/jq-1.8.2-1.gpkg.tar"))

    def test_full_release_overflows_into_the_next(self):
        make_pkgdir(self.pkgdir, self.second_package)
        with unittest.mock.patch.object(binhost, "MAX_ASSETS_PER_RELEASE", 1):
            self.assertEqual(self.publish("--final"), 0)
        index = self.index()
        self.assertEqual(index.by_cpv()["app-misc/hello-2.12.2"]["PATH"],
                         "pkgs-app-misc/hello-2.12.2-1.gpkg.tar")
        self.assertEqual(index.by_cpv()["app-misc/jq-1.8.2"]["PATH"],
                         "pkgs-app-misc.2/jq-1.8.2-1.gpkg.tar")
        self.assertEqual(pkgindex.validate(index, "pkgs-"), [])
        self.assertTrue(os.path.exists(
            os.path.join(self.root, "assets", "pkgs-app-misc.2", "jq-1.8.2-1.gpkg.tar")))

    def test_no_room_in_any_release_is_reported(self):
        make_pkgdir(self.pkgdir, self.second_package)
        with unittest.mock.patch.object(binhost, "MAX_ASSETS_PER_RELEASE", 1), \
             unittest.mock.patch.object(binhost, "MAX_RELEASES_PER_CATEGORY", 1):
            self.assertEqual(self.publish("--final"), binhost.EXIT_LEFTOVER)
        self.assertIn("no room", self.read_result()["skipped"]["app-misc/jq-1.8.2"])
        self.assertNotIn("app-misc/jq-1.8.2", self.index().by_cpv())

    def test_a_file_that_cannot_be_deleted_stays_queued(self):
        make_pkgdir(self.pkgdir)
        self.publish()
        self.assertEqual(self.run_cli("evict", "app-misc/hello-2.12.2"), 0)
        asset = os.path.join(self.root, "assets", "pkgs-app-misc", "hello-2.12.2-1.gpkg.tar")
        queued = ["pkgs-app-misc/hello-2.12.2-1.gpkg.tar"]
        with unittest.mock.patch.object(binhost.DirStore, "delete_asset",
                                        side_effect=binhost.PublishError("storage is down")):
            self.assertEqual(self.run_cli("prune", "--grace-days", "0"), 0)
        self.assertTrue(os.path.exists(asset))
        self.assertEqual([s["path"] for s in self.state()["superseded"]], queued)
        # A prune that dies while deleting must not have forgotten the files.
        with unittest.mock.patch.object(binhost, "delete_files", side_effect=KeyboardInterrupt):
            with self.assertRaises(KeyboardInterrupt):
                self.run_cli("prune", "--grace-days", "0")
        self.assertEqual([s["path"] for s in self.state()["superseded"]], queued)
        self.assertEqual(self.run_cli("prune", "--grace-days", "0"), 0)
        self.assertFalse(os.path.exists(asset))
        self.assertEqual(self.state()["superseded"], [])

    def test_files_nothing_refers_to_are_deleted_after_the_grace_period(self):
        make_pkgdir(self.pkgdir)
        self.publish()
        orphan = os.path.join(self.root, "assets", "pkgs-app-misc", "old-1.0-1.gpkg.tar")
        with open(orphan, "wb") as handle:
            handle.write(b"left by an upload whose index update never happened")
        self.assertEqual(self.run_cli("prune", "--grace-days", "14"), 0)
        self.assertEqual([s["path"] for s in self.state()["superseded"]],
                         ["pkgs-app-misc/old-1.0-1.gpkg.tar"])
        # Looking again does not start its grace period again.
        state = self.state()
        state["superseded"][0]["at"] = 5
        with open(os.path.join(self.root, "index", "state.json"), "w", encoding="utf-8") as handle:
            handle.write(binhost.dump_state(state))
        self.assertEqual(self.run_cli("prune", "--grace-days", "14"), 0)
        self.assertFalse(os.path.exists(orphan))
        self.assertEqual(self.state()["superseded"], [])
        for pkg in self.index().packages:
            self.assertTrue(os.path.exists(os.path.join(self.root, "assets", pkg["PATH"])))


class FakeGitHub(http.server.BaseHTTPRequestHandler):
    """Just enough of the releases API for the publisher."""

    def log_message(self, *args):
        pass

    def _send(self, status, body=None, headers=None):
        data = json.dumps(body).encode() if body is not None else b""
        self.send_response(status)
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _body(self):
        return self.rfile.read(int(self.headers.get("Content-Length", "0")))

    def do_GET(self):
        hub = self.server.hub
        url = urllib.parse.urlparse(self.path)
        parts = url.path.strip("/").split("/")
        hub["calls"].append(("GET", url.path))
        if parts[:4] == ["repos", "o", "r", "releases"] and parts[4:5] == ["tags"]:
            release = hub["releases"].get(urllib.parse.unquote(parts[5]))
            if release is None:
                return self._send(404, {"message": "Not Found"})
            return self._send(200, {"id": release["id"], "immutable": release["immutable"]})
        if parts[:4] == ["repos", "o", "r", "releases"] and parts[5:] == ["assets"]:
            release = next(r for r in hub["releases"].values() if str(r["id"]) == parts[4])
            page = int(urllib.parse.parse_qs(url.query).get("page", ["1"])[0])
            assets = [{"id": a["id"], "name": n, "size": a["size"], "state": "uploaded"}
                      for n, a in sorted(release["assets"].items())]
            return self._send(200, assets[(page - 1) * 100: page * 100])
        return self._send(404, {"message": "unhandled"})

    def do_POST(self):
        hub = self.server.hub
        url = urllib.parse.urlparse(self.path)
        parts = url.path.strip("/").split("/")
        data = self._body()
        hub["calls"].append(("POST", url.path))
        if parts == ["repos", "o", "r", "releases"]:
            payload = json.loads(data)
            if payload["tag_name"] in hub["releases"]:
                return self._send(422, {"errors": [{"code": "already_exists"}]})
            hub["next"] += 1
            hub["releases"][payload["tag_name"]] = {
                "id": hub["next"], "assets": {}, "payload": payload, "immutable": False}
            if hub["flaky_release"]:
                # Created, but the answer got lost.
                hub["flaky_release"] = False
                return self._send(500, {"message": "Server Error"})
            return self._send(201, {"id": hub["next"]})
        if parts[0] == "upload":
            release = next(r for r in hub["releases"].values() if str(r["id"]) == parts[5])
            name = urllib.parse.parse_qs(url.query)["name"][0]
            hub["uploads"] += 1
            if hub["limit_after"] is not None and hub["uploads"] > hub["limit_after"]:
                return self._send(403, {"message": "You have exceeded a secondary rate limit"},
                                  {"Retry-After": "60"})
            if name in hub["drop"]:
                # Hang up without an answer.
                self.close_connection = True
                return None
            if name in hub["flaky_upload"]:
                # Half an upload: the name is reserved, then the request fails.
                hub["flaky_upload"].discard(name)
                hub["next"] += 1
                release["assets"][name] = {"id": hub["next"], "size": 3}
                return self._send(500, {"message": "Server Error"})
            if name in release["assets"]:
                return self._send(422, {"errors": [{"code": "already_exists"}]})
            stored = hub["rename"].get(name, name)
            hub["next"] += 1
            release["assets"][stored] = {"id": hub["next"], "size": len(data)}
            return self._send(201, {"id": hub["next"], "name": stored, "size": len(data),
                                    "state": "uploaded"})
        return self._send(404, {"message": "unhandled"})

    def do_DELETE(self):
        hub = self.server.hub
        parts = self.path.strip("/").split("/")
        hub["calls"].append(("DELETE", self.path))
        for release in hub["releases"].values():
            for name, asset in list(release["assets"].items()):
                if str(asset["id"]) == parts[-1]:
                    del release["assets"][name]
                    return self._send(204)
        return self._send(404, {"message": "Not Found"})


@unittest.skipUnless(shutil.which("git"), "git is required for the GitHub backend tests")
class GitHubBackend(Base):
    def setUp(self):
        super().setUp()
        self.hub = {"releases": {}, "next": 100, "calls": [], "uploads": 0,
                    "limit_after": None, "rename": {}, "drop": set(),
                    "flaky_upload": set(), "flaky_release": False}
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeGitHub)
        self.server.hub = self.hub
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.shutdown)
        self.addCleanup(self.server.server_close)
        self.remote = os.path.join(self.tmp, "remote.git")
        subprocess.run(["git", "init", "--quiet", "--bare", self.remote], check=True)
        os.environ.pop("GH_TOKEN", None)
        os.environ.pop("GITHUB_TOKEN", None)

    def run_cli(self, *args):
        port = self.server.server_address[1]
        return binhost.main([
            "--backend", "github", "--repo", "o/r", "--branch", "binhost",
            "--api-url", f"http://127.0.0.1:{port}",
            "--uploads-url", f"http://127.0.0.1:{port}/upload",
            "--git-url", self.remote, "--pause", "0", *args])

    def publish(self, *extra):
        return self.run_cli("publish", "--pkgdir", self.pkgdir, "--result", self.result, *extra)

    def branch_file(self, name):
        return subprocess.run(["git", "--git-dir", self.remote, "show", f"binhost:{name}"],
                              check=True, capture_output=True, text=True).stdout

    def index(self):
        return pkgindex.parse(self.branch_file("Packages"))

    def commits(self):
        out = subprocess.run(["git", "--git-dir", self.remote, "log", "--format=%an <%ae>|%s",
                              "binhost"], check=True, capture_output=True, text=True).stdout
        return out.strip().splitlines()

    def test_publish_creates_releases_assets_and_branch(self):
        make_pkgdir(self.pkgdir)
        self.assertEqual(self.publish("--final"), 0)
        self.assertEqual(sorted(self.hub["releases"]),
                         ["pkgs-app-misc", "pkgs-dev-libs", "pkgs-x11-libs"])
        payload = self.hub["releases"]["pkgs-app-misc"]["payload"]
        self.assertTrue(payload["prerelease"])
        self.assertEqual(payload["make_latest"], "false")
        self.assertEqual(sorted(self.hub["releases"]["pkgs-x11-libs"]["assets"]),
                         ["gtk_p_-3.24.50-1.gpkg.tar"])
        index = self.index()
        self.assertEqual(index.header["URI"], "https://github.com/o/r/releases/download")
        self.assertEqual(pkgindex.validate(index, "pkgs-"), [])
        self.assertEqual(index.by_cpv()["x11-libs/gtk+-3.24.50"]["PATH"],
                         "pkgs-x11-libs/gtk_p_-3.24.50-1.gpkg.tar")
        self.assertIn("binhost index", self.branch_file("README.md"))
        self.assertTrue(all(c.startswith("github-actions[bot] <") for c in self.commits()))
        self.assertEqual(self.read_result()["head"],
                         subprocess.run(["git", "--git-dir", self.remote, "rev-parse", "binhost"],
                                        check=True, capture_output=True, text=True).stdout.strip())

    def test_idempotent_and_no_packages_gz(self):
        make_pkgdir(self.pkgdir)
        self.publish()
        commits = len(self.commits())
        uploads = self.hub["uploads"]
        self.assertEqual(self.publish("--final"), 0)
        self.assertEqual(len(self.commits()), commits)
        self.assertEqual(self.hub["uploads"], uploads)
        listing = subprocess.run(["git", "--git-dir", self.remote, "ls-tree", "--name-only",
                                  "binhost"], check=True, capture_output=True, text=True).stdout
        self.assertEqual(sorted(listing.split()), ["Packages", "README.md", "state.json"])

    def test_rate_limit_keeps_what_was_uploaded(self):
        make_pkgdir(self.pkgdir)
        self.hub["limit_after"] = 1
        self.assertEqual(self.publish("--final"), binhost.EXIT_LEFTOVER)
        result = self.read_result()
        self.assertTrue(result["rate_limited"])
        self.assertEqual(result["published"], ["app-misc/hello-2.12.2"])
        self.assertEqual([p["CPV"] for p in self.index().packages], ["app-misc/hello-2.12.2"])
        self.hub["limit_after"] = None
        self.assertEqual(self.publish("--final"), 0)
        self.assertEqual(len(self.index().packages), 3)

    def test_renamed_asset_never_reaches_the_index(self):
        make_pkgdir(self.pkgdir)
        self.hub["rename"]["hello-2.12.2-1.gpkg.tar"] = "hello.2.12.2.1.gpkg.tar"
        self.assertEqual(self.publish("--final"), binhost.EXIT_LEFTOVER)
        self.assertNotIn("app-misc/hello-2.12.2", self.index().by_cpv())
        self.assertIn("upload failed", self.read_result()["skipped"]["app-misc/hello-2.12.2"])
        self.assertEqual(len(self.index().packages), 2)

    def test_name_reserved_by_a_failed_upload_is_recovered(self):
        make_pkgdir(self.pkgdir)
        # The first upload stores a truncated file and answers 500; the retry
        # then finds the name taken.
        self.hub["flaky_upload"].add("hello-2.12.2-1.gpkg.tar")
        self.assertEqual(self.publish("--final"), 0)
        asset = self.hub["releases"]["pkgs-app-misc"]["assets"]["hello-2.12.2-1.gpkg.tar"]
        self.assertEqual(asset["size"], 11)
        self.assertEqual(len(self.index().packages), 3)

    def test_release_created_by_a_request_that_seemed_to_fail(self):
        make_pkgdir(self.pkgdir)
        self.hub["flaky_release"] = True
        self.assertEqual(self.publish("--final"), 0)
        self.assertEqual(len(self.index().packages), 3)

    def test_dropped_connection_costs_one_package_not_the_run(self):
        make_pkgdir(self.pkgdir)
        self.hub["drop"].add("hello-2.12.2-1.gpkg.tar")
        self.assertEqual(self.publish("--final"), binhost.EXIT_LEFTOVER)
        self.assertIn("upload failed", self.read_result()["skipped"]["app-misc/hello-2.12.2"])
        self.assertEqual([p["CPV"] for p in self.index().packages],
                         ["dev-libs/oniguruma-6.9.10", "x11-libs/gtk+-3.24.50"])
        self.hub["drop"].clear()
        self.assertEqual(self.publish("--final"), 0)
        self.assertEqual(len(self.index().packages), 3)

    def test_pending_ok_does_not_excuse_a_failed_upload(self):
        make_pkgdir(self.pkgdir)
        self.hub["drop"].add("hello-2.12.2-1.gpkg.tar")
        self.assertEqual(self.publish("--final", "--pending-ok"), binhost.EXIT_LEFTOVER)

    def test_evict_and_prune_delete_release_assets(self):
        make_pkgdir(self.pkgdir)
        self.publish()
        self.assertEqual(self.run_cli("evict", "app-misc/hello-2.12.2"), 0)
        assets = self.hub["releases"]["pkgs-app-misc"]["assets"]
        self.assertIn("hello-2.12.2-1.gpkg.tar", assets)
        self.assertEqual(self.run_cli("prune", "--grace-days", "0"), 0)
        self.assertNotIn("hello-2.12.2-1.gpkg.tar", assets)
        self.assertEqual(json.loads(self.branch_file("state.json"))["superseded"], [])

    def test_immutable_release_is_reported(self):
        make_pkgdir(self.pkgdir)
        self.hub["releases"]["pkgs-app-misc"] = {"id": 7, "assets": {}, "immutable": True,
                                                 "payload": {}}
        self.assertEqual(self.publish("--final"), binhost.EXIT_LEFTOVER)
        self.assertIn("immutable", self.read_result()["skipped"]["app-misc/hello-2.12.2"])

    def test_concurrent_index_update_is_merged_not_overwritten(self):
        make_pkgdir(self.pkgdir)
        self.publish()
        store = binhost.GitHubStore("o/r", "binhost", None, self.tmp, git_url=self.remote,
                                    api=f"http://127.0.0.1:{self.server.server_address[1]}",
                                    pause=0)
        stale = store.load()
        self.assertEqual(self.run_cli("state-set", "note", '"written by someone else"'), 0)
        time.sleep(1)

        def build(current, state):
            index, _ = pkgindex.remove(current, ["app-misc/hello-2.12.2"], store.uri)
            return index, state

        binhost.commit_index(store, stale, build, "Remove one", None, "pkgs-",
                             allow_shrink=True)
        self.assertEqual(json.loads(self.branch_file("state.json"))["note"],
                         "written by someone else")
        self.assertEqual(len(self.index().packages), 2)


if __name__ == "__main__":
    unittest.main()
