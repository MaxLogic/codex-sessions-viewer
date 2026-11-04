"""Whole-tree selection invariant; direct graph plus independent reverse BFS.

The four review witnesses validate the graph oracle before testing selection.
This check is intentionally not limited to those historical examples.
"""
from collections import deque
from pathlib import Path
import unittest

from fast_tests import select
from test_dependencies import DependencyIndex, use_paths, RUST_HUBS, RUST_SEMANTIC_RULES, NATIVE_CONTRACTS
from fnmatch import fnmatchcase

ROOT = Path(__file__).resolve().parents[1]


class DependencyInvariantTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.index = DependencyIndex(ROOT)
        cls.reverse = {}
        for consumer, dependencies in cls.index.dependencies.items():
            for dependency in dependencies:
                cls.reverse.setdefault(dependency, set()).add(consumer)

    def references(self, changed):
        found = {changed}
        queue = deque([changed])
        while queue:
            node = queue.popleft()
            for consumer in self.reverse.get(node, ()):
                if consumer not in found:
                    found.add(consumer)
                    queue.append(consumer)
        return found

    def test_use_tree_expansion(self):
        self.assertEqual(set(use_paths('crate::{store::{write_budget as budget, self}, price_history::{self, History}}')),
                         {('crate', 'store', 'write_budget'), ('crate', 'store', 'self'),
                          ('crate', 'price_history', 'self'), ('crate', 'price_history', 'History')})

    def test_review_witnesses_are_in_oracle_and_selected(self):
        cases = [
            ('collector/src/price_history.rs', 'collector/tests/write_budget.rs'),
            ('collector/src/price_history.rs', 'app/test/pricing/hub_price_history_test.dart'),
            ('collector/src/contract.rs', 'collector/tests/hub_sync.rs'),
            ('app/test/pricing/hub_price_history_test.dart', 'app/test/pricing/local_price_confirmation_test.dart'),
        ]
        for changed, consumer in cases:
            with self.subTest(changed=changed, consumer=consumer):
                self.assertIn(consumer, self.references(changed), 'oracle must discover the reviewed edge')
                plan = select(ROOT, [changed], index=self.index)
                if consumer.endswith('.rs'):
                    self.assertTrue('all' in plan['rust'] or Path(consumer).stem in plan['rust'])
                else:
                    self.assertTrue(plan['widened'] or consumer.removeprefix('app/') in plan['flutter'])

    def test_every_real_module_and_dart_file_obeys_bounded_rust_and_transitive_dart_rule(self):
        failures = []
        checked = 0
        for changed in sorted(self.index.dependencies):
            if not (changed.startswith('collector/src/') or changed.endswith('.dart')):
                continue
            checked += 1
            plan = select(ROOT, [changed], index=self.index)
            if plan['widened']:
                continue
            if changed.endswith('.dart'):
                rust = set()
                dart = {node.removeprefix('app/') for node in self.references(changed) & self.index.dart_tests}
            else:
                # Independent direct + one-hop calculation. Never walk through
                # dispatcher hubs or a process's binary entry point.
                rust = set()
                for node, target in self.index.rust_targets.items():
                    direct = self.index.dependencies[node]
                    if node == changed or changed in direct:
                        rust.add(target)
                    for module in direct:
                        if (module.startswith('collector/src/') and module not in RUST_HUBS
                                and changed in self.index.dependencies[module]):
                            rust.add(target)
                if changed not in self.index.binaries.values():
                    rust.add('lib')
                for pattern, targets in RUST_SEMANTIC_RULES.items():
                    if fnmatchcase(changed, pattern):
                        rust |= targets
                dart = set()
                for contract in NATIVE_CONTRACTS:
                    dart |= {node.removeprefix('app/') for node in self.references(contract) & self.index.dart_tests}
            missing_rust = rust - set(plan['rust'])
            missing_dart = dart - set(plan['flutter'])
            if changed.endswith(".rs") and (set(plan["rust"]) - rust):
                failures.append(f"{changed}: extra Rust beyond bounded rule={sorted(set(plan['rust']) - rust)}")
            if missing_rust or missing_dart:
                failures.append(f'{changed}: missing Rust={sorted(missing_rust)}, Flutter={sorted(missing_dart)}')
        print(f'Whole-tree invariant checked {checked} Rust source modules/Dart files; {len(failures)} uncovered selections.')
        self.assertEqual(failures, [], '\n'.join(failures))


if __name__ == '__main__':
    unittest.main()
