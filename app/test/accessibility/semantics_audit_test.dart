import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:codex_sessions_viewer/src/database/project_tag_state.dart';
import 'package:codex_sessions_viewer/src/ui/app_shell.dart';
import 'package:codex_sessions_viewer/src/ui/models/projects_repository.dart';
import 'package:codex_sessions_viewer/src/ui/screens/projects_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/isolated_app.dart';
import '../helpers/semantics_audit.dart';
import '../helpers/test_sessions_screen.dart';

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
    final handle = tester.ensureSemantics();
    final app = await createIsolatedApp(tester);
    await tester.pumpWidget(app);
    await _settle(tester);
    expect(
      find.bySemanticsLabel(
        RegExp('^Open terminal and resume unavailable for Unsafe ID fixture'),
      ),
      findsOneWidget,
      reason: 'The audit covers a row whose resume is unavailable.',
    );

    for (final section in CodexAppSection.values) {
      if (section != CodexAppSection.sessions) {
        await tester.tap(
          find.bySemanticsLabel(RegExp('^${section.label} navigation\\nTab ')),
        );
        await _settle(tester);
      }
      await expectSemanticsAuditPasses(tester, context: section.label);
      if (section == CodexAppSection.sessions) {
        await tester.tap(find.text('More filters'));
        await tester.pump();
        await expectSemanticsAuditPasses(
          tester,
          context: 'Sessions with expanded filters',
        );
        await tester.tap(find.text('Codex fixture summary').first);
        await _settle(tester);
        await expectSemanticsAuditPasses(
          tester,
          context: 'Sessions with a selected session',
        );
      }
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await _settle(tester);
    handle.dispose();
  });

  testWidgets('disabled resume actions expose a disabled state', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(home: TestSessionsScreen(initialRows: isolatedAppRows())),
    );
    final unavailable = tester
        .getSemantics(
          find.bySemanticsLabel(
            RegExp('^Open terminal and resume unavailable for No ID fixture'),
          ),
        )
        .getSemanticsData();
    expect(unavailable.flagsCollection.isEnabled, Tristate.isFalse);
    await expectSemanticsAuditPasses(tester, context: 'Unavailable resume');
    handle.dispose();
  });

  testWidgets('a busy Projects screen passes the semantics audit', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repository = _BusyProjectsRepository();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProjectsScreen(
            repository: repository,
            viewState: ProjectsViewState(),
            openProjectName: 'viewer',
            now: () => DateTime.utc(2026, 9, 22, 12),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset all to automatic'));
    await tester.pump();
    expect(repository.pendingReset, isNotNull, reason: 'Screen is busy.');

    final merge = tester
        .getSemantics(
          find.bySemanticsLabel(
            r'Merge F:\projects\viewer into another project',
          ),
        )
        .getSemanticsData();
    expect(merge.flagsCollection.isEnabled, Tristate.isFalse);
    await expectSemanticsAuditPasses(tester, context: 'Busy Projects');

    repository.pendingReset!.complete(
      const ProjectRulesSnapshot(masks: [], manualSessions: {}),
    );
    await tester.pumpAndSettle();
  });
}

/// Lets real database and isolate work finish between frames.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
  }
  // Row update motion hides rows from semantics until it finishes; the first
  // pump starts it, the second completes it.
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));
}

class _BusyProjectsRepository implements ProjectsRepository {
  Completer<ProjectRulesSnapshot>? pendingReset;

  @override
  Future<List<ProjectSummary>> loadProjects() async => [
    ProjectSummary(
      id: 1,
      name: 'viewer',
      sessionCount: 3,
      manualSessionCount: 1,
      folderRuleCount: 0,
      lastActivityUtc: DateTime.utc(2026, 9, 21),
    ),
  ];

  @override
  Future<ProjectDetail> loadProjectDetail(int projectId) async => ProjectDetail(
    projectId: projectId,
    rules: const [],
    detectedFolders: [(folder: r'F:\projects\viewer', sessionCount: 2)],
    manualSessionCount: 1,
  );

  @override
  Future<ProjectRulesSnapshot> resetManualSessions(int projectId) =>
      (pendingReset = Completer<ProjectRulesSnapshot>()).future;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
