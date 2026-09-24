import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// Returns accessibility defects found in the semantics currently rendered by
/// [tester]. This checks the generated semantics tree, not widget source code.
List<String> collectSemanticsAuditIssues(WidgetTester tester) {
  final handle = tester.ensureSemantics();
  try {
    final issues = <String>[];
    for (final view in tester.binding.renderViews) {
      final root = view.owner?.semanticsOwner?.rootSemanticsNode;
      if (root != null) {
        _auditNode(root, issues);
      }
    }
    return issues;
  } finally {
    handle.dispose();
  }
}

Future<void> expectSemanticsAuditPasses(
  WidgetTester tester, {
  String? context,
}) async {
  await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
  final issues = collectSemanticsAuditIssues(tester);
  expect(
    issues,
    isEmpty,
    reason: [
      if (context != null) '$context semantics audit failed.',
      ...issues,
    ].join('\n'),
  );
}

void _auditNode(SemanticsNode node, List<String> issues) {
  node.visitChildren((child) {
    _auditNode(child, issues);
    return true;
  });

  if (node.isMergedIntoParent ||
      node.isInvisible ||
      node.flagsCollection.isHidden) {
    return;
  }

  final data = node.getSemanticsData();
  final name = data.label.trim().isNotEmpty
      ? data.label.trim()
      : data.tooltip.trim();
  final hasTap = data.hasAction(ui.SemanticsAction.tap);
  final hasLongPress = data.hasAction(ui.SemanticsAction.longPress);
  final hasIncrease = data.hasAction(ui.SemanticsAction.increase);
  final hasDecrease = data.hasAction(ui.SemanticsAction.decrease);
  final hasDismiss = data.hasAction(ui.SemanticsAction.dismiss);
  final hasUserAction =
      hasTap || hasLongPress || hasIncrease || hasDecrease || hasDismiss;

  if (hasUserAction && name.isEmpty && !data.flagsCollection.isTextField) {
    issues.add(
      'Semantics node ${node.id}: tappable control has no accessible name.',
    );
  }

  if (data.flagsCollection.isEnabled == ui.Tristate.isFalse) {
    return;
  }

  if ((data.flagsCollection.isButton || data.flagsCollection.isLink) &&
      !hasTap) {
    final role = data.flagsCollection.isLink ? 'link' : 'button';
    issues.add(
      'Semantics node ${node.id}: $role "${_displayName(name)}" has no tap action.',
    );
  }

  final hasToggleState =
      data.flagsCollection.isToggled != ui.Tristate.none ||
      data.flagsCollection.isChecked != ui.CheckedState.none;
  if (hasToggleState && !hasTap) {
    issues.add(
      'Semantics node ${node.id}: toggle "${_displayName(name)}" has no tap action.',
    );
  }

  if (data.flagsCollection.isSlider && !hasIncrease && !hasDecrease) {
    issues.add(
      'Semantics node ${node.id}: slider "${_displayName(name)}" has no increase or decrease action.',
    );
  }
}

String _displayName(String name) => name.isEmpty ? '<unnamed>' : name;
