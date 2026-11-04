"""Conservative file dependency graph, using only the Python standard library.

Edges point from a consumer to an input. Rust use trees, qualified references,
external mod declarations and CARGO_BIN_EXE references are included regardless
of cfg, so platform/test-only branches can add work but cannot hide a consumer.
This is file/module granularity, not a Rust or Dart type checker.
"""
from pathlib import Path
import re

# Expansion stops here. Changing one of these files itself still selects its
# direct tests (and the lib/root entry changes explicitly widen in the selector).
RUST_HUBS = frozenset({
    "collector/src/lib.rs", "collector/src/main.rs", "collector/src/cli.rs",
    "collector/src/bin/codex-sessions-hub.rs",
    "collector/src/bin/codex-sessions-scan-launcher.rs",
    "collector/src/hub_server.rs", "collector/src/resident/mod.rs",
    "collector/src/store/mod.rs",
})
RUST_SEMANTIC_RULES = {
    "collector/src/resident/*": {"lib", "resident", "scan_launcher", "scan_transport"},
    "collector/src/price_history.rs": {"lib", "price_history_sync", "write_budget"},
    "collector/src/contract.rs": {"lib", "collector_contract", "local_ingestion", "hub_sync"},
}
# Risk-based native sentinels, not every process-spawning test reachable through
# a binary dispatcher. Importing tests are included by full Dart closure.
NATIVE_CONTRACTS = frozenset({
    "app/test/app/collector_ingestion_compat_test.dart",
    "app/test/pricing/hub_price_history_test.dart",
    "app/test/scanner/resident_collector_client_test.dart",
})

def use_paths(statement):
    """Expand nested Rust use trees, including aliases, self and glob imports."""
    tokens = re.findall(r"[A-Za-z_][A-Za-z_0-9]*|::|[{},*]", statement)
    result = []
    position = 0

    def tree(prefix):
        nonlocal position
        path = list(prefix)
        while position < len(tokens):
            token = tokens[position]
            if token in (",", "}"):
                break
            position += 1
            if token == "{":
                while position < len(tokens) and tokens[position] != "}":
                    tree(path)
                    if position < len(tokens) and tokens[position] == ",":
                        position += 1
                if position < len(tokens):
                    position += 1
                return
            if token == "as":
                if position < len(tokens):
                    position += 1
                break
            if token != "::":
                path.append(token)
        if path:
            result.append(tuple(path))

    tree([])
    return result


class DependencyIndex:
    def __init__(self, root):
        self.root = Path(root).resolve()
        self.dependencies = {}
        self.rust_targets = {}
        self.dart_tests = set()
        self.module_names = {}
        self._rust()
        self._dart()
        self._sidecars()
        reverse = {node: set() for node in self.dependencies}
        for consumer, inputs in self.dependencies.items():
            for dependency in inputs:
                reverse.setdefault(dependency, set()).add(consumer)
        # Precompute once, so the whole-tree invariant need not rescan sources
        # once per changed file. No persistent cache can go stale across runs.
        self.affected = {}
        for node in self.dependencies:
            seen, pending = {node}, [node]
            while pending:
                for consumer in reverse.get(pending.pop(), ()):
                    if consumer not in seen:
                        seen.add(consumer)
                        pending.append(consumer)
            self.affected[node] = seen

    def text(self, node):
        return (self.root / node).read_text(encoding="utf-8")

    def _rust(self):
        sources = sorted((self.root / "collector/src").rglob("*.rs"))
        tests = sorted((self.root / "collector/tests").rglob("*.rs"))
        library, local_tests = {}, {}
        for source in sources + tests:
            node = source.relative_to(self.root).as_posix()
            self.dependencies[node] = set()
            if source in sources:
                parts = source.relative_to(self.root / "collector/src").with_suffix("").parts
                if parts[0] == "bin" or parts == ("main",):
                    self.module_names[node] = ()
                    continue
                name = parts[:-1] if parts[-1] in ("mod", "lib") else parts
                library[name] = node
            else:
                parts = source.relative_to(self.root / "collector/tests").with_suffix("").parts
                name = parts[:-1] if parts[-1] == "mod" else parts
                if len(parts) == 1:
                    self.rust_targets[node] = parts[0]
                    # Each integration target is a crate root: `mod support;`
                    # resolves beside target.rs, not target/support.rs.
                    self.module_names[node] = ()
                    continue
                local_tests[name] = node
            self.module_names[node] = name
        self.rust_targets["collector/src/lib.rs"] = "lib"
        self.binaries = {
            "codex-sessions-collector": "collector/src/main.rs",
            "codex-sessions-hub": "collector/src/bin/codex-sessions-hub.rs",
            "codex-sessions-scan-launcher": "collector/src/bin/codex-sessions-scan-launcher.rs",
        }

        for node in list(self.dependencies):
            text = self.text(node)
            # Comments are irrelevant; strings are retained for env! binary
            # references. A qualified name in a string may overselect safely.
            code = re.sub(r"/\*.*?\*/|//[^\n]*", "", text, flags=re.S)
            namespace = library if node.startswith("collector/src/") else local_tests
            current = self.module_names[node]

            def reference(path):
                if not path:
                    return
                if path[0] == "codex_sessions_collector":
                    names, candidate = library, list(path[1:])
                elif path[0] == "crate":
                    names, candidate = namespace, list(path[1:])
                elif path[0] in ("self", "super"):
                    names, candidate = namespace, list(current)
                    offset = 0
                    while offset < len(path) and path[offset] in ("self", "super"):
                        if path[offset] == "super" and candidate:
                            candidate.pop()
                        offset += 1
                    candidate += list(path[offset:])
                else:
                    # Rust 2018 sibling module imports and local mod support.
                    names, candidate = namespace, list(current[:-1]) + list(path)
                    if not any(tuple(candidate[:length]) in names for length in range(1, len(candidate) + 1)):
                        return
                candidate = [part for part in candidate if part not in ("self", "*")]
                explicit_root = not candidate
                while candidate and tuple(candidate) not in names:
                    candidate.pop()
                if not candidate and not explicit_root:
                    return
                dependency = names.get(tuple(candidate))
                if dependency and dependency != node:
                    self.dependencies[node].add(dependency)

            for statement in re.findall(r"\buse\s+([^;]+);", code):
                for path in use_paths(statement):
                    reference(path)
            without_uses = re.sub(r"\buse\s+[^;]+;", "", code)
            for match in re.finditer(r"\b(?:crate|self|super|codex_sessions_collector)(?:::(?:[A-Za-z_][A-Za-z_0-9]*|\*))+", without_uses):
                reference(tuple(match.group().split("::")))
            # A parent module consumes its externally declared modules. This
            # includes test-only files and does not confuse inline mod tests.
            for child in re.findall(r"\bmod\s+([A-Za-z_][A-Za-z_0-9]*)\s*;", code):
                dependency = namespace.get(current + (child,))
                if dependency:
                    self.dependencies[node].add(dependency)
            for binary in re.findall(r'CARGO_BIN_EXE_([A-Za-z_0-9-]+)', text):
                if binary in self.binaries:
                    self.dependencies[node].add(self.binaries[binary])

    def _dart(self):
        for folder in ("lib", "test", "integration_test"):
            for source in sorted((self.root / "app" / folder).rglob("*.dart")):
                node = source.relative_to(self.root).as_posix()
                self.dependencies[node] = set()
                if folder != "lib" and source.name.endswith("_test.dart"):
                    self.dart_tests.add(node)
                # Include every branch of conditional imports/exports and part
                # files; test-to-test imports are ordinary graph edges too.
                for directive in re.findall(r"^\s*(?:import|export|part)\s+([^;]+);", self.text(node), re.M):
                    for uri in re.findall(r"['\"]([^'\"]+\.dart)['\"]", directive):
                        if uri.startswith("package:codex_sessions_viewer/"):
                            dependency = self.root / "app/lib" / uri.split("/", 1)[1]
                        elif ":" not in uri:
                            dependency = source.parent / uri
                        else:
                            continue
                        if dependency.resolve().is_relative_to(self.root):
                            self.dependencies[node].add(dependency.resolve().relative_to(self.root).as_posix())

    def _sidecars(self):
        # Native-client/fixture anchors derive from executable markers. The
        # profile boundary lists environment keys but is not itself a contract
        # that launches every listed sidecar in every importing test.
        plumbing = {"app/test/support/test_environment.dart"}
        for node in list(self.dependencies):
            if not node.endswith(".dart") or node in plumbing:
                continue
            text = self.text(node)
            for kind in ("collector", "hub"):
                if re.search(r"CODEX_SESSIONS_" + kind.upper() + r"_EXE|codex-sessions-" + kind + r"\b", text):
                    self.dependencies[node].add(self.binaries["codex-sessions-" + kind])

    def tests_for(self, changed):
        from fnmatch import fnmatchcase
        if changed.endswith(".dart"):
            affected = self.affected.get(changed, {changed})
            return [], sorted(node.removeprefix("app/") for node in affected & self.dart_tests)
        if changed.startswith("collector/tests/"):
            return ([self.rust_targets[changed]] if changed in self.rust_targets else []), []
        if not changed.startswith("collector/src/"):
            return [], []
        importers = {node for node, dependencies in self.dependencies.items()
                     if node.startswith("collector/src/") and node not in RUST_HUBS
                     and changed in dependencies}
        inputs = {changed} | importers
        rust = {target for node, target in self.rust_targets.items()
                if node == changed or self.dependencies[node] & inputs}
        if changed not in self.binaries.values():
            rust.add("lib")
        for pattern, targets in RUST_SEMANTIC_RULES.items():
            if fnmatchcase(changed, pattern):
                rust |= targets
        dart = set()
        for contract in NATIVE_CONTRACTS:
            dart |= self.affected.get(contract, {contract}) & self.dart_tests
        return sorted(rust), sorted(node.removeprefix("app/") for node in dart)
