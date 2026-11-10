import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:codex_sessions_viewer/src/app/runtime_session_controller.dart';
import 'package:codex_sessions_viewer/src/app/codex_sessions_viewer_app.dart';
import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/config/parsed_with_settings.dart';
import 'package:codex_sessions_viewer/src/database/database_connection.dart'
    hide Row;
import 'package:codex_sessions_viewer/src/database/database_migrator.dart';
import 'package:codex_sessions_viewer/src/scanner/resident_collector_client.dart';
import 'package:codex_sessions_viewer/src/ui/screens/sessions_screen.dart';
import 'package:codex_sessions_viewer/src/ui/screens/settings_screen.dart';
import 'package:codex_sessions_viewer/src/ui/widgets/reparse_settings_notice.dart';
import 'package:codex_sessions_viewer/src/ui/themes.dart';
import 'package:codex_sessions_viewer/src/ui/scan_activity.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/scripted_collector_bridge.dart';

AppSettings _settings(int preview) => AppSettings.fromTomlMap({
  'tool_output': {'max_tool_output_preview_chars': preview},
  'pricing': {'use_external_pricing': false},
});

class _Fixture {
  late Directory root;
  late File settingsFile;
  late File databaseFile;
  late RuntimeSessionController runtime;
  late ResidentCollectorClient client;
  late final ScriptedBridge bridge;
  late final Completer<Map<String, dynamic>> requested;
  CancellableSessionScanOperation? operation;

  Future<void> initialize() async {
    bridge = ScriptedBridge();
    requested = Completer<Map<String, dynamic>>();
    root = await Directory.systemTemp.createTemp('cxv220-');
    settingsFile = File(p.join(root.path, 'settings.toml'));
    databaseFile = File(p.join(root.path, 'viewer.sqlite'));
    await DatabaseMigrator(
      sqlRoot: Directory('../sql'),
    ).openAndMigrate(databaseFile);
    await SettingsRepository(settingsFile).save(_settings(4000));
    client = ResidentCollectorClient(
      databaseFile: databaseFile,
      settingsFile: settingsFile,
      start: (_, _) async {
        bridge.emit({'event': 'bridge', 'state': 'connected'});
        return bridge;
      },
    );
    runtime = RuntimeSessionController(
      settingsFile: settingsFile,
      databaseFile: databaseFile,
      collectorClient: client,
      claudeProjectRoots: const [],
    );
    bridge.onRequest = (request) {
      if (request['op'] == 'scan') requested.complete(request);
      if (request['op'] == 'cancel') finish(cancelled: true);
    };
  }

  Future<ParsedWithSettings> recorded() =>
      runtime.loadParsedWithSettings(_settings(8000));

  SessionsRefreshOperation reparse(SessionsRefreshProgressCallback progress) {
    operation = runtime.startRefreshOperation(
      force: true,
      onProgress: progress,
    );
    return SessionsRefreshOperation(
      result: operation!.result,
      cancel: operation!.cancel,
    );
  }

  void finish({
    bool cancelled = false,
    bool failed = false,
    bool unreachable = false,
  }) {
    final id = requested.future;
    unawaited(
      id.then((request) {
        bridge.emit({
          'id': request['id'],
          'event': 'finished',
          'command': 'codex scan',
          'files_found': 1,
          'files_parsed': failed ? 0 : 1,
          'files_failed': failed ? 1 : 0,
          'all_configured_roots_reachable': !unreachable,
          'errors': [],
        });
        bridge.emit({
          'id': request['id'],
          'event': 'done',
          'cancelled': cancelled,
        });
      }),
    );
  }

  Future<void> dispose() async {
    await client.dispose();
    await root.delete(recursive: true);
  }
}

void main() {
  final evidenceDirectory = Platform.environment['CXV_EVIDENCE_DIR'];
  testWidgets('C03 reload refreshes form despite failed history metadata', (
    tester,
  ) async {
    final metadata = Completer<ParsedWithSettings>();
    metadata.future.ignore();
    AppSettings? saved;
    final next = _settings(
      8000,
    ).copyWith(ui: _settings(8000).ui.copyWith(fontSize: 22));
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          initialSettings: _settings(4000),
          parsedWithSettings: metadata.future,
          reloadParsedWithSettings: () => metadata.future,
          onReparse: (_) => throw StateError('must not scan'),
          onReload: () async => next,
          onSave: (settings) async {
            saved = settings;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    metadata.completeError(StateError('history metadata unavailable'));
    await tester.tap(find.text('Reload from file'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('Settings reloaded.'), findsOneWidget);
    await tester.ensureVisible(find.text('Data and cache'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining(
        'Could not read the values stored sessions were parsed with.',
      ),
      findsOneWidget,
    );
    await tester.ensureVisible(find.text('Font size (pixels)'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, '22'), findsOneWidget);
    // Cancel must restore the reloaded baseline, and Save must use its parse values.
    await tester.ensureVisible(find.text('Cancel changes'));
    await tester.tap(find.text('Cancel changes'));
    await tester.tap(find.text('Save settings'));
    await tester.pumpAndSettle();
    expect(saved!.ui.fontSize, 22);
    expect(saved!.toolOutput.maxToolOutputPreviewChars, 8000);
  }, timeout: const Timeout(Duration(seconds: 20)));

  for (final scenario in [
    'cached failure',
    'refresh failure',
    'finished scan',
  ]) {
    testWidgets('UX5 app status speech: $scenario', (tester) async {
      final semantics = tester.ensureSemantics();

      final fixture = _Fixture();
      final completion = Completer<SessionsRefreshResult>();
      VoidCallback? loadCache;
      await tester.runAsync(() async {
        await fixture.initialize();
        await tester.pumpWidget(
          CodexSessionsViewerApp(
            settingsFile: fixture.settingsFile,
            databaseFile: fixture.databaseFile,
            settingsStartup: Future.value(_settings(4000)),
            collectorClient: fixture.client,
            deferInitialSessionLoad: (callback) {
              loadCache = callback;
            },
            sessionCachedRowsLoader: (_) async =>
                throw StateError('fixture cache unavailable'),
            usageSummaryLoader: (_, _) async => null,
            sessionRefreshOperation: (_) => SessionsRefreshOperation(
              result: completion.future,
              cancel: () async {},
            ),
          ),
        );
      });
      addTearDown(() => tester.runAsync(fixture.dispose));
      await tester.pumpAndSettle();
      try {
        late String expected;
        if (scenario == 'cached failure') {
          loadCache!();
          await tester.pumpAndSettle();
          expected =
              'Failed to load cached sessions. Bad state: fixture cache unavailable';
        } else {
          await tester.tap(find.text('Refresh'));
          await tester.pump();
          if (scenario == 'refresh failure') {
            completion.completeError(
              const CollectorRequestException('busy', 'fixture raw detail'),
            );
            expected = collectionRefreshError(
              const CollectorRequestException('busy', 'fixture raw detail'),
            );
          } else {
            completion.complete(
              const SessionsRefreshResult(
                rows: [],
                statusMessage: 'Scan finished. 2 sessions visible.',
              ),
            );
            expected = 'Scan finished. 2 sessions available.';
          }
          await tester.pumpAndSettle();
        }
        expect(find.text(expected), findsOneWidget);
        final status = tester.getSemantics(find.bySemanticsLabel(expected));
        expect(status.label, expected);
        expect(status.flagsCollection.isLiveRegion, isTrue);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
        await tester.runAsync(fixture.client.stop);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      }
    }, timeout: const Timeout(Duration(seconds: 20)));
  }

  testWidgets('C02 app reparse force and navigation retain working Cancel', (
    tester,
  ) async {
    final fixture = _Fixture();
    await tester.runAsync(() async {
      await fixture.initialize();
      await fixture.runtime.loadParsedWithSettings(_settings(4000));
      await SettingsRepository(fixture.settingsFile).save(_settings(8000));
    });
    addTearDown(() => tester.runAsync(fixture.dispose));
    await tester.runAsync(() async {
      fixture.client.requestPort;
      await tester.pumpWidget(
        CodexSessionsViewerApp(
          settingsFile: fixture.settingsFile,
          databaseFile: fixture.databaseFile,
          settingsStartup: Future.value(_settings(8000)),
          collectorClient: fixture.client,
          deferInitialSessionLoad: (_) {},
          usageSummaryLoader: (_, _) async => null,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    Future<void> section(String name) async {
      await tester.tap(
        find.bySemanticsLabel(RegExp('^$name navigation\\nTab ')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
    }

    await section('Settings');
    await tester.runAsync(() async {
      await tester.tap(find.text('Reload from file'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    // Complete the real startup metadata read before interacting.
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Data and cache'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Reparse all sessions'));
    try {
      await tester.runAsync(() async {
        await tester.tap(find.text('Reparse all sessions'));
        final request = await fixture.requested.future.timeout(
          const Duration(seconds: 3),
        );
        expect(
          request['force'],
          isTrue,
          reason: 'Exercise the actual app onReparse wiring.',
        );
      });
      await tester.pump();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'Cancel scan');
      await section('Sessions');
      expect(find.text('Cancel scan'), findsWidgets);
      // A competing normal refresh must join, never replace the app operation.
      final sessions = tester.widget<SessionsScreen>(
        find.byType(SessionsScreen),
      );
      final joined = sessions.onRefreshOperation!((_) {});
      await tester.pump();
      expect(
        fixture.bridge.received.where((r) => r['op'] == 'scan'),
        hasLength(1),
      );
      await section('Settings');
      await tester.ensureVisible(find.text('Data and cache'));
      await tester.pump();
      expect(
        find.byKey(const Key('reparse-cancel-scan')),
        findsOneWidget,
        reason:
            'Reviewer navigation probe: cancellation survives widget disposal.',
      );
      await tester.ensureVisible(find.byKey(const Key('reparse-cancel-scan')));
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('reparse-cancel-scan')));
        await joined.result.timeout(const Duration(seconds: 3));
      });
      await tester.pumpAndSettle();
      expect(
        fixture.bridge.received.where((r) => r['op'] == 'cancel'),
        hasLength(1),
      );
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'Session scan status',
        reason: 'User cancellation moves focus even after notice remount.',
      );
    } finally {
      fixture.finish();
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 25));
        });
        await tester.pump();
      }
      await tester.runAsync(fixture.client.stop);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    }
  }, timeout: const Timeout(Duration(seconds: 20)));

  for (final changedSettings in [false, true]) {
    testWidgets(
      'UX8 leaving Sessions cancels an ordinary scan; forced race joins without overwriting (changed settings: $changedSettings)',
      (tester) async {
        final fixture = _Fixture();
        late Completer<SessionsRefreshResult> completion;
        var starts = 0;
        var cancels = 0;
        await tester.runAsync(() async {
          await fixture.initialize();
          completion = Completer<SessionsRefreshResult>();
          await fixture.runtime.loadParsedWithSettings(_settings(4000));
          await SettingsRepository(
            fixture.settingsFile,
          ).save(_settings(changedSettings ? 8000 : 4000));
          await tester.pumpWidget(
            CodexSessionsViewerApp(
              settingsFile: fixture.settingsFile,
              databaseFile: fixture.databaseFile,
              settingsStartup: Future.value(
                _settings(changedSettings ? 8000 : 4000),
              ),
              collectorClient: fixture.client,
              deferInitialSessionLoad: (_) {},
              usageSummaryLoader: (_, _) async => null,
              sessionRefreshOperation: (_) {
                starts++;
                return SessionsRefreshOperation(
                  result: completion.future,
                  cancel: () async {
                    cancels++;
                    completion.complete(
                      const SessionsRefreshResult(
                        rows: [],
                        statusMessage: 'Scan cancelled.',
                        cancelled: true,
                      ),
                    );
                  },
                );
              },
            ),
          );
        });
        addTearDown(() => tester.runAsync(fixture.dispose));
        await tester.pumpAndSettle();
        final sessions = tester.widget<SessionsScreen>(
          find.byType(SessionsScreen),
        );
        final normal = sessions.onRefreshOperation!((_) {});
        await tester.pump();
        try {
          // Exercise the opposite C02 race before navigation disposes Sessions.
          // A forced request must join the ordinary scan without replacing it.
          await tester.tap(
            find.bySemanticsLabel(RegExp('^Settings navigation\\nTab ')),
          );
          await tester.pump();
          final screen = tester.widget<SettingsScreen>(
            find.byType(SettingsScreen),
          );
          final joined = screen.onReparse!((_) {});
          expect(identical(joined, normal), isTrue);
          expect(starts, 1);
          expect(
            fixture.bridge.received.where((r) => r['op'] == 'scan'),
            isEmpty,
          );
          await tester.pump(const Duration(milliseconds: 300));
          await tester.pump();
          expect(find.byType(SessionsScreen), findsNothing);
          expect(
            cancels,
            1,
            reason: 'Leaving Sessions cancels an ordinary scan.',
          );
          await tester.runAsync(
            () => normal.result.timeout(const Duration(seconds: 3)),
          );
          await tester.pumpAndSettle();
          expect(screen.scanActivity!.running, isFalse);
          expect(completion.isCompleted, isTrue);
          expect(
            (await tester.runAsync(
              fixture.recorded,
            ))!.values['tool_output.max_tool_output_preview_chars'],
            4000,
          );
        } finally {
          if (!completion.isCompleted) {
            completion.complete(
              const SessionsRefreshResult(
                rows: [],
                statusMessage: 'Scan completed.',
              ),
            );
          }
          await tester.runAsync(fixture.client.stop);
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
        }
      },
      timeout: const Timeout(Duration(seconds: 20)),
    );
  }

  test(
    'foreign completion cannot finish a forced request or record values',
    () async {
      final fixture = _Fixture();
      await fixture.initialize();
      addTearDown(fixture.dispose);
      await fixture.runtime.loadParsedWithSettings(_settings(4000));
      await SettingsRepository(fixture.settingsFile).save(_settings(8000));
      final operation = fixture.runtime.startRefreshOperation(force: true);
      final request = await fixture.requested.future.timeout(
        const Duration(seconds: 3),
      );
      var finished = false;
      final completion = operation.result.then((result) {
        finished = true;
        return result;
      });
      fixture.bridge.emit({
        'id': 'foreign-normal-request',
        'event': 'finished',
        'files_parsed': 1,
      });
      fixture.bridge.emit({
        'id': 'foreign-normal-request',
        'event': 'done',
        'cancelled': false,
      });
      // A protocol round-trip proves the foreign events were consumed before checking.
      fixture.bridge.onRequest = (message) {
        if (message['op'] == 'ingest') {
          fixture.bridge.emit({'id': message['id'], 'event': 'done'});
        }
      };
      await fixture.client
          .ingest(
            sourcePath: p.join(fixture.root.path, 'foreign.jsonl'),
            harness: 'codex',
          )
          .timeout(const Duration(seconds: 3));
      expect(finished, isFalse);
      expect(
        (await fixture.recorded())
            .values['tool_output.max_tool_output_preview_chars'],
        4000,
      );
      expect(request['force'], isTrue);
      fixture.finish();
      await completion.timeout(const Duration(seconds: 3));
      expect(
        (await fixture.recorded())
            .values['tool_output.max_tool_output_preview_chars'],
        8000,
      );
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );

  for (final change in [
    'edited',
    'edit and revert',
    'invalid edited file',
    'foreign scan',
  ]) {
    test('C01 $change never records forced scan values', () async {
      final fixture = _Fixture();
      await fixture.initialize();
      addTearDown(fixture.dispose);
      await fixture.runtime.loadParsedWithSettings(_settings(4000));
      await SettingsRepository(fixture.settingsFile).save(_settings(8000));
      final before = await fixture.settingsFile.readAsString();
      final beforeStat = await fixture.settingsFile.stat();
      final operation = fixture.runtime.startRefreshOperation(
        force: change != 'foreign scan',
      );
      await fixture.requested.future.timeout(const Duration(seconds: 3));
      if (change != 'foreign scan') {
        await SettingsRepository(fixture.settingsFile).save(_settings(12000));
        if (change == 'invalid edited file') {
          await fixture.settingsFile.writeAsString('not valid [toml');
        }
        if (change == 'edit and revert') {
          await fixture.settingsFile.writeAsString(before);
          // Explicitly advance the fixture timestamp, independent of FS clock resolution.
          await fixture.settingsFile.setLastModified(
            beforeStat.modified.add(const Duration(seconds: 2)),
          );
        }
      }
      fixture.finish();
      final result = await operation.result.timeout(const Duration(seconds: 3));
      expect(
        (await fixture.recorded())
            .values['tool_output.max_tool_output_preview_chars'],
        4000,
      );
      if (change != 'foreign scan') {
        expect(
          result.statusMessage,
          contains('Settings changed during the reparse'),
        );
      }
    }, timeout: const Timeout(Duration(seconds: 20)));
  }

  testWidgets(
    'evidence: Data and cache reparse notice',
    (tester) async {
      await tester.runAsync(() async {
        for (final entry in {
          'Segoe UI': r'C:\Windows\Fonts\segoeui.ttf',
          'Roboto':
              r'C:\tools\flutter\bin\cache\artifacts\material_fonts\roboto-regular.ttf',
          'MaterialIcons':
              r'C:\tools\flutter\bin\cache\artifacts\material_fonts\materialicons-regular.otf',
        }.entries) {
          final font = FontLoader(entry.key);
          font.addFont(
            File(
              entry.value,
            ).readAsBytes().then((bytes) => ByteData.view(bytes.buffer)),
          );
          await font.load();
        }
      });
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final key = GlobalKey();
      final activity = ScanActivity();
      addTearDown(activity.dispose);
      final completion = Completer<SessionsRefreshResult>();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: CodexAppTheme.themeData(CodexThemeMode.dark),
            home: SettingsScreen(
              initialSettings: _settings(8000),
              parsedWithSettings: Future.value(
                ParsedWithSettings.capture(_settings(4000)),
              ),
              reloadParsedWithSettings: () async =>
                  ParsedWithSettings.capture(_settings(4000)),
              scanActivity: activity,
              onReparse: (_) {
                final operation = SessionsRefreshOperation(
                  result: completion.future,
                  cancel: () async {},
                );
                activity.start(operation, force: true);
                return operation;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Data and cache'));
      await tester.pumpAndSettle();
      Future<void> capture(String filename) => tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          p.join(evidenceDirectory!, filename),
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await capture('settings-reparse-notice-r4.png');
      await tester.ensureVisible(find.text('Reparse all sessions'));
      await tester.tap(find.text('Reparse all sessions'));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('reparse-cancel-scan')));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.ensureVisible(find.text('Data and cache'));
      await tester.pump();
      await capture('settings-reparse-running-r4.png');
      const result = SessionsRefreshResult(
        rows: [],
        statusMessage: 'Reparse finished. History parsing settings recorded.',
      );
      completion.complete(result);
      activity.finish(result.statusMessage);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Data and cache'));
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'Session scan status',
      );
      await capture('settings-reparse-focused-status-r4.png');
    },
    skip: evidenceDirectory == null || !Platform.isWindows,
    timeout: const Timeout(Duration(seconds: 20)),
  );
  test(
    'background reparse carries force through isolate and records its values',
    () async {
      final fixture = _Fixture();
      await fixture.initialize();
      addTearDown(fixture.dispose);
      await fixture.runtime.loadParsedWithSettings(_settings(4000));
      await SettingsRepository(fixture.settingsFile).save(_settings(8000));
      final operation = fixture.runtime.startRefreshInBackgroundOperation(
        force: true,
      );
      final request = await fixture.requested.future.timeout(
        const Duration(seconds: 5),
      );
      expect(request['force'], isTrue);
      fixture.finish();
      final result = await operation.result.timeout(const Duration(seconds: 5));
      expect(result.cancelled, isFalse);
      expect(
        (await fixture.recorded())
            .values['tool_output.max_tool_output_preview_chars'],
        8000,
      );
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );

  testWidgets(
    'metadata read failure remains visible without a reparse action',
    (tester) async {
      final metadata = Completer<ParsedWithSettings>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReparseSettingsNotice(
              settings: _settings(8000),
              parsedWith: metadata.future,
              reloadParsedWith: () async => throw StateError('must not reload'),
              onReparse: (_) => throw StateError('must not reparse'),
            ),
          ),
        ),
      );
      metadata.completeError(StateError('fixture metadata read failed'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining(
          'Could not read the values stored sessions were parsed with.',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('fixture metadata read failed'),
        findsOneWidget,
      );
      expect(find.text('Reparse all sessions'), findsNothing);
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );
  testWidgets(
    'fresh upgrade and nonparse changes stay quiet; reload shows changes and reverting hides them',
    (tester) async {
      final fixture = _Fixture();
      late ParsedWithSettings initial;
      await tester.runAsync(() async {
        await fixture.initialize();
        initial = await fixture.runtime.loadParsedWithSettings(_settings(4000));
      });
      addTearDown(() => tester.runAsync(fixture.dispose));
      var next = _settings(
        4000,
      ).copyWith(ui: _settings(4000).ui.copyWith(fontSize: 18));
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            initialSettings: _settings(4000),
            parsedWithSettings: Future.value(initial),
            reloadParsedWithSettings: fixture.recorded,
            onReparse: fixture.reparse,
            onReload: () async => next,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Reparse all sessions'), findsNothing);
      await tester.tap(find.text('Reload from file'));
      await tester.pumpAndSettle();
      expect(find.text('Reparse all sessions'), findsNothing);
      next = _settings(8000);
      await tester.tap(find.text('Reload from file'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Tool output preview length (tool_output.max_tool_output_preview_chars): changed from 4000 to 8000 characters.',
        ),
        findsOneWidget,
      );
      expect(find.text('Reparse all sessions'), findsOneWidget);
      expect(fixture.bridge.received.where((r) => r['op'] == 'scan'), isEmpty);
      expect(
        find.text(
          'Settings reloaded. History parsing settings changed; reparse available in Data and cache.',
        ),
        findsOneWidget,
      );
      next = _settings(4000);
      await tester.tap(find.text('Reload from file'));
      await tester.pumpAndSettle();
      expect(find.text('Reparse all sessions'), findsNothing);
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );

  for (final outcome in [
    'success',
    'cancel',
    'error',
    'partial',
    'unreachable',
    'changed during scan',
    'metadata write failure',
  ]) {
    testWidgets(
      'reparse $outcome uses forced resident scan and preserves correct history values',
      (tester) async {
        final fixture = _Fixture();
        late ParsedWithSettings initial;
        await tester.runAsync(() async {
          await fixture.initialize();
          initial = await fixture.runtime.loadParsedWithSettings(
            _settings(4000),
          );
          await SettingsRepository(fixture.settingsFile).save(_settings(8000));
          if (outcome == 'metadata write failure') {
            final db = openFileBackedDatabase(fixture.databaseFile);
            try {
              db.execute(
                "create trigger refuse_parsed_with before update on app_metadata when new.key = '${ParsedWithSettingsStore.metadataKey}' begin select raise(abort, 'fixture metadata write failed'); end",
              );
            } finally {
              db.close();
            }
          }
        });
        addTearDown(() => tester.runAsync(fixture.dispose));
        final semantics = tester.ensureSemantics();
        try {
          var current = _settings(8000);
          final parsedWith = Future.value(initial);
          Future<void> render() => tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: ReparseSettingsNotice(
                  settings: current,
                  parsedWith: parsedWith,
                  reloadParsedWith: fixture.recorded,
                  onReparse: fixture.reparse,
                ),
              ),
            ),
          );
          await render();
          await tester.pumpAndSettle();
          expect(
            find.bySemanticsLabel('History parsing settings changed'),
            findsOneWidget,
          );
          final button = find.bySemanticsLabel('Reparse all sessions');
          final data = tester.getSemantics(button).getSemanticsData();
          expect(data.flagsCollection.isButton, isTrue);
          expect(data.hasAction(ui.SemanticsAction.tap), isTrue);
          // Tab and Enter exercise the production button's keyboard action.
          await tester.runAsync(() async {
            await tester.sendKeyEvent(LogicalKeyboardKey.tab);
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
            expect(
              fixture.operation,
              isNotNull,
              reason:
                  'Keyboard activation must start the scan before awaiting its IPC request.',
            );
            final request = await fixture.requested.future.timeout(
              const Duration(seconds: 3),
              onTimeout: () => throw StateError(
                'request boundary; received=${fixture.bridge.received}; operation=${fixture.operation != null}',
              ),
            );
            expect(
              request['force'],
              isTrue,
              reason: 'Every reparse must force unchanged files too.',
            );
          });
          await tester.pump();
          expect(find.text('Cancel scan'), findsOneWidget);
          if (outcome == 'changed during scan') {
            current = _settings(12000);
            await tester.runAsync(
              () => SettingsRepository(fixture.settingsFile).save(current),
            );
            await render();
          }
          await tester.runAsync(() async {
            if (outcome == 'cancel') {
              await tester.tap(find.text('Cancel scan'));
            } else if (outcome == 'error') {
              fixture.bridge.emit({
                'id': (await fixture.requested.future)['id'],
                'event': 'error',
                'code': 'refused',
                'message': 'fixture scan failed',
              });
            } else {
              fixture.finish(
                failed: outcome == 'partial',
                unreachable: outcome == 'unreachable',
              );
            }
            try {
              await fixture.operation!.result.timeout(
                const Duration(seconds: 3),
              );
            } on Object {
              if (outcome != 'error' && outcome != 'metadata write failure') {
                rethrow;
              }
            }
          });
          await tester.pumpAndSettle();
          final success = outcome == 'success';
          late ParsedWithSettings recorded;
          await tester.runAsync(() async {
            recorded = await fixture.recorded();
          });
          expect(
            recorded.values['tool_output.max_tool_output_preview_chars'],
            success ? 8000 : 4000,
          );
          expect(
            find.text('Reparse all sessions'),
            outcome == 'success' ? findsNothing : findsOneWidget,
          );
          if (outcome == 'changed during scan') {
            expect(
              find.text(
                'Tool output preview length (tool_output.max_tool_output_preview_chars): changed from 4000 to 12000 characters.',
              ),
              findsOneWidget,
            );
          }
          if (outcome == 'error') {
            expect(find.textContaining('fixture scan failed'), findsOneWidget);
          }
          if (outcome == 'metadata write failure') {
            expect(
              find.textContaining('fixture metadata write failed'),
              findsOneWidget,
            );
          }
          if (outcome == 'cancel') {
            expect(find.textContaining('Scan cancelled.'), findsOneWidget);
          }
          if (outcome == 'partial') {
            expect(find.textContaining('could not be parsed.'), findsOneWidget);
          }
          if (outcome == 'unreachable') {
            expect(
              find.textContaining('Session root is unreachable.'),
              findsOneWidget,
            );
          }
        } finally {
          semantics.dispose();
        }
      },
      timeout: const Timeout(Duration(seconds: 20)),
    );
  }
}
