import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "scripts"))

import pkgindex  # noqa: E402

URI = "https://github.com/example/binhost/releases/download"
PREFIX = "pkgs-"


def fixture():
    with open(os.path.join(HERE, "fixtures", "pkgdir-Packages"), encoding="utf-8") as handle:
        return pkgindex.parse(handle.read())


def published(local, names=None):
    """Publish every stanza of a PKGDIR index into an empty remote index."""
    additions = []
    for stanza in local.packages:
        tag = pkgindex.release_tag(stanza["CPV"], PREFIX)
        additions.append(pkgindex.localize(stanza, local.header,
                                           f"{tag}/{pkgindex.asset_name(stanza)}"))
    index, _ = pkgindex.merge(pkgindex.empty(URI, now=100), additions, local.header, URI,
                              now=200)
    return index


class ParseDump(unittest.TestCase):
    def test_round_trip_is_stable(self):
        index = fixture()
        text = pkgindex.dump(index)
        again = pkgindex.parse(text)
        self.assertEqual(index.header, again.header)
        self.assertEqual(index.packages, again.packages)
        self.assertEqual(text, pkgindex.dump(again))

    def test_blocks_are_separated_by_exactly_one_blank_line(self):
        # Portage stops reading at the first empty stanza.
        text = pkgindex.dump(fixture())
        self.assertNotIn("\n\n\n", text)
        self.assertTrue(text.endswith("\n\n"))
        self.assertEqual(text.count("\n\n"), 1 + 3)

    def test_parse_tolerates_extra_blank_lines(self):
        index = pkgindex.parse("VERSION: 0\n\n\n\nCPV: a/b-1\nPATH: x\n\n\n")
        self.assertEqual([p["CPV"] for p in index.packages], ["a/b-1"])

    def test_values_keep_colons_and_empty_values(self):
        index = pkgindex.parse("VERSION: 0\nURI: https://h/p\nEMPTY:\n")
        self.assertEqual(index.header["URI"], "https://h/p")
        self.assertEqual(index.header["EMPTY"], "")
        self.assertIn("EMPTY:\n", pkgindex.dump(index))

    def test_rejects_headerless_and_cpvless(self):
        with self.assertRaises(pkgindex.PackageIndexError):
            pkgindex.parse("")
        with self.assertRaises(pkgindex.PackageIndexError):
            pkgindex.parse("CPV: a/b-1\n")
        with self.assertRaises(pkgindex.PackageIndexError):
            pkgindex.parse("VERSION: 0\n\nPATH: x\n")


class Names(unittest.TestCase):
    def test_asset_name_keeps_portage_basename(self):
        hello = fixture().packages[0]
        self.assertEqual(pkgindex.asset_name(hello), "hello-2.12.2-1.gpkg.tar")
        self.assertEqual(pkgindex.asset_name(hello, unique=True),
                         "hello-2.12.2-1.1790000010.gpkg.tar")

    def test_plus_is_mapped_to_a_safe_alphabet(self):
        gtk = fixture().packages[2]
        self.assertEqual(pkgindex.asset_name(gtk), "gtk_p_-3.24.50-1.gpkg.tar")
        self.assertEqual(pkgindex.release_tag("x11-libs/gtk+-3.24.50", PREFIX), "pkgs-x11-libs")
        self.assertEqual(pkgindex.release_tag("dev-c++/foo-1", PREFIX), "pkgs-dev-c_p__p_")

    def test_xpak_is_refused(self):
        with self.assertRaises(pkgindex.PackageIndexError):
            pkgindex.asset_name({"CPV": "a/b-1", "PATH": "a/b-1.tbz2", "BUILD_TIME": "1"})

    def test_cp_of(self):
        self.assertEqual(pkgindex.cp_of("app-misc/hello-2.12.2"), "app-misc/hello")
        self.assertEqual(pkgindex.cp_of("media-fonts/font-adobe-100dpi-1.0.4-r1"),
                         "media-fonts/font-adobe-100dpi")
        self.assertEqual(pkgindex.cp_of("x11-libs/gtk+-3.24.50"), "x11-libs/gtk+")
        self.assertEqual(pkgindex.cp_of("dev-libs/openssl-3.5.0_beta1"), "dev-libs/openssl")


class Merge(unittest.TestCase):
    def test_stanzas_are_verbatim_except_path_and_inherited_keys(self):
        local = fixture()
        index = published(local)
        hello = index.by_cpv()["app-misc/hello-2.12.2"]
        original = dict(local.packages[0])
        self.assertEqual(hello["PATH"], "pkgs-app-misc/hello-2.12.2-1.gpkg.tar")
        self.assertEqual(hello["CHOST"], "x86_64-pc-linux-gnu")
        for key, value in original.items():
            if key != "PATH":
                self.assertEqual(hello[key], value, key)

    def test_header_is_the_builders_plus_managed_keys(self):
        index = published(fixture())
        self.assertEqual(index.header["VERSION"], "0")
        self.assertEqual(index.header["URI"], URI)
        self.assertEqual(index.header["PACKAGES"], "3")
        self.assertEqual(index.header["TIMESTAMP"], "200")
        self.assertEqual(index.header["PROFILE"], "default/linux/amd64/23.0/desktop/plasma")
        self.assertNotIn("REPO_REVISIONS", index.header)
        self.assertEqual(pkgindex.validate(index, PREFIX), [])

    def test_timestamp_strictly_increases_even_with_a_slow_clock(self):
        index = published(fixture())
        again, _ = pkgindex.merge(index, [], None, URI, now=5)
        self.assertEqual(again.header["TIMESTAMP"], "201")
        self.assertEqual(pkgindex.validate(again, PREFIX, previous=index), [])

    def test_rebuild_replaces_the_cpv_and_reports_the_old_file(self):
        local = fixture()
        index = published(local)
        rebuilt = dict(local.packages[0], BUILD_TIME="1790009999", BUILD_ID="2",
                       PATH="app-misc/hello/hello-2.12.2-2.gpkg.tar")
        entry = pkgindex.localize(rebuilt, local.header, "pkgs-app-misc/hello-2.12.2-2.gpkg.tar")
        merged, superseded = pkgindex.merge(index, [entry], local.header, URI, now=300)
        self.assertEqual(superseded, ["pkgs-app-misc/hello-2.12.2-1.gpkg.tar"])
        self.assertEqual(len(merged.packages), 3)
        self.assertEqual(merged.by_cpv()["app-misc/hello-2.12.2"]["BUILD_TIME"], "1790009999")
        self.assertEqual(pkgindex.validate(merged, PREFIX, previous=index), [])

    def test_packages_are_sorted_by_cpv(self):
        cpvs = [p["CPV"] for p in published(fixture()).packages]
        self.assertEqual(cpvs, sorted(cpvs))

    def test_remove(self):
        index = published(fixture())
        smaller, paths = pkgindex.remove(index, ["app-misc/hello-2.12.2"], URI, now=400)
        self.assertEqual(paths, ["pkgs-app-misc/hello-2.12.2-1.gpkg.tar"])
        self.assertEqual(smaller.header["PACKAGES"], "2")
        self.assertTrue(pkgindex.validate(smaller, PREFIX, previous=index))
        self.assertEqual(pkgindex.validate(smaller, PREFIX, previous=index, allow_shrink=True), [])


class Validate(unittest.TestCase):
    def assertRejected(self, index, needle, **kwargs):
        errors = pkgindex.validate(index, PREFIX, **kwargs)
        self.assertTrue(any(needle in e for e in errors), errors)

    def test_empty_index_is_valid(self):
        self.assertEqual(pkgindex.validate(pkgindex.empty(URI), PREFIX), [])

    def test_header_requirements(self):
        index = published(fixture())
        for key in ("VERSION", "TIMESTAMP", "URI"):
            broken = pkgindex.Index(index.header, index.packages)
            del broken.header[key]
            self.assertRejected(broken, key)
        broken = pkgindex.Index(index.header, index.packages[:-1])
        self.assertRejected(broken, "PACKAGES")

    def test_unsynthesised_metadata_is_required(self):
        # The index the old generator wrote: no BUILD_TIME, no MTIME.
        index = published(fixture())
        for key in ("BUILD_ID", "BUILD_TIME", "MTIME", "SIZE"):
            broken = pkgindex.Index(index.header, index.packages)
            del broken.packages[0][key]
            self.assertRejected(broken, key)

    def test_path_must_be_tag_slash_asset(self):
        index = published(fixture())
        cases = {
            "tmp/artifacts/app-misc/hello-2.12.2-1.gpkg.tar": "PATH",
            "pkgs-app-misc/hello-2.12.2-1.tbz2": "PATH",
            "pkgs-dev-libs/hello-2.12.2-1.gpkg.tar": "does not match",
            "pkgs-app-misc/hel lo.gpkg.tar": "PATH",
        }
        for path, needle in cases.items():
            broken = pkgindex.Index(index.header, index.packages)
            broken.packages[0]["PATH"] = path
            self.assertRejected(broken, needle)

    def test_corrupt_cpv_is_rejected(self):
        # The entry that once crashed every client.
        index = published(fixture())
        index.packages[0]["CPV"] = "tmp/artifacts/acct-group/cuse/cuse-0-1"
        self.assertRejected(index, "CPV")

    def test_duplicates_are_rejected(self):
        index = published(fixture())
        doubled = pkgindex.Index(index.header, index.packages + [index.packages[0]])
        doubled.header["PACKAGES"] = "4"
        self.assertRejected(doubled, "duplicate CPV")
        self.assertRejected(doubled, "used by another package")

    def test_shrinking_needs_permission(self):
        index = published(fixture())
        smaller, _ = pkgindex.remove(index, ["app-misc/hello-2.12.2"], URI, now=999)
        self.assertRejected(smaller, "shrank", previous=index)

    def test_bad_digest(self):
        index = published(fixture())
        index.packages[0]["MD5"] = "xyz"
        self.assertRejected(index, "MD5")


if __name__ == "__main__":
    unittest.main()
