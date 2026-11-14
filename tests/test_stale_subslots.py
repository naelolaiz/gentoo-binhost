import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "scripts"))

import stale_subslots  # noqa: E402


def record(cp, slot, subslot, deps=()):
    return {"cp": cp, "slot": slot, "subslot": subslot, "deps": list(deps)}


class SplitSlot(unittest.TestCase):
    def test_subslot(self):
        self.assertEqual(stale_subslots.split_slot("0/4"), ("0", "4"))

    def test_slot_without_subslot_is_its_own(self):
        self.assertEqual(stale_subslots.split_slot("0"), ("0", "0"))
        self.assertEqual(stale_subslots.split_slot("3.13"), ("3.13", "3.13"))


class ProviderIndex(unittest.TestCase):
    def test_grouped_by_cp_and_slot(self):
        index = stale_subslots.provider_index([
            ("dev-libs/openssl", "0", "4"),
            ("dev-libs/openssl", "3", "3"),
        ])
        self.assertEqual(index[("dev-libs/openssl", "0")], {"4"})
        self.assertEqual(index[("dev-libs/openssl", "3")], {"3"})


class StaleDependencies(unittest.TestCase):
    def index(self):
        return stale_subslots.provider_index([("dev-libs/openssl", "0", "4")])

    def test_matching_subslot_is_fine(self):
        stale = stale_subslots.stale_dependencies(
            [("dev-libs/openssl", "0", "4")], self.index())
        self.assertEqual(stale, [])

    def test_old_subslot_is_stale(self):
        stale = stale_subslots.stale_dependencies(
            [("dev-libs/openssl", "0", "3")], self.index())
        self.assertEqual(stale, [("dev-libs/openssl", "0", "3")])

    def test_unknown_slot_is_ignored(self):
        stale = stale_subslots.stale_dependencies(
            [("dev-libs/openssl", "3", "3")], self.index())
        self.assertEqual(stale, [])

    def test_missing_subslot_is_ignored(self):
        stale = stale_subslots.stale_dependencies(
            [("dev-libs/openssl", None, None),
             ("dev-libs/openssl", "0", None)], self.index())
        self.assertEqual(stale, [])


class StaleConsumers(unittest.TestCase):
    def test_consumer_of_moved_provider_is_rebuilt(self):
        installed = {
            "dev-libs/openssl-4.1.0": record("dev-libs/openssl", "0", "4"),
            "dev-vcs/git-2.56.1": record(
                "dev-vcs/git", "0", "0",
                deps=[("dev-libs/openssl", "0", "3")]),
        }
        self.assertEqual(stale_subslots.stale_consumers(installed),
                         ["dev-vcs/git"])

    def test_consumer_of_current_provider_is_left_alone(self):
        installed = {
            "dev-libs/openssl-4.1.0": record("dev-libs/openssl", "0", "4"),
            "dev-vcs/git-2.56.1": record(
                "dev-vcs/git", "0", "0",
                deps=[("dev-libs/openssl", "0", "4")]),
        }
        self.assertEqual(stale_subslots.stale_consumers(installed), [])

    def test_absent_provider_does_not_flag(self):
        installed = {
            "dev-vcs/git-2.56.1": record(
                "dev-vcs/git", "0", "0",
                deps=[("dev-libs/openssl", "0", "3")]),
        }
        self.assertEqual(stale_subslots.stale_consumers(installed), [])

    def test_one_stale_dependency_is_enough(self):
        installed = {
            "dev-libs/openssl-4.1.0": record("dev-libs/openssl", "0", "4"),
            "media-libs/libavif-1.4.2": record("media-libs/libavif", "0", "16.4"),
            "media-libs/gd-2.3.3": record(
                "media-libs/gd", "2", "3",
                deps=[("media-libs/libavif", "0", "16.3"),
                      ("media-libs/libpng", "0", "16")]),
        }
        self.assertEqual(stale_subslots.stale_consumers(installed),
                         ["media-libs/gd"])

    def test_result_is_sorted_and_unique(self):
        installed = {
            "dev-libs/openssl-4.1.0": record("dev-libs/openssl", "0", "4"),
            "z-app/one-1": record("z-app/one", "0", "0",
                                  deps=[("dev-libs/openssl", "0", "3"),
                                        ("dev-libs/openssl", "0", "3")]),
            "a-app/two-1": record("a-app/two", "0", "0",
                                  deps=[("dev-libs/openssl", "0", "3")]),
        }
        self.assertEqual(stale_subslots.stale_consumers(installed),
                         ["a-app/two", "z-app/one"])


if __name__ == "__main__":
    unittest.main()
