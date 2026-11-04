"""Conservative source-to-test rules. Unknown/shared changes select the full gate.

The rules are intentionally owning-contract selections, not a claim of complete
dynamic dependency analysis. Keep the full suite at slice closure and in CI.
"""
import argparse
from fnmatch import fnmatchcase
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
from test_dependencies import DependencyIndex, RUST_HUBS, RUST_SEMANTIC_RULES, NATIVE_CONTRACTS

RUNTIME_MAINTENANCE_CASE = "pricing commits between background scan batches before scan completion"
SHARED = ["*Cargo.toml", "*Cargo.lock", "*pubspec.*", "sql/*", "scripts/*",
          ".github/*", "collector/.cargo/*", "collector/build.rs",
          "collector/tests/support/*", "app/test/support/*", "collector/src/store/*",
          "*flutter_test_config.dart", "app/integration_test/support/*",
          # Identity normalization also controls write-lease lock ownership.
          "collector/src/resident/instance.rs"]
SHARED += sorted(RUST_HUBS)


def dart_dependents(root, changed):
    """Compatibility helper: all reverse Dart import/export/part consumers."""
    return DependencyIndex(root).tests_for(changed)[1]


def select(root, paths, index=None):
    rust, flutter, reasons = set(), set(), []
    normalized = sorted(set(p.replace("\\", "/") for p in paths))
    filters = {}
    unfiltered = set()
    widened = False
    for path in normalized:
        r, f = [], []
        reason = ""
        wide_reason = ""
        if any(fnmatchcase(path, pattern) for pattern in SHARED):
            wide_reason = "shared/high-risk path: full Rust + Flutter + integration tests"
        elif path.startswith("docs/") or path in ("README.md", "CHANGELOG.md"):
            reasons.append({"path": path, "reason": "documentation only", "rust": [], "flutter": []})
            continue
        elif (root / path).is_file() and path.startswith(("collector/", "app/")) and path.endswith((".rs", ".dart")):
            if index is None:
                index = DependencyIndex(root)
            r, f = index.tests_for(path)
            if path.endswith('.rs'):
                expected = set().union(*RUST_SEMANTIC_RULES.values())
                if (expected - set(index.rust_targets.values())
                        or any(not (root / fixture).is_file() for fixture in NATIVE_CONTRACTS)):
                    wide_reason = "stale semantic/native contract target: full suite"
            reason = ("Rust direct references + one non-hub importer hop + semantic map + native sentinels"
                      if path.endswith(".rs") else "reverse Dart imports/exports/parts, including test-to-test edges")
            if path == "app/lib/src/database/application_maintenance.dart":
                runtime = "test/app/runtime_scan_app_test.dart"
                if RUNTIME_MAINTENANCE_CASE in (root / "app" / runtime).read_text(encoding="utf-8"):
                    filters[runtime] = RUNTIME_MAINTENANCE_CASE
                else:
                    wide_reason = "stale named maintenance contract: full suite"
        if wide_reason or not (r or f):
            widened = True
            reason = wide_reason or "unmapped or deleted path: full Rust + Flutter + integration tests"
        rust.update(r)
        flutter.update(f)
        if path != "app/lib/src/database/application_maintenance.dart":
            unfiltered.update(f)
        reasons.append({"path": path, "reason": reason, "rust": r, "flutter": f})
    return {"rust": ["all"] if widened else sorted(rust),
            "flutter": ["test", "integration_test"] if widened else sorted(flutter),
            "flutter_filters": {} if widened else {k: v for k, v in filters.items() if k not in unfiltered},
            "widened": widened, "reasons": reasons}


def changed_paths(root, base):
    # --no-renames includes both sides, so moving out of a shared area widens.
    result = subprocess.run(["git", "diff", "--name-only", "--no-renames", "-z", base, "--"],
                            cwd=root, check=True, capture_output=True)
    untracked = subprocess.run(["git", "ls-files", "--others", "--exclude-standard", "-z"],
                              cwd=root, check=True, capture_output=True)
    return [p.decode("utf-8") for p in (result.stdout + untracked.stdout).split(b"\0") if p]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default="HEAD", help="git diff base, includes staged, unstaged and untracked paths")
    parser.add_argument("--path", action="append", help="explicit hypothetical path, repeatable; replaces git diff")
    parser.add_argument("--dry-run", action="store_true", help="print selection only (this selector never executes tests)")
    args = parser.parse_args()
    print(json.dumps(select(ROOT, args.path if args.path is not None else changed_paths(ROOT, args.base)), indent=2))


if __name__ == "__main__":
    main()
