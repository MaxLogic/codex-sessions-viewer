import 'dart:io';

import 'package:codex_sessions_viewer/src/app/runtime_session_controller.dart';
import 'package:codex_sessions_viewer/src/app/codex_sessions_viewer_app.dart';
import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/database/database_migrator.dart';
import 'package:codex_sessions_viewer/src/ui/screens/sessions_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

void main() {
  test(
    'runtime scan loads settings, persists parsed sessions, and returns rows',
    () async {
      final temp = await Directory.systemTemp.createTemp('csv_runtime_scan_');
      addTearDown(() async {
        if (await temp.exists()) {
          await temp.delete(recursive: true);
        }
      });

      final windowsRoot = Directory(p.join(temp.path, 'windows'));
      final wslRoot = Directory(p.join(temp.path, 'wsl'));
      await windowsRoot.create();
      await wslRoot.create();
      await _copyFixture('sample_windows_session.json', windowsRoot);
      await _copyFixture('sample_wsl_session.json', wslRoot);

      final settingsFile = File(p.join(temp.path, 'settings.toml'));
      await SettingsRepository(settingsFile).save(
        AppSettings.defaults().copyWith(
          paths: PathSettings(
            windowsCodexPath: windowsRoot.path,
            wslCodexUncPath: wslRoot.path,
          ),
          wsl: WslSettings(
            distro: 'Ubuntu',
            linuxHome: '/home/pawel',
            linuxRootUnc: '${wslRoot.path}${Platform.pathSeparator}',
          ),
        ),
      );

      final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
      final startup = await DatabaseMigrator(
        sqlRoot: Directory(p.normalize(p.join('..', 'sql'))),
      ).openAndMigrate(databaseFile);
      expect(startup.canStartNormalUi, isTrue);

      final controller = RuntimeSessionController(
        settingsFile: settingsFile,
        databaseFile: databaseFile,
      );
      final result = await controller.refresh();

      expect(result.rows, hasLength(2));
      expect(
        result.rows.map((row) => row.platformLabel),
        containsAll(['Windows', 'WSL']),
      );
      expect(result.statusMessage, contains('Scan finished'));

      final db = sqlite3.open(databaseFile.path);
      addTearDown(db.close);
      expect(
        db.select('select count(*) as count from sessions').single['count'],
        2,
      );
      expect(
        db
            .select('select count(*) as count from session_search')
            .single['count'],
        2,
      );
    },
  );

  test(
    'runtime refresh hides a previously parsed session after source deletion',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'csv_runtime_scan_missing_',
      );
      addTearDown(() async {
        if (await temp.exists()) {
          await temp.delete(recursive: true);
        }
      });

      final windowsRoot = Directory(p.join(temp.path, 'windows'));
      final wslRoot = Directory(p.join(temp.path, 'wsl'));
      await windowsRoot.create();
      await wslRoot.create();
      final fixture = await _copyFixture(
        'sample_windows_session.json',
        windowsRoot,
      );

      final settingsFile = File(p.join(temp.path, 'settings.toml'));
      await SettingsRepository(settingsFile).save(
        AppSettings.defaults().copyWith(
          paths: PathSettings(
            windowsCodexPath: windowsRoot.path,
            wslCodexUncPath: wslRoot.path,
          ),
        ),
      );
      final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
      final startup = await DatabaseMigrator(
        sqlRoot: Directory(p.normalize(p.join('..', 'sql'))),
      ).openAndMigrate(databaseFile);
      expect(startup.canStartNormalUi, isTrue);

      final controller = RuntimeSessionController(
        settingsFile: settingsFile,
        databaseFile: databaseFile,
      );
      expect((await controller.refresh()).rows, hasLength(1));

      await fixture.delete();
      final secondResult = await controller.refresh();

      expect(secondResult.rows, isEmpty);
      final db = sqlite3.open(databaseFile.path);
      addTearDown(db.close);
      final row = db.select(
        'select scan_status from sessions where source_file_path = ?',
        [fixture.path],
      ).single;
      expect(row['scan_status'], 'missing');
    },
  );

  testWidgets('production refresh distinguishes path errors from empty roots', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: SessionsScreen(
          onRefreshResult: () async {
            calls++;
            return const SessionsRefreshResult(
              rows: [],
              statusMessage:
                  r'Scan finished. Session root is unreachable. Unreachable paths: \\wsl.localhost\Ubuntu\home\pawel\.codex',
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('Refresh'));
    await tester.pumpAndSettle();

    expect(calls, 1);
    expect(find.textContaining('Session root is unreachable'), findsOneWidget);
    expect(
      find.text('Codex session path is currently unreachable.'),
      findsOneWidget,
    );
    expect(find.text('Test WSL path'), findsOneWidget);
    expect(find.text('Open Settings'), findsOneWidget);
    expect(
      find.textContaining(
        r'Configured path: \\wsl.localhost\Ubuntu\home\pawel\.codex',
      ),
      findsOneWidget,
    );
    expect(find.text('No sessions found.'), findsNothing);
  });

  testWidgets('refresh failure clears scanning state and shows error', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: SessionsScreen(
          onRefreshResult: () async {
            calls++;
            throw const FormatException('Invalid settings.toml');
          },
        ),
      ),
    );

    await tester.tap(find.text('Refresh'));
    await tester.pumpAndSettle();

    expect(calls, 1);
    expect(find.text('Refresh'), findsOneWidget);
    expect(find.textContaining('Refresh failed'), findsOneWidget);
    expect(find.textContaining('Invalid settings.toml'), findsOneWidget);
  });

  test('runtime refresh does not show root errors as session rows', () async {
    final temp = await Directory.systemTemp.createTemp(
      'csv_runtime_scan_empty_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });

    final emptyRoot = Directory(p.join(temp.path, 'empty'));
    await emptyRoot.create();
    final missingRoot = p.join(temp.path, 'missing');
    final settingsFile = File(p.join(temp.path, 'settings.toml'));
    await SettingsRepository(settingsFile).save(
      AppSettings.defaults().copyWith(
        paths: PathSettings(
          windowsCodexPath: emptyRoot.path,
          wslCodexUncPath: missingRoot,
        ),
      ),
    );
    final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
    final startup = await DatabaseMigrator(
      sqlRoot: Directory(p.normalize(p.join('..', 'sql'))),
    ).openAndMigrate(databaseFile);
    expect(startup.canStartNormalUi, isTrue);

    final result = await RuntimeSessionController(
      settingsFile: settingsFile,
      databaseFile: databaseFile,
    ).refresh();

    expect(result.rows, isEmpty);
    expect(result.statusMessage, contains('Session root is unreachable'));
    expect(result.statusMessage, contains(missingRoot));
  });

  test('runtime refresh distinguishes empty reachable roots', () async {
    final temp = await Directory.systemTemp.createTemp(
      'csv_runtime_scan_empty_reachable_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });

    final windowsRoot = Directory(p.join(temp.path, 'windows'));
    final wslRoot = Directory(p.join(temp.path, 'wsl'));
    await windowsRoot.create();
    await wslRoot.create();
    final settingsFile = File(p.join(temp.path, 'settings.toml'));
    await SettingsRepository(settingsFile).save(
      AppSettings.defaults().copyWith(
        paths: PathSettings(
          windowsCodexPath: windowsRoot.path,
          wslCodexUncPath: wslRoot.path,
        ),
      ),
    );
    final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
    final startup = await DatabaseMigrator(
      sqlRoot: Directory(p.normalize(p.join('..', 'sql'))),
    ).openAndMigrate(databaseFile);
    expect(startup.canStartNormalUi, isTrue);

    final result = await RuntimeSessionController(
      settingsFile: settingsFile,
      databaseFile: databaseFile,
    ).refresh();

    expect(result.rows, isEmpty);
    expect(result.statusMessage, contains('No supported files found'));
  });

  testWidgets('empty reachable scans show a no-sessions empty state', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SessionsScreen(
          initialStatusMessage: 'Scan finished. No supported files found.',
        ),
      ),
    );

    expect(find.text('No sessions found.'), findsOneWidget);
    expect(find.text('Refresh'), findsOneWidget);
    expect(find.text('Open Settings'), findsOneWidget);
  });

  testWidgets('filters hiding rows show a clear-filters empty state', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SessionsScreen(
          initialRows: [_row('visible-row', SessionRowPlatform.windows)],
        ),
      ),
    );

    await tester.enterText(find.bySemanticsLabel('Session search'), 'nomatch');
    await tester.pumpAndSettle();

    expect(find.text('No sessions match the current filters.'), findsOneWidget);
    expect(find.text('Clear filters'), findsWidgets);
  });

  testWidgets('app shell wires runtime refresh into the Sessions screen', (
    tester,
  ) async {
    var refreshCalls = 0;
    await tester.pumpWidget(
      CodexSessionsViewerApp(
        databaseStartup: Future.value(
          DatabaseStartupResult.ready(lastAppliedSchemaVersion: 3),
        ),
        sessionRefresh: () async {
          refreshCalls++;
          return SessionsRefreshResult.scanFinished([
            _row('runtime-row', SessionRowPlatform.windows),
          ]);
        },
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Refresh'));
    await tester.pumpAndSettle();

    expect(refreshCalls, 1);
    expect(find.text('runtime-row'), findsOneWidget);
  });

  testWidgets(
    'production empty-state actions open settings and retry path test',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      var refreshCalls = 0;
      await tester.pumpWidget(
        CodexSessionsViewerApp(
          databaseStartup: Future.value(
            DatabaseStartupResult.ready(lastAppliedSchemaVersion: 3),
          ),
          sessionRefresh: () async {
            refreshCalls++;
            return const SessionsRefreshResult(
              rows: [],
              statusMessage:
                  r'Scan finished. Session root is unreachable. Unreachable paths: \\wsl.localhost\Ubuntu\home\pawel\.codex',
            );
          },
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();
      expect(refreshCalls, 1);

      await tester.tap(find.text('Test WSL path'));
      await tester.pumpAndSettle();
      expect(refreshCalls, 2);

      await tester.tap(find.text('Open Settings'));
      await tester.pumpAndSettle();
      expect(find.text('Save settings'), findsOneWidget);
    },
  );
}

Future<File> _copyFixture(String name, Directory destination) async {
  final source = File(p.normalize(p.join('..', 'samples', 'sessions', name)));
  return source.copy(p.join(destination.path, name));
}

SessionRowViewModel _row(String title, SessionRowPlatform platform) {
  return SessionRowViewModel(
    id: title,
    startedAtUtc: DateTime.utc(2026, 6, 14, 10),
    lastMessageAtUtc: DateTime.utc(2026, 6, 14, 11),
    platform: platform,
    project: 'Codex Viewer',
    path: r'C:\Users\pawel\.codex\sessions\runtime.jsonl',
    title: title,
    summary: 'Loaded from runtime scan',
    messageCount: 1,
    totalTokens: 42,
    model: 'gpt-5.4',
    tags: const [],
    status: 'available',
  );
}
