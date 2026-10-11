import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:codex_sessions_viewer/src/app/codex_sessions_viewer_app.dart';
import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/config/settings_diagnostics.dart';
import 'package:codex_sessions_viewer/src/database/database_connection.dart';
import 'package:codex_sessions_viewer/src/database/application_maintenance.dart';
import 'package:codex_sessions_viewer/src/database/database_maintenance.dart';
import 'package:codex_sessions_viewer/src/database/database_migrator.dart';
import 'package:codex_sessions_viewer/src/ui/screens/sessions_screen.dart';
import 'package:codex_sessions_viewer/src/ui/screens/settings_screen.dart';
import 'package:codex_sessions_viewer/src/ui/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  testWidgets('startup synchronizes pricing policy before normal usage reads', (
    tester,
  ) async {
    late Directory temp;
    late File databaseFile;
    late File settingsFile;
    late DatabaseMaintenanceCoordinator coordinator;
    late _NotifyingMaintenance maintenance;
    final release = Completer<void>();
    final settings = AppSettings.fromTomlMap({
      'pricing': {'use_external_pricing': false},
      'maintenance': {'database_optimize_enabled': false},
    });
    await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('csv_schedule_startup_');
      databaseFile = File('${temp.path}/viewer.sqlite');
      settingsFile = File('${temp.path}/settings.toml');
      await SettingsRepository(settingsFile).save(settings);
      final startup = await DatabaseMigrator(
        sqlRoot: Directory('../sql'),
      ).openAndMigrate(databaseFile);
      expect(startup.canStartNormalUi, isTrue);
      coordinator = DatabaseMaintenanceCoordinator(databaseFile);
      maintenance = _NotifyingMaintenance(
        databaseFile: databaseFile,
        coordinator: coordinator,
      );
      final entered = Completer<void>();
      unawaited(
        coordinator.runWriter(() async {
          entered.complete();
          await release.future;
        }),
      );
      await entered.future.timeout(const Duration(seconds: 3));
    });
    var usageLoads = 0;
    var cachedLoads = 0;
    try {
      await tester.pumpWidget(
        CodexSessionsViewerApp(
          databaseFile: databaseFile,
          settingsFile: settingsFile,
          writerCoordinator: coordinator,
          applicationMaintenance: maintenance,
          settingsStartup: Future.value(settings),
          databaseStartup: Future.value(
            DatabaseStartupResult.ready(lastAppliedSchemaVersion: 16),
          ),
          deferInitialSessionLoad: (_) {
            cachedLoads++;
          },
          usageSummaryLoader: (_, _) async {
            usageLoads++;
            return null;
          },
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(
        usageLoads,
        0,
        reason: 'cost policy must commit before usage is read',
      );
      expect(cachedLoads, 0);
      release.complete();
      await _pumpUntil(
        tester,
        condition: () => cachedLoads > 0,
        description: 'configured application startup',
      );
      expect(cachedLoads, greaterThan(0));
      final db = openFileBackedDatabase(databaseFile);
      try {
        expect(
          db
              .select('select pricing_policy_json from database_state')
              .single['pricing_policy_json'],
          '[1,false,true]',
        );
      } finally {
        db.close();
      }
      await tester.pump();
      expect(
        usageLoads,
        0,
        reason: 'hidden Usage does not query after startup',
      );
      final saved = AppSettings.fromTomlMap({
        'pricing': {
          'use_external_pricing': false,
          'overrides': {
            'local/saved': {'prompt': '0.05', 'completion': '0.1'},
          },
        },
        'maintenance': {'database_optimize_enabled': false},
      });
      final screen =
          tester
                  .widget<CodexAppShell>(find.byType(CodexAppShell))
                  .settingsScreen
              as SettingsScreen;
      expect(
        screen.maintenanceSchedules,
        hasLength(2),
        reason: 'the app exposes persisted job status to Settings',
      );
      final diagnostic = await screen.diagnostics.run(
        SettingsDiagnosticAction.testOpenRouterPricingFetch,
        settings,
      );
      expect(
        diagnostic.message,
        'OpenRouter price refresh failed.',
        reason:
            'manual refresh routes through the configured saved-settings service',
      );
      final originalRefreshToken = tester
          .widget<SessionsScreen>(find.byType(SessionsScreen))
          .autoRefreshToken;
      maintenance.publishCostWork(running: true);
      await tester.pump();
      expect(
        tester
            .widget<SessionsScreen>(find.byType(SessionsScreen))
            .pricingUpdating,
        isTrue,
      );
      maintenance.publishCostWork(running: false, committed: true);
      await tester.pump();
      expect(usageLoads, 0, reason: 'hidden Usage defers pricing invalidation');
      final updatedSessions = tester.widget<SessionsScreen>(
        find.byType(SessionsScreen),
      );
      expect(updatedSessions.pricingUpdating, isFalse);
      expect(updatedSessions.pricingRevision, 1);
      expect(
        updatedSessions.autoRefreshToken,
        originalRefreshToken,
        reason: 'repricing must not request a source scan',
      );
      var savedCompleted = false;
      unawaited(screen.onSave!(saved).then((_) => savedCompleted = true));
      await _pumpUntil(
        tester,
        condition: () => savedCompleted,
        description: 'saved pricing synchronization',
      );
      await tester.pump();
      final savedDb = openFileBackedDatabase(databaseFile);
      try {
        expect(
          savedDb.select(
            "select prompt_price_per_token from local_price_override_periods where model_id='local/saved' and valid_to_utc is null",
          ),
          hasLength(1),
          reason:
              'Save synchronizes history before publishing the new settings',
        );
      } finally {
        savedDb.close();
      }
      await tester.tap(
        find.bySemanticsLabel(RegExp('^Usage navigation\\nTab ')),
      );
      await _pumpUntil(
        tester,
        condition: () => usageLoads == 1,
        description: 'visible Usage catches up with committed pricing',
      );
    } finally {
      if (!release.isCompleted) release.complete();
      await tester.pumpWidget(const SizedBox.shrink());
      var stopped = false;
      var idle = false;
      unawaited(maintenance.stop().then((_) => stopped = true));
      unawaited(coordinator.idle.then((_) => idle = true));
      await _pumpUntil(
        tester,
        condition: () => stopped && idle,
        description: 'maintenance and background writer shutdown',
      );
      await tester.runAsync(() async {
        maintenance.dispose();
        await temp.delete(recursive: true);
      });
    }
  });

  testWidgets('direct session edits wait for the shared database writer', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1800, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late Directory temp;
    late File databaseFile;
    late File settingsFile;
    late DatabaseMaintenanceCoordinator coordinator;
    late Completer<void> releaseWriter;
    late Future<void> occupyingWriter;
    var writerStarted = false;
    addTearDown(() async {
      if (writerStarted) {
        if (!releaseWriter.isCompleted) {
          releaseWriter.complete();
        }
        await occupyingWriter.timeout(const Duration(seconds: 5));
        await coordinator.idle.timeout(const Duration(seconds: 5));
      }
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });
    await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp(
        'csv_app_writer_coordinator_',
      );
      databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
      settingsFile = File(p.join(temp.path, 'settings.toml'));
      await SettingsRepository(settingsFile).save(AppSettings.defaults());
      final startup = await DatabaseMigrator(
        sqlRoot: Directory(p.normalize(p.join('..', 'sql'))),
      ).openAndMigrate(databaseFile);
      expect(startup.canStartNormalUi, isTrue);
      final seed = openFileBackedDatabase(databaseFile);
      try {
        seed.execute(
          '''
          insert into sessions (
            id, source_type, source_file_path, display_path, platform_path,
            created_at_utc, updated_at_utc
          ) values (?, 'windows', ?, ?, ?, ?, ?)
          ''',
          [
            'barrier-session',
            r'C:\sessions\barrier.jsonl',
            r'C:\project',
            r'C:\project',
            '2026-09-07T10:00:00Z',
            '2026-09-07T10:00:00Z',
          ],
        );
      } finally {
        seed.close();
      }

      coordinator = DatabaseMaintenanceCoordinator(databaseFile);
    });

    await tester.pumpWidget(
      CodexSessionsViewerApp(
        databaseFile: databaseFile,
        settingsFile: settingsFile,
        databaseStartup: Future.value(
          DatabaseStartupResult.ready(lastAppliedSchemaVersion: 16),
        ),
        settingsStartup: Future.value(AppSettings.defaults()),
        writerCoordinator: coordinator,
        sessionRefresh: () async =>
            SessionsRefreshResult.scanFinished([_row()]),
        now: () => DateTime.utc(2026, 9, 8),
        deferInitialSessionLoad: (_) {},
        usageSummaryLoader: (_, _) async => null,
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Refresh'));
    await tester.pumpAndSettle();
    final moreActions = find.bySemanticsLabel(
      'More actions for Writer barrier session',
    );
    expect(moreActions, findsOneWidget);

    final writerEntered = Completer<void>();
    await tester.runAsync(() async {
      releaseWriter = Completer<void>();
      occupyingWriter = coordinator.runWriter(() async {
        writerEntered.complete();
        await releaseWriter.future;
      }, priority: DatabaseWriterPriority.migration);
      writerStarted = true;
    });
    await _pumpUntil(
      tester,
      condition: () => writerEntered.isCompleted,
      description: 'the migration-priority writer to enter the coordinator',
    );

    await tester.tap(moreActions);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.text('Pin session'));
    await tester.pump();

    expect(_pinnedValue(databaseFile), 0);

    releaseWriter.complete();
    await _pumpUntil(
      tester,
      condition: () => _pinnedValue(databaseFile) == 1,
      description: 'the queued pin update to finish',
    );

    expect(_pinnedValue(databaseFile), 1);
  });

  testWidgets('graceful exit waits for the shared writer safe boundary', (
    tester,
  ) async {
    final databaseFile = File(
      p.join(Directory.systemTemp.path, 'csv_exit_writer_unused.sqlite'),
    );
    final coordinator = DatabaseMaintenanceCoordinator(databaseFile);
    final releaseWriter = Completer<void>();
    final writerEntered = Completer<void>();
    late Future<void> occupyingWriter;
    final maintenanceResult = Completer<DatabaseMaintenanceResult>();
    var maintenanceStopCalls = 0;
    var exitCompleted = false;
    Future<AppExitResponse>? exit;

    occupyingWriter = coordinator.runWriter(() async {
      writerEntered.complete();
      await releaseWriter.future;
    });

    try {
      await tester.pumpWidget(
        CodexSessionsViewerApp(
          databaseFile: databaseFile,
          databaseStartup: Future.value(
            DatabaseStartupResult.ready(lastAppliedSchemaVersion: 16),
          ),
          settingsStartup: Future.value(AppSettings.defaults()),
          writerCoordinator: coordinator,
          databaseMaintenanceStartup: () async => DatabaseMaintenanceOperation(
            result: maintenanceResult.future,
            progress: const Stream.empty(),
            requestStop: () async {
              maintenanceStopCalls++;
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(writerEntered.isCompleted, isTrue);

      exit = tester.binding.handleRequestAppExit().then((response) {
        exitCompleted = true;
        return response;
      });
      await tester.pump();
      expect(maintenanceStopCalls, 1);
      expect(exitCompleted, isFalse);

      maintenanceResult.complete(
        const DatabaseMaintenanceResult(
          state: DatabaseMaintenanceState.interrupted,
        ),
      );
      await tester.pump();
      expect(
        exitCompleted,
        isFalse,
        reason: 'the ordinary writer has not reached its safe boundary',
      );

      releaseWriter.complete();
      await _pumpUntil(
        tester,
        condition: () => exitCompleted,
        description: 'graceful application exit',
      );
      expect(await exit, AppExitResponse.exit);
    } finally {
      if (!maintenanceResult.isCompleted) {
        maintenanceResult.complete(
          const DatabaseMaintenanceResult(
            state: DatabaseMaintenanceState.interrupted,
          ),
        );
      }
      if (!releaseWriter.isCompleted) {
        releaseWriter.complete();
      }
      var writerIdle = false;
      unawaited(coordinator.idle.then((_) => writerIdle = true));
      await _pumpUntil(
        tester,
        condition: () => writerIdle,
        description: 'exit test writer cleanup',
      );
      await occupyingWriter;
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('graceful exit cancels and joins the active session refresh', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1800, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late Directory temp;
    late File databaseFile;
    late File settingsFile;
    late DatabaseMaintenanceCoordinator coordinator;
    final refreshResult = Completer<SessionsRefreshResult>();
    var refreshStarts = 0;
    var refreshCancelCalls = 0;
    var exitCompleted = false;
    Future<AppExitResponse>? exit;

    await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('csv_app_exit_refresh_');
      databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
      settingsFile = File(p.join(temp.path, 'settings.toml'));
      await SettingsRepository(settingsFile).save(AppSettings.defaults());
      final startup = await DatabaseMigrator(
        sqlRoot: Directory(p.normalize(p.join('..', 'sql'))),
      ).openAndMigrate(databaseFile);
      expect(startup.canStartNormalUi, isTrue);
      coordinator = DatabaseMaintenanceCoordinator(databaseFile);
    });

    try {
      await tester.pumpWidget(
        CodexSessionsViewerApp(
          databaseFile: databaseFile,
          settingsFile: settingsFile,
          databaseStartup: Future.value(
            DatabaseStartupResult.ready(lastAppliedSchemaVersion: 16),
          ),
          settingsStartup: Future.value(AppSettings.defaults()),
          writerCoordinator: coordinator,
          sessionRefreshOperation: (_) {
            refreshStarts++;
            return SessionsRefreshOperation(
              result: refreshResult.future,
              cancel: () async {
                refreshCancelCalls++;
              },
            );
          },
          deferInitialSessionLoad: (_) {},
          usageSummaryLoader: (_, _) async => null,
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Refresh'));
      await tester.pump();
      expect(refreshStarts, 1);

      exit = tester.binding.handleRequestAppExit().then((response) {
        exitCompleted = true;
        return response;
      });
      await tester.pump();
      expect(refreshCancelCalls, 1);
      expect(
        exitCompleted,
        isFalse,
        reason: 'the cancelled refresh result has not released its resources',
      );

      refreshResult.complete(SessionsRefreshResult.scanFinished(const []));
      await _pumpUntil(
        tester,
        condition: () => exitCompleted,
        description: 'active session refresh shutdown',
      );
      expect(await exit, AppExitResponse.exit);
    } finally {
      if (!refreshResult.isCompleted) {
        refreshResult.complete(SessionsRefreshResult.scanFinished(const []));
      }
      var writerIdle = false;
      unawaited(coordinator.idle.then((_) => writerIdle = true));
      await _pumpUntil(
        tester,
        condition: () => writerIdle,
        description: 'active refresh test writer cleanup',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() => temp.delete(recursive: true));
    }
  });
}

class _NotifyingMaintenance extends ApplicationMaintenance {
  _NotifyingMaintenance({
    required super.databaseFile,
    required super.coordinator,
  });
  var revision = 0;
  @override
  int get dataRevision => revision;

  void publishCostWork({required bool running, bool committed = false}) {
    if (committed) revision++;
    progress = DatabaseMaintenanceProgress(
      state: running
          ? DatabaseMaintenanceState.running
          : DatabaseMaintenanceState.succeeded,
      phase: 'reprice_costs',
      currentWork: 'Updating historical costs',
      unitLabel: 'partitions',
      completedUnits: running ? 0 : 1,
      totalUnits: 1,
      ratePerSecond: null,
      elapsed: Duration.zero,
      estimatedRemaining: null,
      walBytes: 0,
    );
    notifyListeners();
  }
}

Future<void> _pumpUntil(
  WidgetTester tester, {
  required bool Function() condition,
  required String description,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for $description.');
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
}

int _pinnedValue(File databaseFile) {
  final db = openFileBackedDatabase(databaseFile);
  try {
    return db
            .select(
              "select is_pinned from sessions where id = 'barrier-session'",
            )
            .single['is_pinned']
        as int;
  } finally {
    db.close();
  }
}

SessionRowViewModel _row() => SessionRowViewModel(
  id: 'barrier-session',
  sessionId: 'barrier-session',
  startedAtUtc: DateTime.utc(2026, 9, 7, 10),
  lastMessageAtUtc: DateTime.utc(2026, 9, 7, 11),
  platform: SessionRowPlatform.windows,
  project: 'Writer barrier project',
  path: r'C:\project',
  workingDirectory: r'C:\project',
  title: 'Writer barrier session',
  summary: 'Coordinator barrier fixture',
  messageCount: 1,
  totalTokens: 42,
  model: 'gpt-5.5',
  tags: const [],
  status: 'available',
);
