import 'package:codex_sessions_viewer/src/database/project_tag_state.dart';
import 'package:codex_sessions_viewer/src/ui/models/projects_repository.dart';
import 'package:codex_sessions_viewer/src/ui/screens/projects_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _empty = ProjectRulesSnapshot(masks: [], manualSessions: {});

class _FakeRepository implements ProjectsRepository {
  _FakeRepository(this.projects, this.details);

  List<ProjectSummary> projects;
  final Map<int, ProjectDetail> details;
  final calls = <String>[];

  @override
  Future<List<ProjectSummary>> loadProjects() async => projects;

  @override
  Future<ProjectDetail> loadProjectDetail(int projectId) async =>
      details[projectId] ??
      ProjectDetail(
        projectId: projectId,
        rules: const [],
        detectedFolders: const [],
        manualSessionCount: 0,
      );

  @override
  Future<ProjectRulesSnapshot> addFolderRule({
    required String folder,
    required String projectName,
  }) async {
    calls.add('add $folder -> $projectName');
    return _empty;
  }

  @override
  Future<ProjectRulesSnapshot> changeFolderRule({
    required String oldFolder,
    required String newFolder,
    required String projectName,
  }) async {
    calls.add('change $oldFolder -> $newFolder');
    return _empty;
  }

  @override
  Future<ProjectRulesSnapshot> moveFolderRule({
    required String folder,
    required String projectName,
  }) async {
    calls.add('move $folder -> $projectName');
    return _empty;
  }

  @override
  Future<ProjectRulesSnapshot> removeFolderRule(String folder) async {
    calls.add('remove $folder');
    return _empty;
  }

  @override
  Future<ProjectRulesSnapshot> mergeProject({
    required int sourceProjectId,
    required String targetName,
  }) async {
    calls.add('merge $sourceProjectId -> $targetName');
    projects = [
      for (final project in projects)
        if (project.id != sourceProjectId) project,
    ];
    return _empty;
  }

  @override
  Future<ProjectRulesSnapshot> resetManualSessions(int projectId) async {
    calls.add('reset $projectId');
    return _empty;
  }

  @override
  Future<void> restore(ProjectRulesSnapshot snapshot) async {
    calls.add('restore');
  }
}

ProjectSummary _project(
  int id,
  String name, {
  DateTime? lastActivity,
  int sessions = 3,
  int rules = 0,
  int manual = 0,
}) => ProjectSummary(
  id: id,
  name: name,
  sessionCount: sessions,
  manualSessionCount: manual,
  folderRuleCount: rules,
  lastActivityUtc: lastActivity,
);

_FakeRepository _repository() => _FakeRepository(
  [
    _project(1, 'viewer', lastActivity: DateTime.utc(2026, 9, 21), rules: 1),
    _project(2, 'viewer-wt', lastActivity: DateTime.utc(2026, 9, 22)),
    _project(3, 'alpha', lastActivity: DateTime.utc(2026, 1, 1), manual: 2),
  ],
  {
    1: ProjectDetail(
      projectId: 1,
      rules: [
        ProjectRuleUsage(
          folder: r'F:\projects',
          sessionCount: 4,
          overriddenBy: {
            const ProjectFolderRule(
              folder: r'F:\projects\viewer-wt',
              projectName: 'viewer-wt',
            ): 2,
          },
        ),
      ],
      detectedFolders: [(folder: r'F:\projects\viewer', sessionCount: 3)],
      manualSessionCount: 0,
    ),
    3: const ProjectDetail(
      projectId: 3,
      rules: [],
      detectedFolders: [],
      manualSessionCount: 2,
    ),
  },
);

Future<void> _pump(
  WidgetTester tester,
  _FakeRepository repository, {
  ProjectsViewState? viewState,
  String? openProjectName,
  void Function(String)? onShowSessions,
}) async {
  await tester.binding.setSurfaceSize(const Size(1400, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ProjectsScreen(
          repository: repository,
          viewState: viewState ?? ProjectsViewState(),
          openProjectName: openProjectName,
          onShowSessions: onShowSessions,
          now: () => DateTime.utc(2026, 9, 22, 12),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

List<String> _listedNames(WidgetTester tester) => [
  for (final tile in tester.widgetList<ListTile>(
    find.byWidgetPredicate(
      (widget) =>
          widget is ListTile &&
          (widget.key?.toString().contains('project-') ?? false),
    ),
  ))
    ((tile.title! as Text).data!),
];

void main() {
  testWidgets('sorts by last activity, by name, and in both directions', (
    tester,
  ) async {
    await _pump(tester, _repository());
    expect(_listedNames(tester), ['viewer-wt', 'viewer', 'alpha']);
    expect(find.text('Newest first'), findsOneWidget);

    await tester.tap(find.text('Newest first'));
    await tester.pumpAndSettle();
    expect(find.text('Oldest first'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(_listedNames(tester), ['alpha', 'viewer', 'viewer-wt']);

    await tester.tap(find.text('Name'));
    await tester.pumpAndSettle();
    expect(find.text('A to Z'), findsOneWidget);
    expect(_listedNames(tester), ['alpha', 'viewer', 'viewer-wt']);

    await tester.tap(find.text('A to Z'));
    await tester.pumpAndSettle();
    expect(_listedNames(tester), ['viewer-wt', 'viewer', 'alpha']);
  });

  testWidgets('sort and search survive leaving the screen', (tester) async {
    final viewState = ProjectsViewState();
    await _pump(tester, _repository(), viewState: viewState);
    await tester.tap(find.text('Name'));
    await tester.enterText(find.byType(TextField), 'view');
    await tester.pumpAndSettle();
    expect(find.text('2 of 3 shown'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await _pump(tester, _repository(), viewState: viewState);

    expect(_listedNames(tester), ['viewer', 'viewer-wt']);
    expect(find.text('2 of 3 shown'), findsOneWidget);
  });

  testWidgets('shows rules, overrides, and detected folders of a project', (
    tester,
  ) async {
    await _pump(tester, _repository(), openProjectName: 'viewer');

    expect(find.text(r'F:\projects'), findsOneWidget);
    expect(find.text('Places 4 sessions'), findsOneWidget);
    expect(
      find.text(
        '2 sessions from here go to "viewer-wt" by the more specific rule '
        r'for F:\projects\viewer-wt.',
      ),
      findsOneWidget,
    );
    expect(find.text(r'F:\projects\viewer'), findsOneWidget);
    await tester.ensureVisible(find.text('Merge into…').last);
    await tester.pumpAndSettle();
    expect(
      find.bySemanticsLabel(r'Merge F:\projects\viewer into another project'),
      findsOneWidget,
    );
    expect(find.text('Set by hand'), findsNothing);
  });

  testWidgets('Ctrl+N adds a folder rule and Undo restores', (tester) async {
    final repository = _repository();
    await _pump(tester, repository, openProjectName: 'viewer');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Folder'),
      r'F:\worktrees\viewer-2',
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Add rule'));
    await tester.pumpAndSettle();

    expect(repository.calls, [r'add F:\worktrees\viewer-2 -> viewer']);
    expect(
      find.text(r'Sessions from F:\worktrees\viewer-2 now belong to "viewer".'),
      findsOneWidget,
    );
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(repository.calls.last, 'restore');
    expect(find.text('Change undone.'), findsOneWidget);
  });

  testWidgets('a rule can be removed from its menu', (tester) async {
    final repository = _repository();
    await _pump(tester, repository, openProjectName: 'viewer');

    await tester.tap(find.byTooltip(r'Actions for the rule for F:\projects'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove rule (Delete)'));
    await tester.pumpAndSettle();

    expect(repository.calls, [r'remove F:\projects']);
  });

  testWidgets('merging a project selects the target afterwards', (
    tester,
  ) async {
    final repository = _repository();
    await _pump(tester, repository, openProjectName: 'viewer-wt');

    await tester.tap(find.widgetWithText(OutlinedButton, 'Merge into…'));
    await tester.pumpAndSettle();
    expect(find.text('Merge "viewer-wt" into…'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Project'),
      'viewer-wt',
    );
    await tester.pump();
    expect(find.text('That is the current project.'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Project'), 'viewer');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(repository.calls, ['merge 2 -> viewer']);
    expect(_listedNames(tester), ['viewer', 'alpha']);
    expect(find.text(r'F:\projects'), findsOneWidget);
  });

  testWidgets('a project can show its sessions', (tester) async {
    final shown = <String>[];
    await _pump(
      tester,
      _repository(),
      openProjectName: 'viewer',
      onShowSessions: shown.add,
    );

    await tester.tap(find.widgetWithText(OutlinedButton, 'Show sessions'));
    await tester.pumpAndSettle();

    expect(shown, ['viewer']);
  });

  testWidgets('sessions set by hand can be reset', (tester) async {
    final repository = _repository();
    await _pump(tester, repository, openProjectName: 'alpha');

    expect(
      find.text('2 sessions were moved here by hand and ignore folder rules.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Reset all to automatic'));
    await tester.pumpAndSettle();

    expect(repository.calls, ['reset 3']);
  });
}
