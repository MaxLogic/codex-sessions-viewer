import 'package:codex_sessions_viewer/src/app/codex_sessions_viewer_app.dart';
import 'package:codex_sessions_viewer/src/ui/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/semantics_audit.dart';

void main() {
  testWidgets('audit detects a button role without an activation action', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Semantics(
          label: 'Broken control',
          button: true,
          enabled: true,
          child: const SizedBox(width: 40, height: 40),
        ),
      ),
    );

    expect(
      collectSemanticsAuditIssues(tester),
      contains(contains('button "Broken control" has no tap action')),
    );
  });

  testWidgets('audit detects an interactive control without a name', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: GestureDetector(
          onTap: () {},
          child: const SizedBox(width: 40, height: 40),
        ),
      ),
    );

    expect(
      collectSemanticsAuditIssues(tester),
      contains(contains('tappable control has no accessible name')),
    );
  });

  testWidgets('audit accepts a named actionable button', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: IconButton(
          tooltip: 'Refresh sessions',
          onPressed: () {},
          icon: const Icon(Icons.refresh),
        ),
      ),
    );

    expect(collectSemanticsAuditIssues(tester), isEmpty);
    await expectSemanticsAuditPasses(tester);
  });

  testWidgets('main application screens pass the semantics audit', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(CodexSessionsViewerApp());
    await tester.pump();

    for (final section in CodexAppSection.values) {
      if (section != CodexAppSection.sessions) {
        await tester.tap(
          find.bySemanticsLabel(RegExp('^${section.label} navigation\\nTab ')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      }
      await expectSemanticsAuditPasses(tester, context: section.label);
      if (section == CodexAppSection.sessions) {
        await tester.tap(find.text('More filters'));
        await tester.pump();
        await expectSemanticsAuditPasses(
          tester,
          context: 'Sessions with expanded filters',
        );
      }
    }
  });
}
