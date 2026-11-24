"""Selection contracts; no Rust/Flutter processes are started."""
import os
import unittest
from pathlib import Path
import subprocess
import sys
import tempfile

from fast_tests import changed_paths, explicit_paths, select
from test_dependencies import DependencyIndex
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

    def test_script_checks_follow_scripts_changes_only(self):
        script_paths = [r"scripts\test_fast.ps1", r".\scripts\test_fast.ps1"]
        if os.name == "nt":
            script_paths.extend([r"Scripts\test_fast.ps1", r".\SCRIPTS\TEST_FAST.PS1"])
        for path in script_paths:
            with self.subTest(path=path):
                plan = select(ROOT, explicit_paths(ROOT, [path]))
                self.assertTrue(plan["script_checks"])
                self.assertEqual(plan["rust"], ["all"])
                self.assertEqual(plan["flutter"], ["test", "integration_test"])
                self.assertIn("shared/high-risk path", plan["reasons"][0]["reason"])
        for path in ("app/lib/src/database/application_maintenance.dart", "docs/testing.md"):
            with self.subTest(path=path):
                self.assertFalse(select(ROOT, [path])["script_checks"])

    def test_static_checks_follow_the_selected_toolchains(self):
        cases = [
            (["collector/tests/context_query.rs"], ["rust-fmt", "rust-clippy"]),
            (["app/test/database/application_maintenance_test.dart"], ["dart-format", "flutter-analyze"]),
            (["collector/tests/context_query.rs", "app/test/database/application_maintenance_test.dart"],
             ["rust-fmt", "rust-clippy", "dart-format", "flutter-analyze"]),
            (["collector/Cargo.toml"], ["rust-fmt", "rust-clippy", "dart-format", "flutter-analyze"]),
            (["docs/testing.md"], []),
            ([], []),
        ]
        for paths, expected in cases:
            with self.subTest(paths=paths):
                plan = select(ROOT, paths)
                self.assertEqual(plan["static_checks"], expected)
                self.assertEqual(bool(plan["rust"]), "rust-clippy" in expected)
                self.assertEqual(bool(plan["flutter"]), "flutter-analyze" in expected)

    def test_equivalent_path_spellings_select_the_same_plan(self):
        # Every accepted spelling of one repository path must produce the
        # canonical path's whole plan: separators, `.` segments, `..` detours
        # (including detours through scripts/), absolute paths, a detour
        # through the repository's parent and, on Windows, letter case.
        canonical = ["scripts/test_fast.ps1", "scripts/test_support/TestEnvironment.ps1",
                     "docs/testing.md", "app/lib/src/database/application_maintenance.dart",
                     "collector/src/hub_server.rs", "CHANGELOG.md"]
        detours = ["", "./", "././", "app/../", "scripts/../", "docs/../collector/../",
                   f"../{ROOT.name}/", str(ROOT) + "/"]
        index = DependencyIndex(ROOT)
        for path in canonical:
            expected = select(ROOT, [path], index)
            self.assertEqual(expected["reasons"][0]["path"], path)
            parts = path.split("/")
            # A detour inside the path: first segment, then into scripts/ and back out.
            inner = "/".join(parts[:1] + ["..", "scripts", ".."] + parts) if len(parts) > 1 else path
            spellings = [prefix + body for prefix in detours for body in (path, inner)]
            if os.name == "nt":
                spellings += [s.upper() for s in spellings] + [s.lower() for s in spellings]
            for spelling in spellings:
                for variant in (spelling, spelling.replace("/", "\\")):
                    with self.subTest(path=path, variant=variant):
                        self.assertEqual(select(ROOT, explicit_paths(ROOT, [variant]), index), expected)

    def test_paths_outside_the_repository_are_rejected(self):
        drive_root = Path(ROOT.anchor)
        outside = ["../outside.txt", f"../{ROOT.name}-other/scripts/test_fast.ps1",
                   str(drive_root / ".." / "docs" / "testing.md"),
                   str(drive_root / ".." / "scripts" / "test_fast.ps1"),
                   str(drive_root / "docs" / "testing.md")]
        for path in outside:
            with self.subTest(path=path):
                with self.assertRaises(ValueError):
                    explicit_paths(ROOT, [path])
                result = subprocess.run([sys.executable, "-B", str(ROOT / "scripts" / "fast_tests.py"),
                                         "--path", path, "--dry-run"],
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 2, result.stdout)
                self.assertIn("outside the repository", result.stderr)
                self.assertEqual(result.stdout, "")

    def test_git_reported_paths_are_selected_as_reported(self):
        # Git reports both sides of a case-only rename. Each side keeps its
        # own spelling, so the unmapped side still widens as before.
        plan = select(ROOT, ["DOCS/sample test.md", "docs/sample test.md"])
        self.assertEqual([r["path"] for r in plan["reasons"]], ["DOCS/sample test.md", "docs/sample test.md"])
        self.assertTrue(plan["widened"])
        self.assertEqual(plan["rust"], ["all"])

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
