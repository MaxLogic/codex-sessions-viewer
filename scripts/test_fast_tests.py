"""Selection contracts; no Rust/Flutter processes are started."""
import unittest
from pathlib import Path
import subprocess
import tempfile

from fast_tests import changed_paths, select
from test_selection_invariant import DependencyInvariantTests

ROOT = Path(__file__).resolve().parents[1]


class SelectionTests(unittest.TestCase):
    def test_resident_contract(self):
        plan = select(ROOT, ["collector/src/resident/bridge.rs"])
        self.assertTrue({"lib", "resident", "scan_launcher", "scan_transport"} <= set(plan["rust"]))
        self.assertIn("test/scanner/resident_collector_client_test.dart", plan["flutter"])
        self.assertNotIn("write_lease", plan["rust"])
        self.assertNotIn("test/path_mapping/path_mapping_test.dart", plan["flutter"])

    def test_maintenance_contract(self):
        plan = select(ROOT, ["app/lib/src/database/application_maintenance.dart"])
        self.assertIn("test/database/application_maintenance_test.dart", plan["flutter"])
        self.assertIn("test/database/space_reclaim_test.dart", plan["flutter"])
        self.assertIn("test/app/runtime_scan_app_test.dart", plan["flutter"])
        self.assertEqual(plan["rust"], [])
        self.assertNotIn("test/scanner/resident_collector_client_test.dart", plan["flutter"])
        self.assertEqual(plan["flutter_filters"], {
            "test/app/runtime_scan_app_test.dart":
                "pricing commits between background scan batches before scan completion"})

    def test_runtime_change_removes_maintenance_filter(self):
        plan = select(ROOT, ["app/lib/src/database/application_maintenance.dart",
                             "app/test/app/runtime_scan_app_test.dart"])
        self.assertEqual(plan["flutter_filters"], {})

    def test_shared_and_unknown_widen(self):
        for path in ["collector/Cargo.toml", "collector/Cargo.lock", "app/pubspec.yaml",
                     "sql/migration/new.sql", "scripts/build_windows.ps1",
                     "app/test/support/new.dart", "collector/tests/support/mod.rs",
                     "new/unmapped.source"]:
            with self.subTest(path=path):
                plan = select(ROOT, [path])
                self.assertEqual(plan["rust"], ["all"])
                self.assertEqual(plan["flutter"], ["test", "integration_test"])
                self.assertTrue(plan["widened"])
                self.assertTrue(plan["reasons"])

    def test_test_files_select_themselves_and_union(self):
        plan = select(ROOT, ["collector/tests/context_query.rs",
                             "app/test/database/application_maintenance_test.dart"])
        self.assertEqual(plan["rust"], ["context_query"])
        self.assertEqual(plan["flutter"], ["test/database/application_maintenance_test.dart"])
        self.assertFalse(plan["widened"])

    def test_docs_and_empty_are_noops(self):
        for paths in [[], ["docs/testing.md", "README.md"]]:
            plan = select(ROOT, paths)
            self.assertEqual(plan["rust"], [])
            self.assertEqual(plan["flutter"], [])
            self.assertFalse(plan["widened"])

    def test_deleted_tests_widen_instead_of_silently_disappearing(self):
        plan = select(ROOT, ["collector/tests/deleted_target.rs"])
        self.assertEqual(plan["rust"], ["all"])

    def test_portable_slashes_and_duplicates(self):
        plan = select(ROOT, ["collector\\src\\resident\\bridge.rs"] * 2)
        self.assertEqual(plan, select(ROOT, ["collector/src/resident/bridge.rs"]))

    def test_shared_resident_identity_widens(self):
        self.assertEqual(select(ROOT, ["collector/src/resident/instance.rs"])["rust"], ["all"])

    def test_git_includes_staged_unstaged_untracked_and_both_rename_sides(self):
        # Entire temporary Git fixture is disposable, contains no user data.
        with tempfile.TemporaryDirectory(prefix="cxv-selector-test-") as directory:
            root = Path(directory)

            def git(*args):
                return subprocess.run(["git", "-c", "core.hooksPath=", *args], cwd=root,
                                      check=True, capture_output=True)

            git("init")
            for name in ("old.rs", "unstaged.rs", "staged.rs"):
                (root / name).write_text("before", encoding="utf-8")
            git("add", ".")
            git("-c", "user.name=Selector Test", "-c", "user.email=selector@example.invalid",
                "commit", "-m", "disposable baseline")
            git("mv", "old.rs", "new.rs")
            (root / "staged.rs").write_text("after", encoding="utf-8")
            git("add", "staged.rs")
            (root / "unstaged.rs").write_text("after", encoding="utf-8")
            (root / "untracked.rs").write_text("new", encoding="utf-8")
            self.assertEqual(set(changed_paths(root, "HEAD")),
                             {"old.rs", "new.rs", "staged.rs", "unstaged.rs", "untracked.rs"})


if __name__ == "__main__":
    unittest.main()
