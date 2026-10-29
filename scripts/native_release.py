#!/usr/bin/env python3
"""Native release gates and public-only packaging. Python 3.11+, standard library."""
import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
if sys.version_info < (3, 11):
    raise SystemExit("Native releases require Python 3.11 or newer on PATH.")
import tomllib
import zipfile

VIEWER = "codex_sessions_viewer"
APP_ID = "eu.maxlogic.codexsessionsviewer"
BINARIES = ("codex-sessions-collector", "codex-sessions-hub")


class StepFailure(RuntimeError):
    def __init__(self, name, code):
        super().__init__(f"{name} failed (exit {code}); see release logs")
        self.code = code


class PublicationRecoveryError(OSError):
    """Rollback itself failed: retain staging/previous artifacts for recovery."""


@contextmanager
def staging_directory(parent):
    stage = Path(tempfile.mkdtemp(prefix="cxv-native-stage-", dir=parent))
    retain = False
    try:
        yield stage
    except PublicationRecoveryError:
        retain = True
        raise
    finally:
        if not retain:
            shutil.rmtree(stage)


def publish(stage, output, artifacts):
    """Replace all required artifacts together, retaining old files until success."""
    for source, destination in artifacts:
        if (not destination.parent.resolve().is_relative_to(output)
                or destination.is_symlink()
                or (destination.exists() and not (destination.is_dir() if source.is_dir() else destination.is_file()))):
            raise ValueError("unsafe publication target or parent")
    backups, published = [], []
    try:
        for index, (source, destination) in enumerate(artifacts):
            if destination.exists():
                backup = stage / ("previous-" + str(index))
                os.replace(destination, backup)
                backups.append((backup, destination))
            os.replace(source, destination)
            published.append((destination, stage / ("failed-new-" + str(index))))
    except BaseException as error:
        recovery_errors = []
        for destination, failed in reversed(published):
            try:
                os.replace(destination, failed)
            except OSError as recovery_error:
                recovery_errors.append(recovery_error)
        for backup, destination in reversed(backups):
            try:
                os.replace(backup, destination)
            except OSError as recovery_error:
                recovery_errors.append(recovery_error)
        if recovery_errors:
            raise PublicationRecoveryError(f"Publication rollback failed; previous artifacts retained at {stage}") from error
        raise


def group_alive(pgid):
    """Ignore Linux zombies, which cannot run and may await an init reaper."""
    if sys.platform.startswith("linux"):
        for proc in Path("/proc").iterdir():
            if not proc.name.isdecimal():
                continue
            try:
                fields = (proc / "stat").read_text().split(") ", 1)[1].split()
                if int(fields[2]) == pgid and fields[0] != "Z":
                    return True
            except (OSError, ValueError, IndexError):
                continue
        return False
    # On other POSIX hosts the deliberately unreaped leader can be a zombie.
    # A signal-0 probe would count that zombie as live forever. System ps only
    # supplies group/state metadata; no command lines or user files are read.
    rows = subprocess.run(['/bin/ps', '-axo', 'pgid=,stat='], check=True,
                          capture_output=True, text=True).stdout.splitlines()
    return any(int(fields[0]) == pgid and not fields[1].startswith('Z')
               for line in rows if len(fields := line.split()) == 2)


def stop_group(job, grace):
    if os.name == "nt":
        # Popen retains the original Windows process handle. A PID/tree kill
        # could select a replacement process after the original child exits.
        job.kill()
    else:
        # The runner leaves its original session leader unreaped until group
        # cleanup finishes. Its PID/PGID cannot be reused during this window.
        # Never signal a numeric group after that ownership token was reaped.
        if job.returncode is not None:
            return
        try:
            os.killpg(job.pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        until = time.monotonic() + grace
        while group_alive(job.pid) and time.monotonic() < until:
            time.sleep(.05)
        try:
            os.killpg(job.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    job.wait(timeout=30)


class Runner:
    """A durable log/status per step, with a deadline for its owned POSIX group.

    Native releases are POSIX-only. Windows support here is for cheap fixtures;
    Windows CI runs its unchanged PowerShell pipeline under the CI job deadline.
    """
    def __init__(self, logs, identity, deadline=3600, grace=5):
        self.logs = Path(logs)
        self.logs.mkdir(parents=True, exist_ok=True)
        self.identity = identity
        self.deadline = deadline
        self.grace = grace

    def annotate(self, name, **values):
        path = self.logs / (name + ".json")
        data = json.loads(path.read_text()) if path.exists() else {"step": name, "input_identity": self.identity}
        data.update(values)
        path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")

    def __call__(self, name, args, cwd, env=None, sensitive=False):
        log = self.logs / (name + ".log")
        status = self.logs / (name + ".json")
        start = time.monotonic()
        code, expired, job = 127, False, None
        record = {"step": name, "input_identity": self.identity,
                  "command": ["[configured signing tool]"] if sensitive else [str(x) for x in args],
                  "deadline_seconds": self.deadline}
        print(f"==> {name}", flush=True)
        with log.open("wb") as output:
            try:
                if os.name != 'nt' and not all(hasattr(os, key) for key in ('waitid', 'WNOWAIT')):
                    raise OSError('Safe process-group cleanup requires waitid/WNOWAIT')
                options = {"start_new_session": True} if os.name != "nt" else {
                    "creationflags": subprocess.CREATE_NO_WINDOW | subprocess.CREATE_NEW_PROCESS_GROUP}
                job = subprocess.Popen([str(x) for x in args], cwd=cwd, env=env,
                                       stdin=subprocess.DEVNULL,
                                       stdout=subprocess.DEVNULL if sensitive else output,
                                       stderr=subprocess.DEVNULL if sensitive else subprocess.STDOUT, **options)
                record["pid"] = job.pid
                until = start + self.deadline
                while True:
                    if os.name == 'nt':
                        code = job.poll()
                    else:
                        # Observe without reaping: retain the original PID as
                        # a kernel-owned token even if its descendants outlive it.
                        exited = os.waitid(os.P_PID, job.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
                        code = None if exited is None else exited.si_status if exited.si_code == os.CLD_EXITED else -exited.si_status
                    alive = group_alive(job.pid) if os.name != "nt" else code is None
                    if code is not None and not alive:
                        code = job.wait()
                        break
                    if time.monotonic() >= until:
                        expired = True
                        stop_group(job, self.grace)
                        code = 124
                        break
                    time.sleep(.05)
                if sensitive:
                    output.write(b"Configured signing step: tool output suppressed to protect identity/profile.\n")
            except OSError as error:
                output.write((f"Tool launch failed: {type(error).__name__}\n").encode())
                code = 127
            except BaseException:
                if job is not None:
                    stop_group(job, self.grace)
                raise
            finally:
                record.update(exit_code=code, deadline_expired=expired,
                              duration_seconds=round(time.monotonic() - start, 3))
                status.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
        # Keep caller output bounded; the complete ordinary log stays on disk.
        with log.open("rb") as output:
            output.seek(max(0, log.stat().st_size - 2 * 1024 * 1024))
            text = output.read().decode("utf-8", errors="replace")
        print(f"<== {name}: exit {code} ({record['duration_seconds']}s)", flush=True)
        return code, text


def require_step(run, name, args, cwd, env=None, sensitive=False):
    code, text = run(name, args, cwd, env, sensitive)
    if code:
        raise StepFailure(name, code)
    return text


def private(path):
    name = path.name.lower()
    return (name in {"settings.toml", "profiles", "profile", ".git", ".ds_store"}
            or name.endswith((".db", ".sqlite", ".sqlite3", ".db-wal", ".db-shm",
                              ".sqlite-wal", ".sqlite-shm", ".sqlite3-wal", ".sqlite3-shm")))


def validate_tree(root):
    root = root.resolve()
    for base, folders, files in os.walk(root, followlinks=False):
        for name in folders + files:
            path = Path(base) / name
            if path.is_symlink():
                link = os.readlink(path)
                try:
                    target = path.resolve(strict=True)
                except (OSError, RuntimeError) as error:
                    raise ValueError("dangling or cyclic symlink in bundle") from error
                if Path(link).is_absolute() or not target.is_relative_to(root):
                    raise ValueError("unsafe symlink escaping portable bundle")
            elif not path.is_dir() and not path.is_file():
                raise ValueError("unsupported special file in bundle")


def overlaps(a, b):
    return a == b or a.is_relative_to(b) or b.is_relative_to(a)


def validate_output(repo, native, binaries, output):
    if output.is_symlink() or (output / "macos").is_symlink() or (output / "linux").is_symlink():
        raise ValueError("symlinked output is unsafe")
    output = output.resolve()
    protected = [native, binaries, repo / "app", repo / "collector", repo / "sql",
                 repo / "assets", repo / "settings.sample.toml", repo / "README.md"]
    if output == repo.resolve() or any(overlaps(output, p.resolve()) for p in protected):
        raise ValueError("output/source overlap is unsafe")
    if output == Path(output.anchor):
        raise ValueError("root output is unsafe")
    return output


def public_copy(source, destination):
    validate_tree(source)
    shutil.copytree(source, destination, symlinks=True,
                    ignore=lambda base, names: [name for name in names if private(Path(name))])
    validate_tree(destination)


def versions(repo):
    match = re.search(r"^version:\s*([0-9]+\.[0-9]+\.[0-9]+(?:[-+][\w.+-]+)?)\s*$",
                      (repo / "app/pubspec.yaml").read_text(), re.MULTILINE)
    if match is None:
        raise ValueError("pubspec app version is missing")
    cargo = tomllib.loads((repo / "collector/Cargo.toml").read_text())
    return match.group(1), cargo["package"]["version"]


def zip_bundle(bundle, archive):
    """POSIX ZIP: store symlinks as links and retain executable permissions."""
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as output:
        for path in sorted(bundle.rglob("*")):
            info = zipfile.ZipInfo(path.relative_to(bundle.parent).as_posix() + ("/" if path.is_dir() and not path.is_symlink() else ""))
            info.create_system = 3
            info.external_attr = path.lstat().st_mode << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            if path.is_symlink():
                output.writestr(info, os.readlink(path).encode())
            elif path.is_file():
                with path.open("rb") as source, output.open(info, "w") as destination:
                    shutil.copyfileobj(source, destination)
            else:
                output.writestr(info, b"")


def macos_zip(bundle, archive, run):
    # Apple's ditto retains resource forks/extended metadata, including tickets.
    name = "create-notary-zip" if archive.name == "notary-upload.zip" else "create-release-zip"
    require_step(run, name, ["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent",
                            str(bundle), str(archive)], bundle.parent)
    if not archive.is_file():
        raise ValueError("macOS archiver did not produce its archive")


def sha256(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def manifest_data(bundle, target, app_version, collector_version):
    entries = []
    for path in sorted(bundle.rglob("*")):
        if path.is_symlink():
            entries.append({"path": path.relative_to(bundle).as_posix(), "symlink": os.readlink(path)})
        elif path.is_file():
            entries.append({"path": path.relative_to(bundle).as_posix(),
                            "sha256": sha256(path),
                            "mode": stat.S_IMODE(path.stat().st_mode)})
    return {"target": target, "app_version": app_version,
            "collector_version": collector_version, "files": entries}


def sign_macos(bundle, run, identity):
    # Sign embedded executable code inside-out; never add sandbox entitlements.
    frameworks = bundle / "Contents/Frameworks"
    candidates = []
    if frameworks.exists():
        for path in frameworks.rglob("*"):
            if not path.is_symlink() and (path.suffix in {".framework", ".dylib", ".app", ".xpc"}):
                candidates.append(path)
    for index, path in enumerate(sorted(candidates, key=lambda p: len(p.parts), reverse=True)):
        require_step(run, f"sign-runtime-{index}", ["codesign", "--force", "--options", "runtime",
                      "--timestamp", "--sign", identity, str(path)], bundle.parent, sensitive=True)
    for index, name in enumerate(BINARIES):
        require_step(run, "sign-sidecar-" + ("collector" if index == 0 else "hub"),
                     ["codesign", "--force", "--options", "runtime", "--timestamp", "--sign",
                      identity, str(bundle / "Contents/MacOS" / name)], bundle.parent, sensitive=True)
    require_step(run, "sign-app", ["codesign", "--force", "--options", "runtime", "--timestamp",
                 "--sign", identity, str(bundle)], bundle.parent, sensitive=True)
    require_step(run, "verify-signature", ["codesign", "--verify", "--deep", "--strict", str(bundle)], bundle.parent)


def package(repo, native, binaries, output, target, run, identity=None, profile=None,
            zip_writer=zip_bundle):
    repo, native, binaries = Path(repo).resolve(), Path(native).resolve(), Path(binaries).resolve()
    if target not in {"linux", "macos"}:
        raise ValueError("unsupported native target")
    if profile and not identity:
        raise ValueError("notarization profile requires a signing identity")
    output = validate_output(repo, native, binaries, Path(output))
    validate_tree(native)
    app_version, collector_version = versions(repo)
    if (repo / "settings.sample.toml").is_symlink() or not (repo / "settings.sample.toml").is_file():
        raise ValueError("sample settings must be a public regular file")
    for name in BINARIES:
        path = binaries / name
        if not path.is_file() or path.is_symlink():
            raise ValueError("missing or symlinked native sidecar")
    # Create staging beside output; all prior delivery artifacts survive failures.
    output.parent.mkdir(parents=True, exist_ok=True)
    with staging_directory(output.parent) as stage:
        bundle = stage / ("linux" if target == "linux" else VIEWER + ".app")
        public_copy(native, bundle)
        exe_dir = bundle if target == "linux" else bundle / "Contents/MacOS"
        resources = bundle / "data" if target == "linux" else bundle / "Contents/Resources"
        if not (exe_dir / VIEWER).is_file():
            raise ValueError("missing native viewer executable")
        for name in BINARIES:
            if (exe_dir / name).is_symlink():
                raise ValueError("symlinked native sidecar destination")
            shutil.copy2(binaries / name, exe_dir / name)
            (exe_dir / name).chmod((exe_dir / name).stat().st_mode | 0o111)
        resources.mkdir(parents=True, exist_ok=True)
        for name in ("sql", "assets"):
            destination = resources / name
            if destination.exists():
                shutil.rmtree(destination)
            public_copy(repo / name, destination)
        if (resources / "settings.sample.toml").is_symlink():
            raise ValueError("symlinked sample settings destination")
        shutil.copy2(repo / "settings.sample.toml", resources / "settings.sample.toml")
        readme = repo / "README.md"
        if readme.is_file() and not readme.is_symlink():
            shutil.copy2(readme, resources / "README.md")
        else:
            (resources / "README.md").write_text("# Codex Session Viewer\nSee docs/release-validation.md for native installation.\n")
        if (repo / "LICENSE").is_file():
            shutil.copy2(repo / "LICENSE", resources / "LICENSE")
        validate_tree(bundle)
        text = require_step(run, "collector-version", [str(exe_dir / BINARIES[0]), "version"], stage)
        if not re.search(r"^codex-sessions-collector " + re.escape(collector_version) + r"(?:\s|$)", text, re.MULTILINE):
            raise ValueError("bundled collector version does not match Cargo package version")
        if target == "linux":
            for required in (bundle / (APP_ID + ".desktop"), resources / (APP_ID + ".png"),
                             resources / "flutter_assets", bundle / "lib"):
                if not required.exists():
                    raise ValueError("incomplete Linux runtime/identity resources")
        else:
            for required in (bundle / "Contents/Info.plist", bundle / "Contents/Frameworks",
                             bundle / "Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets"):
                if not required.exists():
                    raise ValueError("incomplete macOS runtime resources")
            if identity:
                sign_macos(bundle, run, identity)
            else:
                # Added public resources/sidecars change the generated app seal.
                for index, name in enumerate(BINARIES):
                    require_step(run, "adhoc-sidecar-" + str(index),
                                 ["codesign", "--force", "--sign", "-", str(exe_dir / name)], stage)
                require_step(run, "adhoc-app", ["codesign", "--force", "--sign", "-", str(bundle)], stage)
                require_step(run, "verify-adhoc", ["codesign", "--verify", "--deep", "--strict", str(bundle)], stage)
        archive = stage / (VIEWER + ("_linux.tar.gz" if target == "linux" else "_macos.zip"))
        if profile:
            # Apple's upload ZIP precedes stapling; the distributed ZIP is recreated afterwards.
            upload = stage / "notary-upload.zip"
            zip_writer(bundle, upload)
            require_step(run, "notarize", ["xcrun", "notarytool", "submit", str(upload),
                         "--keychain-profile", profile, "--wait"], stage, sensitive=True)
            require_step(run, "staple", ["xcrun", "stapler", "staple", str(bundle)], stage)
            require_step(run, "validate-staple", ["xcrun", "stapler", "validate", str(bundle)], stage)
        # Metadata lives outside the sealed macOS app, so signing is not invalidated.
        if target == "linux":
            (bundle / "release-manifest.json").write_text(json.dumps(
                manifest_data(bundle, target, app_version, collector_version), indent=2) + "\n", encoding="utf-8")
            with tarfile.open(archive, "w:gz", dereference=False) as tar:
                tar.add(bundle, arcname=bundle.name)
        else:
            zip_writer(bundle, archive)
        metadata_file = None
        if target == "macos":
            # Generate/hash/write metadata before any existing delivery is touched.
            metadata = manifest_data(bundle, target, app_version, collector_version)
            metadata.update(archive=archive.name, archive_sha256=sha256(archive))
            metadata_file = stage / "release-manifest.json"
            metadata_file.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
        output.mkdir(parents=True, exist_ok=True)
        destination = output / "linux" if target == "linux" else output / "macos" / bundle.name
        destination.parent.mkdir(parents=True, exist_ok=True)
        archive_destination = output / archive.name
        artifacts = [(bundle, destination), (archive, archive_destination)]
        if metadata_file is not None:
            artifacts.append((metadata_file, output / "macos/release-manifest.json"))
        publish(stage, output, artifacts)
        return destination, archive_destination


def gates(repo, target, run, env):
    """Run independent gates even after failure; packaging requires every gate."""
    app, cargo = repo / "app", repo / "collector"
    env = dict(env)
    env["CARGO_BUILD_JOBS"] = "2"
    env["CMAKE_BUILD_PARALLEL_LEVEL"] = "2"
    first = 0
    def gate(name, args, cwd, environment):
        code, text = run(name, args, cwd, environment)
        if name in {"cargo-test", "flutter-test", "flutter-integration"}:
            if name == "cargo-test":
                count = sum(int(x) for x in re.findall(r"test result: ok\. (\d+) passed;", text))
            else:
                count = max([int(x) for x in re.findall(r"\+(\d+)", text)] or [0]) if "All tests passed!" in text else 0
            if isinstance(run, Runner):
                run.annotate(name, test_count=count, positive_test_count=count > 0)
            if code == 0 and count == 0:
                print(f"{name}: no positive executed-test count; acceptance failed", flush=True)
                code = 1
        return code
    steps = [("flutter-version", ["flutter", "--version"], app),
             ("cargo-fmt", ["cargo", "fmt", "--check"], cargo),
             ("cargo-clippy", ["cargo", "clippy", "--locked", "--all-targets", "--", "-D", "warnings"], cargo),
             ("cargo-test", ["cargo", "test", "--locked", "--no-fail-fast"], cargo),
             ("cargo-build", ["cargo", "build", "--locked", "--release", "--bins"], cargo),
             ("flutter-pub", ["flutter", "pub", "get"], app),
             ("dart-format", ["dart", "format", "--set-exit-if-changed", "."], app),
             ("flutter-analyze", ["flutter", "analyze"], app)]
    cargo_built = False
    for name, args, cwd in steps:
        code = gate(name, args, cwd, env)
        first = first or code
        if name == "cargo-build":
            cargo_built = code == 0 and all((cargo / "target/release" / name).is_file() for name in BINARIES)
            if not cargo_built:
                first = first or 1
    if cargo_built:
        test_env = {**env, "CODEX_SESSIONS_COLLECTOR_EXE": str((cargo / "target/release" / BINARIES[0]).resolve()),
                    "CODEX_SESSIONS_HUB_EXE": str((cargo / "target/release" / BINARIES[1]).resolve())}
        for name, args in [("flutter-test", ["flutter", "test"]),
                           ("flutter-integration", ["flutter", "test", "integration_test"])]:
            code = gate(name, args, app, test_env)
            first = first or code
    else:
        print("Flutter tests blocked: just-built native sidecars are missing or their build failed", flush=True)
        if isinstance(run, Runner):
            for name in ("flutter-test", "flutter-integration"):
                run.annotate(name, status="blocked", reason="just-built sidecars unavailable")
    code, _ = run("flutter-build", ["flutter", "build", target, "--release"], app, env)
    return first or code


def input_identity(repo):
    digest = hashlib.sha256()
    for root in ("app/lib", "app/assets", "app/test", "app/integration_test", "app/linux", "app/macos", "collector/src", "collector/tests", "collector/benches", "sql", "assets", "scripts"):
        for path in sorted((repo / root).rglob("*")):
            if path.is_file() and not path.is_symlink() and "ephemeral" not in path.parts and "__pycache__" not in path.parts:
                digest.update(path.relative_to(repo).as_posix().encode())
                digest.update(path.read_bytes())
    for name in ("app/pubspec.yaml", "app/pubspec.lock", "app/analysis_options.yaml", "collector/Cargo.toml", "collector/Cargo.lock", "collector/.cargo/config.toml", "settings.sample.toml"):
        path = repo / name
        digest.update(name.encode())
        digest.update(path.read_bytes())
    return digest.hexdigest()


def ninja_shim(directory, ninja):
    shim = Path(directory) / "ninja"
    # Subtools (-t restat, used by CMake) take their own arguments and build nothing.
    shim.write_text("#!/usr/bin/env python3\nimport os,sys\nargs=sys.argv[1:]\n"
                    "if '-t' not in args:\n    args += ['-j2']\n"
                    "os.execv(" + repr(str(ninja)) + ", [" + repr(str(ninja)) + "] + args)\n")
    shim.chmod(0o755)
    return shim


def xcrun_shim(directory, xcrun):
    shim = Path(directory) / "xcrun"
    shim.write_text("#!/usr/bin/env python3\nimport os,sys\nargs=sys.argv[1:]\n"
                    "if args[:1] == ['xcodebuild'] and ('-workspace' in args or '-project' in args):\n"
                    "    args += ['-jobs', '2']\n"
                    "os.execv(" + repr(str(xcrun)) + ", [" + repr(str(xcrun)) + "] + args)\n")
    shim.chmod(0o755)
    return shim


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", choices=("linux", "macos"))
    args = parser.parse_args()
    expected = "Linux" if args.target == "linux" else "Darwin"
    if platform.system() != expected:
        parser.error(f"{args.target} releases require a native {expected} host")
    repo = Path(__file__).resolve().parent.parent
    env = dict(os.environ)
    identity = env.get("CXV_MACOS_SIGN_IDENTITY") or None
    profile = env.get("CXV_MACOS_NOTARY_PROFILE") or None
    if args.target == "macos" and profile and not identity:
        parser.error("CXV_MACOS_NOTARY_PROFILE requires CXV_MACOS_SIGN_IDENTITY")
    tools = ["flutter", "dart", "cargo"] + (["ninja", "cmake", "clang++", "pkg-config"] if args.target == "linux" else ["xcodebuild", "xcrun", "ditto", "codesign"])
    for tool in tools:
        if not shutil.which(tool):
            parser.error(f"required native tool not found: {tool}")
    run_id = time.strftime("%Y%m%d-%H%M%S") + "-" + str(os.getpid())
    logs = repo / "release/logs" / (args.target + "-" + run_id)
    runner = Runner(logs, input_identity(repo))
    try:
        # Flutter invokes literal 'ninja'; a local PATH shim enforces -j2 without SDK edits.
        with tempfile.TemporaryDirectory(prefix="cxv-native-tools-") as tmp:
            if args.target == "linux":
                ninja = shutil.which("ninja")
                ninja_shim(tmp, ninja)
                env["PATH"] = tmp + os.pathsep + env["PATH"]
            else:
                xcrun_shim(tmp, shutil.which("xcrun"))
                env["PATH"] = tmp + os.pathsep + env["PATH"]
            code = gates(repo, args.target, runner, env)
            if code:
                return code
        if args.target == "linux":
            matches = list((repo / "app/build/linux").glob("*/release/bundle"))
            if len(matches) != 1:
                raise ValueError("expected exactly one native Linux release bundle")
            native = matches[0]
        else:
            native = repo / "app/build/macos/Build/Products/Release" / (VIEWER + ".app")
        folder, archive = package(repo, native, repo / "collector/target/release", repo / "release",
                                  args.target, runner, identity if args.target == "macos" else None,
                                  profile if args.target == "macos" else None,
                                  zip_writer=lambda bundle, archive: macos_zip(bundle, archive, runner))
        print(f"Native release prepared: {folder}\nArchive: {archive}\nLogs: {logs}")
        return 0
    except StepFailure as error:
        print(str(error), file=sys.stderr)
        return error.code
    except (ValueError, OSError) as error:
        print(f"Native release failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
