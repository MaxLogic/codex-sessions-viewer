"""Focused native packaging fixtures; never invoke Flutter, Cargo or real signing."""
import json
import os
import platform
from pathlib import Path
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest
from unittest import mock
import zipfile

import native_release as release


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cxv native ; fixture ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.built = self.root / "built"
        self.bins = self.root / "bins"
        self.output = self.root / "output"
        for folder in (self.repo, self.built, self.bins):
            folder.mkdir()
        self.put(self.repo / "app/pubspec.yaml", "version: 2.3.4+5\n")
        self.put(self.repo / "collector/Cargo.toml", '[package]\nversion = "0.9.8"\n')
        self.sample = b"# public sample\n[collector]\n"
        self.put(self.repo / "settings.sample.toml", self.sample)
        self.put(self.repo / "sql/init/schema.sql", "CREATE TABLE example(x);")
        self.put(self.repo / "assets/icons/icon.png", b"public asset")
        for name in release.BINARIES:
            self.put(self.bins / name, name)
            (self.bins / name).chmod(0o755)

    @staticmethod
    def put(path, content):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content.encode() if isinstance(content, str) else content)

    def fixture(self, target):
        if target == "linux":
            native = self.built / "bundle"
            exe = native / release.VIEWER
            self.put(native / "data/flutter_assets/AssetManifest.bin", b"flutter")
            self.put(native / "lib/libsqlite3.so", b"native sqlite")
            self.put(native / (release.APP_ID + ".desktop"), "Exec=codex_sessions_viewer\n")
            self.put(native / ("data/" + release.APP_ID + ".png"), b"icon")
            resources = native / "data"
        else:
            native = self.built / (release.VIEWER + ".app")
            exe = native / "Contents/MacOS" / release.VIEWER
            self.put(native / "Contents/Info.plist", b"plist")
            self.put(native / "Contents/Frameworks/FlutterMacOS.framework/Versions/A/FlutterMacOS", b"framework")
            self.put(native / "Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/AssetManifest.bin", b"flutter")
            resources = native / "Contents/Resources"
        self.put(exe, b"viewer")
        exe.chmod(0o755)
        self.put(resources / "settings.toml", b"PRIVATE RUNTIME")
        self.put(resources / "profiles/private.json", b"PRIVATE PROFILE")
        self.put(resources / "viewer.sqlite3-wal", b"PRIVATE DATABASE")
        return native

    def package(self, target, runner=None, identity=None, profile=None):
        return release.package(self.repo, self.fixture(target), self.bins, self.output,
                               target, runner or self.fake_runner, identity, profile)

    def fake_runner(self, name, args, cwd, env=None, sensitive=False):
        self.assertNotIn("codex-sessions-hub", str(args[0]))
        return 0, "codex-sessions-collector 0.9.8 (contract test)\n"

    def test_linux_complete_public_bundle_tar_and_versions(self):
        folder, archive = self.package("linux")
        self.assertEqual(folder, self.output / "linux")
        self.assertEqual((folder / "data/settings.sample.toml").read_bytes(), self.sample)
        self.assertTrue((folder / "lib/libsqlite3.so").is_file())
        self.assertTrue((folder / "data/flutter_assets/AssetManifest.bin").is_file())
        self.assertTrue((folder / release.BINARIES[1]).is_file())
        manifest = json.loads((folder / "release-manifest.json").read_text())
        self.assertEqual(manifest["app_version"], "2.3.4+5")
        self.assertEqual(manifest["collector_version"], "0.9.8")
        self.assertNotIn(str(self.root), json.dumps(manifest))
        with tarfile.open(archive) as bundle:
            names = bundle.getnames()
            contents = b"".join(bundle.extractfile(x).read() for x in bundle.getmembers() if x.isfile())
            if os.name != "nt":
                self.assertTrue(bundle.getmember("linux/" + release.VIEWER).mode & 0o111)
        self.assertNotIn(b"PRIVATE", contents)
        self.assertFalse(any("settings.toml" in x or "profiles" in x or "sqlite3-wal" in x for x in names))

    def test_macos_complete_app_zip_and_executable_modes(self):
        folder, archive = self.package("macos")
        self.assertEqual((folder / "Contents/Resources/settings.sample.toml").read_bytes(), self.sample)
        self.assertTrue((folder / "Contents/MacOS" / release.BINARIES[1]).is_file())
        with zipfile.ZipFile(archive) as bundle:
            member = bundle.getinfo(folder.name + "/Contents/MacOS/" + release.VIEWER)
            if os.name != "nt":
                self.assertTrue((member.external_attr >> 16) & 0o111)
            contents = b"".join(bundle.read(x) for x in bundle.namelist())
            self.assertNotIn(b"PRIVATE", contents)

    def test_ad_hoc_app_is_resealed_after_sidecars_are_added(self):
        names = []
        def fake(name, args, cwd, env=None, sensitive=False):
            names.append(name)
            if name == "adhoc-app":
                self.assertEqual(args[:4], ["codesign", "--force", "--sign", "-"])
                self.assertTrue((Path(args[-1]) / "Contents/MacOS" / release.BINARIES[1]).is_file())
                self.assertEqual((Path(args[-1]) / "Contents/Resources/settings.sample.toml").read_bytes(), self.sample)
            return self.fake_runner(name, args, cwd, env, sensitive)
        self.package("macos", fake)
        self.assertLess(names.index("adhoc-sidecar-0"), names.index("adhoc-app"))
        self.assertLess(names.index("adhoc-app"), names.index("verify-adhoc"))
        self.assertNotIn("notarize", names)

    @unittest.skipIf(os.name == "nt", "real POSIX framework symlinks and executable modes")
    def test_framework_symlink_preserved_zip_without_dereferencing(self):
        native = self.fixture("macos")
        framework = native / "Contents/Frameworks/FlutterMacOS.framework"
        (framework / "Versions/Current").symlink_to("A")
        (framework / "FlutterMacOS").symlink_to("Versions/Current/FlutterMacOS")
        folder, archive = release.package(self.repo, native, self.bins, self.output,
                                          "macos", self.fake_runner)
        self.assertTrue((folder / "Contents/Frameworks/FlutterMacOS.framework/FlutterMacOS").is_symlink())
        with zipfile.ZipFile(archive) as bundle:
            entry = bundle.getinfo(folder.name + "/Contents/Frameworks/FlutterMacOS.framework/FlutterMacOS")
            self.assertTrue(stat.S_ISLNK(entry.external_attr >> 16))
            self.assertEqual(bundle.read(entry), b"Versions/Current/FlutterMacOS")

    @unittest.skipIf(os.name == "nt", "real POSIX symlinks")
    def test_external_symlink_is_rejected_before_archive(self):
        native = self.fixture("linux")
        self.put(self.root / "secret", b"PRIVATE")
        (native / "data/leak").symlink_to(self.root / "secret")
        with self.assertRaisesRegex(ValueError, "symlink"):
            release.package(self.repo, native, self.bins, self.output, "linux", self.fake_runner)
        self.assertFalse(self.output.exists())

    def test_overlapping_output_is_rejected_without_deletion(self):
        native = self.fixture("linux")
        for output in (native, native / "child", self.repo, self.repo / "assets", self.root):
            with self.subTest(output=output), self.assertRaisesRegex(ValueError, "overlap|output"):
                release.package(self.repo, native, self.bins, output, "linux", self.fake_runner)
        self.assertTrue((native / release.VIEWER).is_file())

    def test_collector_version_error_blocks_publication(self):
        def wrong(*args, **kwargs):
            return 0, "not collector 0.9.8"
        with self.assertRaisesRegex(ValueError, "version"):
            self.package("linux", wrong)
        self.assertFalse((self.output / "linux").exists())

    def test_signed_macos_order_and_notary_profile_configuration(self):
        calls = []
        def run(name, args, cwd, env=None, sensitive=False):
            calls.append((name, list(args), sensitive))
            if name == "staple":
                self.put(Path(args[-1]) / "Contents/stapled-fixture", b"fixture ticket")
            return self.fake_runner(name, args, cwd, env, sensitive)
        self.package("macos", run, "fixture identity", "fixture profile")
        names = [x[0] for x in calls]
        self.assertLess(names.index("sign-sidecar-collector"), names.index("sign-app"))
        self.assertLess(names.index("sign-app"), names.index("verify-signature"))
        self.assertLess(names.index("verify-signature"), names.index("notarize"))
        self.assertLess(names.index("notarize"), names.index("staple"))
        self.assertLess(names.index("staple"), names.index("validate-staple"))
        with zipfile.ZipFile(self.output / "codex_sessions_viewer_macos.zip") as z:
            self.assertTrue(any(x.endswith("Contents/stapled-fixture") for x in z.namelist()))
        self.assertTrue(all(sensitive for name, _, sensitive in calls if name.startswith("sign") or name == "notarize"))
        with self.assertRaisesRegex(ValueError, "identity"):
            self.package("macos", profile="fixture profile")

    def test_sign_failure_keeps_previous_package(self):
        self.package("macos")
        archive = self.output / "codex_sessions_viewer_macos.zip"
        previous = archive.read_bytes()
        def fail(name, *args, **kwargs):
            return (17, "failed") if name == "sign-app" else self.fake_runner(name, *args, **kwargs)
        with self.assertRaises(release.StepFailure) as failure:
            self.package("macos", fail, "fixture identity")
        self.assertEqual(failure.exception.code, 17)
        self.assertEqual(archive.read_bytes(), previous)

    def test_native_macos_archiver_preserves_metadata_and_checks_output(self):
        bundle = self.fixture("macos")
        archive = self.root / "mac.zip"
        def fake(name, args, cwd, env=None, sensitive=False):
            self.assertEqual(args[:3], ["ditto", "-c", "-k"])
            self.assertIn("--sequesterRsrc", args)
            self.assertIn("--keepParent", args)
            release.zip_bundle(Path(args[-2]), Path(args[-1]))
            return 0, ""
        release.macos_zip(bundle, archive, fake)
        self.assertTrue(archive.is_file())
        archive.unlink()
        with self.assertRaisesRegex(ValueError, "archiver"):
            release.macos_zip(bundle, archive, lambda *a, **k: (0, ""))

    @unittest.skipIf(os.name == "nt", "real POSIX output symlink")
    def test_symlinked_output_platform_is_rejected_without_external_changes(self):
        native = self.fixture("macos")
        external = self.root / "external"
        external.mkdir()
        self.put(external / "keep", b"keep")
        self.output.mkdir()
        (self.output / "macos").symlink_to(external, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "output"):
            release.package(self.repo, native, self.bins, self.output, "macos", self.fake_runner)
        self.assertEqual(list(external.iterdir()), [external / "keep"])

    @unittest.skipIf(os.name == "nt", "real POSIX symlink")
    def test_filtered_private_file_link_cannot_reenter_archive(self):
        native = self.fixture("linux")
        (native / "data/public-link").symlink_to("settings.toml")
        with self.assertRaisesRegex(ValueError, "symlink"):
            release.package(self.repo, native, self.bins, self.output, "linux", self.fake_runner)

    def test_missing_native_runtime_is_not_a_package(self):
        native = self.fixture("linux")
        (native / (release.APP_ID + ".desktop")).unlink()
        with self.assertRaisesRegex(ValueError, "incomplete"):
            release.package(self.repo, native, self.bins, self.output, "linux", self.fake_runner)
        self.assertFalse((self.output / "linux").exists())

    def previous_macos(self):
        folder, archive = self.package("macos")
        metadata = self.output / "macos/release-manifest.json"
        before = {path: path.read_bytes() for path in folder.rglob("*") if path.is_file()}
        before.update({path: path.read_bytes() for path in (archive, metadata)})
        native = self.fixture("macos")
        self.put(native / "Contents/MacOS" / release.VIEWER, b"CHANGED VIEWER")
        self.put(native / "Contents/Resources/new-public-fixture", b"NEW RESOURCE")
        return native, before, metadata

    def assert_previous(self, before):
        for path, data in before.items():
            self.assertEqual(path.read_bytes(), data, str(path))
        folder = self.output / "macos" / (release.VIEWER + ".app")
        self.assertEqual({p for p in folder.rglob("*") if p.is_file()},
                         {p for p in before if p.is_relative_to(folder)})

    @unittest.skipIf(os.name == "nt", "real POSIX metadata symlink")
    def test_metadata_symlink_cannot_corrupt_external_note(self):
        native, before, metadata = self.previous_macos()
        note = self.root / "external-note"
        self.put(note, b"KEEP-EXTERNAL")
        metadata.unlink()
        metadata.symlink_to(note)
        with self.assertRaisesRegex(ValueError, "publication"):
            release.package(self.repo, native, self.bins, self.output, "macos", self.fake_runner)
        self.assertEqual(note.read_bytes(), b"KEEP-EXTERNAL")
        self.assert_previous({p: data for p, data in before.items() if p != metadata})
        self.assertTrue(metadata.is_symlink())

    def test_metadata_directory_failure_keeps_previous_app_and_archive(self):
        native, before, metadata = self.previous_macos()
        metadata.unlink()
        metadata.mkdir()
        with self.assertRaises((ValueError, OSError)):
            release.package(self.repo, native, self.bins, self.output, "macos", self.fake_runner)
        self.assert_previous({p: data for p, data in before.items() if p != metadata})
        self.assertTrue(metadata.is_dir())

    def test_metadata_write_failure_keeps_previous_delivery(self):
        native, before, _ = self.previous_macos()
        original = Path.write_text
        def fail(path, *args, **kwargs):
            if path.name == "release-manifest.json":
                raise OSError("fixture metadata storage exhaustion")
            return original(path, *args, **kwargs)
        with mock.patch.object(Path, "write_text", fail), self.assertRaisesRegex(OSError, "fixture metadata"):
            release.package(self.repo, native, self.bins, self.output, "macos", self.fake_runner)
        self.assert_previous(before)

    def test_archive_hash_failure_keeps_previous_delivery(self):
        native, before, _ = self.previous_macos()
        original = release.sha256
        def fail(path):
            if path.name.endswith("_macos.zip"):
                raise OSError("fixture archive hash read failure")
            return original(path)
        with mock.patch.object(release, "sha256", fail), self.assertRaisesRegex(OSError, "fixture archive hash"):
            release.package(self.repo, native, self.bins, self.output, "macos", self.fake_runner)
        self.assert_previous(before)

    def test_final_metadata_publication_failure_rolls_back_all_three_artifacts(self):
        native, before, metadata = self.previous_macos()
        original = os.replace
        failed = False
        def fail(source, destination):
            nonlocal failed
            if Path(destination) == metadata and not failed:
                failed = True
                raise OSError("fixture final metadata publication failure")
            return original(source, destination)
        with mock.patch.object(os, "replace", fail), self.assertRaisesRegex(OSError, "fixture final metadata"):
            release.package(self.repo, native, self.bins, self.output, "macos", self.fake_runner)
        self.assertTrue(failed)
        self.assert_previous(before)

    def test_rollback_failure_retains_previous_artifact_for_recovery(self):
        native, before, metadata = self.previous_macos()
        archive = self.output / "codex_sessions_viewer_macos.zip"
        original = os.replace
        failed = False
        def fail(source, destination):
            nonlocal failed
            if Path(destination) == metadata and not failed:
                failed = True
                raise OSError("fixture publication failure")
            if Path(source).name == "previous-1" and Path(destination) == archive:
                raise OSError("fixture rollback failure")
            return original(source, destination)
        with mock.patch.object(os, "replace", fail), self.assertRaisesRegex(release.PublicationRecoveryError, "retained"):
            release.package(self.repo, native, self.bins, self.output, "macos", self.fake_runner)
        stages = list(self.root.glob("cxv-native-stage-*"))
        self.assertEqual(len(stages), 1)
        self.assertEqual((stages[0] / "previous-1").read_bytes(), before[archive])
        self.assert_previous({p: data for p, data in before.items() if p != archive})


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cxv runner ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_native_error_status_logs_and_environment_unchanged(self):
        runner = release.Runner(self.root / "logs", "fixture-hash", deadline=10)
        before = dict(os.environ)
        code, output = runner("native-error", [sys.executable, "-c", "import os,sys; print(os.environ['CXV_FIXTURE']); sys.exit(7)"],
                              self.root, {**os.environ, "CXV_FIXTURE": "temporary"})
        self.assertEqual(code, 7)
        self.assertIn("temporary", output)
        self.assertEqual(dict(os.environ), before)
        record = json.loads((self.root / "logs/native-error.json").read_text())
        self.assertEqual(record["exit_code"], 7)
        self.assertEqual(record["input_identity"], "fixture-hash")
        self.assertTrue((self.root / "logs/native-error.log").is_file())

    def test_sensitive_arguments_and_tool_output_are_not_logged(self):
        runner = release.Runner(self.root / "logs", "fixture", deadline=10)
        runner("sign", [sys.executable, "-c", "print('fixture-private-identity')"], self.root, sensitive=True)
        self.assertNotIn("fixture-private-identity", "".join(x.read_text() for x in (self.root / "logs").iterdir()))

    @unittest.skipIf(os.name == "nt", "real POSIX executable shim")
    def test_ninja_shim_enforces_two_jobs_with_spaced_tool_path(self):
        tool = self.root / "fake ninja ; literal"
        tool.write_text("#!/usr/bin/env python3\nimport sys,json\nprint(json.dumps(sys.argv[1:]))\n")
        tool.chmod(0o755)
        tools = self.root / "tools"
        tools.mkdir()
        shim = release.ninja_shim(tools, tool)
        runner = release.Runner(self.root / "logs", "fixture", deadline=10)
        code, output = runner("ninja-shim", [str(shim), "-j8", "path ; unchanged"], self.root)
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(output), ["-j8", "path ; unchanged", "-j2"])

    @unittest.skipIf(os.name == "nt", "real POSIX executable shim")
    def test_xcrun_shim_bounds_xcode_projects_and_preserves_other_tools(self):
        tool = self.root / "fake xcrun"
        tool.write_text("#!/usr/bin/env python3\nimport sys,json\nprint(json.dumps(sys.argv[1:]))\n")
        tool.chmod(0o755)
        tools = self.root / "tools"
        tools.mkdir()
        shim = release.xcrun_shim(tools, tool)
        runner = release.Runner(self.root / "logs", "fixture", deadline=10)
        code, output = runner("xcode-shim", [str(shim), "xcodebuild", "-workspace", "fixture ; path"], self.root)
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(output)[-2:], ["-jobs", "2"])
        code, output = runner("xcrun-other", [str(shim), "notarytool", "help"], self.root)
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(output), ["notarytool", "help"])

    @unittest.skipIf(os.name == "nt", "actual POSIX wrapper seam")
    def test_wrapper_interpreter_override_and_native_host_guard(self):
        target = "macos" if platform.system() == "Darwin" else "linux"
        tool = self.root / "fake python ; literal"
        tool.write_text("#!/usr/bin/env python3\nimport sys,json\nprint(json.dumps(sys.argv[1:]))\n")
        tool.chmod(0o755)
        folder = Path(__file__).resolve().parent
        run = release.Runner(self.root / "logs", "fixture", deadline=10)
        env = {**os.environ, "CXV_PYTHON": str(tool)}
        code, output = run("wrapper", ["bash", str(folder / ("build_" + target + ".sh"))], self.root, env)
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(output), [str(folder / "native_release.py"), target])
        other = "linux" if target == "macos" else "macos"
        code, output = run("wrong-host", ["bash", str(folder / ("build_" + other + ".sh"))], self.root, env)
        self.assertEqual(code, 2)
        self.assertIn("require a native", output)

    @unittest.skipIf(os.name == "nt", "real owned POSIX process-group cleanup")
    def test_timeout_kills_owned_descendant_even_when_leader_exits(self):
        pidfile = self.root / "child.pid"
        child = "import os,time,signal; from pathlib import Path; signal.signal(signal.SIGTERM,signal.SIG_IGN); Path(" + repr(str(pidfile)) + ").write_text(str(os.getpid())); time.sleep(60)"
        parent = "import subprocess,sys,time; subprocess.Popen([sys.executable,'-c'," + repr(child) + "]); time.sleep(.15)"
        runner = release.Runner(self.root / "logs", "fixture", deadline=.6, grace=.2)
        start = time.monotonic()
        code, _ = runner("timeout", [sys.executable, "-c", parent], self.root)
        self.assertEqual(code, 124)
        self.assertLess(time.monotonic() - start, 5)
        pid = int(pidfile.read_text())
        # Linux zombies are dead, awaiting the guest's init reaper, not running children.
        def running():
            proc = Path("/proc") / str(pid) / "stat"
            if proc.exists():
                return proc.read_text().split(") ", 1)[1][0] != "Z"
            try:
                os.kill(pid, 0)
                return True
            except ProcessLookupError:
                return False
        until = time.monotonic() + 2
        while running() and time.monotonic() < until:
            time.sleep(.02)
        self.assertFalse(running())

    def test_gate_plan_keeps_independent_failures_and_binds_built_binaries(self):
        calls = []
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "collector/target/release").mkdir(parents=True)
            for name in release.BINARIES:
                (root / "collector/target/release" / name).write_text("fixture")
            def fake(name, args, cwd, env=None, sensitive=False):
                calls.append((name, list(args), env))
                return (11 if name == "cargo-fmt" else 12 if name == "flutter-analyze" else 0,
                        "test result: ok. 1 passed;\n00:01 +1: All tests passed!")
            self.assertEqual(release.gates(root, "linux", fake, dict(os.environ)), 11)
        names = [x[0] for x in calls]
        self.assertIn("cargo-test", names)
        self.assertIn("flutter-integration", names)
        self.assertIn("flutter-build", names)
        for name, args, env in calls:
            if name in ("flutter-test", "flutter-integration"):
                self.assertTrue(Path(env["CODEX_SESSIONS_COLLECTOR_EXE"]).is_absolute())
                self.assertTrue(Path(env["CODEX_SESSIONS_HUB_EXE"]).is_absolute())
            if name == "cargo-test":
                self.assertIn("--no-fail-fast", args)

    def test_zero_tests_and_missing_sidecars_cannot_pass_gate(self):
        with tempfile.TemporaryDirectory() as tmp:
            calls = []
            def fake(name, args, cwd, env=None, sensitive=False):
                calls.append(name)
                return 0, "test result: ok. 0 passed;"
            self.assertEqual(release.gates(Path(tmp), "linux", fake, dict(os.environ)), 1)
        self.assertNotIn("flutter-test", calls)
        self.assertNotIn("flutter-integration", calls)
        self.assertIn("flutter-build", calls)


if __name__ == "__main__":
    unittest.main()
