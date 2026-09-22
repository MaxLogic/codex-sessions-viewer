import 'package:codex_sessions_viewer/src/database/project_tag_state.dart';
import 'package:codex_sessions_viewer/src/ui/dialogs/move_to_project_dialog.dart';
import 'package:codex_sessions_viewer/src/ui/models/session_project_change.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _worktree = SessionProjectAssignment(
  projectName: 'viewer-wt',
  isManual: false,
  detectedProjectName: 'viewer-wt',
  workingDirectory: r'F:\projects\viewer-wt',
  folderRule: null,
  projectNames: ['viewer', 'viewer-wt'],
);

void main() {
  Future<List<SessionProjectChange?>> open(
    WidgetTester tester,
    SessionProjectAssignment assignment,
  ) async {
    final results = <SessionProjectChange?>[];
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => results.add(
                await showMoveToProjectDialog(context, assignment: assignment),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    return results;
  }

  testWidgets('moves one session to an existing project', (tester) async {
    final results = await open(tester, _worktree);
    expect(find.text('In "viewer-wt", detected from its folder.'), findsOne);
    final move = find.widgetWithText(FilledButton, 'Move');
    expect(tester.widget<FilledButton>(move).onPressed, isNull);

    await tester.enterText(find.byType(TextField), 'viewer');
    await tester.pump();
    await tester.tap(move);
    await tester.pumpAndSettle();

    expect(results.single, isA<MoveSessionToProject>());
    expect((results.single! as MoveSessionToProject).projectName, 'viewer');
  });

  testWidgets('merges a worktree folder and names a new project', (
    tester,
  ) async {
    final results = await open(tester, _worktree);
    await tester.enterText(find.byType(TextField), 'Merged');
    await tester.pump();
    expect(find.text('Creates a new project named "Merged".'), findsOne);

    await tester.tap(find.text('Every session from a folder'));
    await tester.pump();
    final folder = find.widgetWithText(TextField, 'Folder');
    expect(
      tester.widget<TextField>(folder).controller!.text,
      r'F:\projects\viewer-wt',
    );
    await tester.enterText(folder, r'F:\projects\worktrees');
    await tester.tap(find.widgetWithText(FilledButton, 'Move'));
    await tester.pumpAndSettle();

    final change = results.single! as MoveFolderToProject;
    expect(change.folder, r'F:\projects\worktrees');
    expect(change.projectName, 'Merged');
  });

  testWidgets('offers to remove the folder rule that placed the session', (
    tester,
  ) async {
    final results = await open(
      tester,
      const SessionProjectAssignment(
        projectName: 'viewer',
        isManual: false,
        detectedProjectName: 'viewer-wt',
        workingDirectory: r'F:\projects\viewer-wt',
        folderRule: ProjectFolderRule(
          folder: r'F:\projects\viewer-wt',
          projectName: 'viewer',
        ),
        projectNames: ['viewer', 'viewer-wt'],
      ),
    );
    await tester.tap(find.text('Remove folder rule'));
    await tester.pumpAndSettle();

    expect(
      (results.single! as RemoveFolderRule).folder,
      r'F:\projects\viewer-wt',
    );
  });

  testWidgets('a session set by hand can return to its detected project', (
    tester,
  ) async {
    final results = await open(
      tester,
      const SessionProjectAssignment(
        projectName: 'Side quest',
        isManual: true,
        detectedProjectName: 'viewer-wt',
        workingDirectory: r'F:\projects\viewer-wt',
        folderRule: null,
        projectNames: ['Side quest', 'viewer', 'viewer-wt'],
      ),
    );
    expect(find.text('In "Side quest", set by hand.'), findsOne);
    await tester.tap(find.text('Use the detected project ("viewer-wt")'));
    await tester.pumpAndSettle();

    expect(results.single, isA<ResetSessionProject>());
  });

  testWidgets('without a working folder only this session can move', (
    tester,
  ) async {
    await open(
      tester,
      const SessionProjectAssignment(
        projectName: null,
        isManual: false,
        detectedProjectName: null,
        workingDirectory: null,
        folderRule: null,
        projectNames: [],
      ),
    );
    expect(find.text('This session has no working folder.'), findsOne);
    await tester.tap(find.text('Every session from a folder'));
    await tester.pump();
    expect(find.widgetWithText(TextField, 'Folder'), findsNothing);
  });
}
