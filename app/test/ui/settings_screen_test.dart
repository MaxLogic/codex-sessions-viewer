import 'dart:ui' show Tristate;
import 'dart:io';
import 'package:codex_sessions_viewer/src/database/application_maintenance.dart';
import 'package:codex_sessions_viewer/src/database/database_connection.dart'
    hide Row;
import 'package:codex_sessions_viewer/src/database/database_migrator.dart';
import 'package:codex_sessions_viewer/src/database/disk_space_probe.dart';
import 'package:codex_sessions_viewer/src/accessibility/announcement_service.dart';
import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/database/maintenance_job.dart';
import 'package:codex_sessions_viewer/src/database/database_maintenance.dart';
import 'package:codex_sessions_viewer/src/ui/screens/settings_screen.dart';
import 'package:codex_sessions_viewer/src/platform/app_locations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final class _AmpleMaintenanceDisk implements DiskSpaceProbe {
  const _AmpleMaintenanceDisk();
  @override
  DiskVolumeSpace probe(Directory directory) =>
      const DiskVolumeSpace(volumeKey: 'test', availableBytes: 1 << 50);
}

void main() {
  for (final reclaim in [false, true]) {
    testWidgets(
      'unavailable maintenance pause shows one accurate message (reclaim=$reclaim)',
      (tester) async {
        late Directory root;
        late ApplicationMaintenance maintenance;
        final expected = reclaim
            ? 'Unused database space was not reclaimed because session collection could not pause. It will be retried the next time the viewer starts.'
            : 'Database optimization was postponed because session collection could not pause. It will be retried automatically.';
        await tester.runAsync(() async {
          root = await Directory.systemTemp.createTemp(
            'cxv184-maintenance-settings-',
          );
          final file = File('${root.path}/viewer.sqlite');
          await DatabaseMigrator(
            sqlRoot: Directory('../sql'),
          ).openAndMigrate(file);
          maintenance = ApplicationMaintenance(
            databaseFile: file,
            coordinator: DatabaseMaintenanceCoordinator(
              file,
              pauseCollector: () async => throw StateError('raw pause failure'),
            ),
            diskSpace: const _AmpleMaintenanceDisk(),
            reclaimMinimumDatabaseBytes: reclaim ? 0 : 1 << 40,
          );
          await maintenance.configure(
            AppSettings.fromTomlMap({
              'pricing': {'use_external_pricing': false},
            }),
          );
          final db = openFileBackedDatabase(file);
          try {
            if (reclaim) {
              db.execute(
                "update maintenance_schedules set next_due_at_utc='2099-01-01T00:00:00Z' where job_type='database_optimize'",
              );
              db.execute(
                'create table filler(body blob); insert into filler values(zeroblob(4000000)); drop table filler;',
              );
            } else {
              db.execute(
                "update maintenance_schedules set next_due_at_utc=null where job_type='database_optimize'",
              );
            }
          } finally {
            db.close();
          }
          await maintenance.runDueJobs();
        });
        final semantics = tester.ensureSemantics();
        try {
          await tester.pumpWidget(
            MaterialApp(
              home: SettingsScreen(maintenanceProgress: maintenance.progress),
            ),
          );
          expect(find.text(expected), findsOneWidget);
          expect(maintenance.progress!.currentWork, isNot(expected));
          expect(maintenance.progress!.errorMessage, expected);
          expect(find.textContaining('Try again in a moment'), findsNothing);
          // ignore: avoid_print
          print(
            'maintenance_settings_text="$expected" visible_text_nodes=1 semantics=${tester.getSemantics(find.text(expected)).label}',
          );
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          semantics.dispose();
          await tester.runAsync(() async {
            await maintenance.stop();
            maintenance.dispose();
            await root.delete(recursive: true);
          });
        }
      },
    );
  }
  testWidgets(
    'scanner helpers distinguish running checks from the scheduled periodic scan',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await tester.binding.setSurfaceSize(const Size(1800, 1600));
        await tester.pumpWidget(
          MaterialApp(
            home: SettingsScreen(
              initialSettings: AppSettings.defaults(),
              onSave: (_) async {},
              onReload: () async => AppSettings.defaults(),
            ),
          ),
        );
        final interval = find.text(
          'How often session collection checks for new sessions while the viewer or Background collection runs. Background collection’s periodic scan (minutes) separately schedules additional checks.',
        );
        await tester.ensureVisible(interval);
        await tester.pumpAndSettle();
        expect(interval, findsOneWidget);
        final intervalControl = tester.getSemantics(
          find.bySemanticsLabel('Scan interval (seconds) input'),
        );
        expect(
          intervalControl.hint,
          contains('separately schedules additional checks'),
        );
        expect(
          find.bySemanticsLabel((tester.widget<Text>(interval).data)!),
          findsNothing,
        );
        final enabled = find.text(
          'Check for new sessions periodically while the viewer or Background collection runs. Turning this off leaves Background collection’s separately scheduled periodic scan (minutes) and hooks unchanged.',
        );
        expect(enabled, findsOneWidget);
        final enabledControl = tester.getSemantics(
          find.bySemanticsLabel('Background scan enabled setting'),
        );
        expect(enabledControl.hint, contains('hooks unchanged'));
        expect(
          find.bySemanticsLabel((tester.widget<Text>(enabled).data)!),
          findsNothing,
        );
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        // ignore: avoid_print
        print(
          'scanner_helpers_control_hints="${intervalControl.hint}"; "${enabledControl.hint}" separate_helper_nodes=0',
        );
      } finally {
        semantics.dispose();
        await tester.binding.setSurfaceSize(null);
      }
    },
  );

  testWidgets('persists parent-session filter', (tester) async {
    final semantics = tester.ensureSemantics();

    await tester.binding.setSurfaceSize(const Size(1800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('parent-filter-'),
    ))!;
    addTearDown(() => directory.delete(recursive: true));
    final repo = SettingsRepository(File('${directory.path}/settings.toml'));
    final original = AppSettings.defaults();
    Future<void>? save;
    Future<AppSettings>? reload;
    await tester.runAsync(() => repo.save(original));
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          initialSettings: original,
          onSave: (value) => save = repo.save(value),
          onReload: () => reload = repo.loadOrCreate(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final toggle = find.bySemanticsLabel(
      'Hide sessions started by other sessions setting',
    );
    await tester.ensureVisible(toggle);
    // Native Switch receives keyboard activation and exposes checked state.
    final switchFinder = find.descendant(
      of: toggle,
      matching: find.byType(Switch),
    );
    expect(switchFinder, findsOneWidget);
    final focus = FocusManager.instance.rootScope.descendants.firstWhere(
      (node) => node.context?.findAncestorWidgetOfExactType<Switch>() != null,
    );
    focus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('Save settings'));
      await save;
    });
    await tester.pumpAndSettle();
    expect(
      (await tester.runAsync(
        repo.loadOrCreate,
      ))!.ui.sessionTable.hideChildSessions,
      isTrue,
    );
    await tester.runAsync(() async {
      await tester.tap(find.text('Reload from file'));
      await reload;
    });
    await tester.pumpAndSettle();
    expect(
      tester.getSemantics(toggle).flagsCollection.isToggled == Tristate.isTrue,
      isTrue,
    );
    expect(
      (await tester.runAsync(repo.loadOrCreate))!.ui.sessionTable.columnWidths,
      original.ui.sessionTable.columnWidths,
    );
    semantics.dispose();
  });

  testWidgets(
    'native settings omit WSL controls and preserve copied WSL configuration',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final original = AppSettings.defaults();
      AppSettings? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            hostPlatform: AppHostPlatform.linux,
            initialSettings: original,
            onSave: (value) async {
              saved = value;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Native Codex path'), findsOneWidget);
      expect(find.text('WSL Codex UNC path'), findsNothing);
      expect(find.text('WSL distro name'), findsNothing);
      expect(find.text('WSL Linux home path'), findsNothing);
      await tester.ensureVisible(find.text('Save settings'));
      await tester.tap(find.text('Save settings'));
      await tester.pumpAndSettle();
      expect(saved?.paths, original.paths);
      expect(saved?.wsl, original.wsl);
    },
  );
  testWidgets('maintenance progress is bounded, accessible and non-modal', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    var saves = 0;
    DatabaseMaintenanceProgress progress({
      int completed = 25,
      int? total = 100,
      DatabaseMaintenanceState state = DatabaseMaintenanceState.running,
    }) => DatabaseMaintenanceProgress(
      state: state,
      phase: 'Repricing usage',
      currentWork: 'Repricing stored daily partitions',
      unitLabel: 'partitions',
      completedUnits: completed,
      totalUnits: total,
      ratePerSecond: null,
      elapsed: const Duration(seconds: 5),
      estimatedRemaining: null,
      walBytes: 0,
      errorMessage: state == DatabaseMaintenanceState.failed
          ? 'Pricing maintenance failed.'
          : null,
    );
    Future<void> show(
      DatabaseMaintenanceProgress? progress, {
      bool reduced = false,
    }) => tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: SettingsScreen(
            maintenanceProgress: progress,
            onSave: (_) async => saves++,
          ),
        ),
      ),
    );
    await show(progress());
    expect(find.text('Repricing usage'), findsOneWidget);
    expect(find.text('Repricing stored daily partitions'), findsOneWidget);
    expect(find.text('25 of 100 partitions'), findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, 0.25);
    expect(bar.semanticsValue, '25%');
    final announcement = find.byKey(
      const Key('settings-maintenance-announcement'),
    );
    expect(
      tester.getSemantics(announcement).label,
      'Database maintenance running. Repricing usage, 20 percent.',
    );
    await show(progress(completed: 26));
    expect(
      tester.getSemantics(announcement).label,
      'Database maintenance running. Repricing usage, 20 percent.',
    );
    await tester.tap(find.text('Save settings'));
    await tester.pump();
    expect(saves, 1);
    expect(find.byType(AlertDialog), findsNothing);
    await show(progress(total: null));
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      isNull,
    );
    await show(progress(total: null), reduced: true);
    await tester.pump(const Duration(seconds: 1));
    expect(tester.binding.transientCallbackCount, 0);
    expect(find.text('25 partitions'), findsOneWidget);
    for (final state in [
      DatabaseMaintenanceState.interrupted,
      DatabaseMaintenanceState.failed,
    ]) {
      await show(progress(state: state));
      expect(find.text('Database maintenance ${state.name}'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
    }
    expect(find.text('Pricing maintenance failed.'), findsOneWidget);
    await show(progress(state: DatabaseMaintenanceState.succeeded));
    expect(find.text('Repricing usage'), findsNothing);
    await show(null);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('shows read-only maintenance history and updates it on rebuild', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    var saves = 0;
    Future<void> show(List<MaintenanceScheduleRecord> schedules) =>
        tester.pumpWidget(
          MaterialApp(
            home: SettingsScreen(
              maintenanceSchedules: schedules,
              clock: () => DateTime.utc(2026, 9, 7, 14),
              onSave: (_) async => saves++,
            ),
          ),
        );
    final attempt = DateTime.utc(2026, 9, 7, 12);
    final success = DateTime.utc(2026, 9, 6, 11);
    final due = DateTime.utc(2026, 9, 7, 13);
    await show([
      MaintenanceScheduleRecord(
        jobType: 'openrouter_price_refresh',
        enabled: true,
        intervalSeconds: 86400,
        lastAttemptAtUtc: attempt,
        lastSuccessAtUtc: success,
        nextDueAtUtc: due,
        retryCount: 1,
        lastError: 'OpenRouter price refresh failed.',
      ),
      MaintenanceScheduleRecord(
        jobType: 'database_optimize',
        enabled: false,
        intervalSeconds: 604800,
        nextDueAtUtc: due,
      ),
    ]);
    expect(find.text('OpenRouter price refresh status'), findsOneWidget);
    expect(find.text('Database optimization status'), findsOneWidget);
    await tester.ensureVisible(find.text('OpenRouter price refresh status'));
    expect(find.text('Last attempt: 2026-09-07 12:00:00 UTC'), findsOneWidget);
    expect(find.text('Last success: 2026-09-06 11:00:00 UTC'), findsOneWidget);
    expect(find.text('Next due: 2026-09-07 13:00:00 UTC'), findsOneWidget);
    expect(
      find.text('Observation state: Stale; prices may have changed'),
      findsOneWidget,
    );
    expect(
      find.text('Last error: OpenRouter price refresh failed.'),
      findsOneWidget,
    );
    await tester.ensureVisible(find.text('Database optimization status'));
    expect(find.text('Automatic job: Disabled'), findsOneWidget);
    expect(
      find.text('Next due: Disabled (stored: 2026-09-07 13:00:00 UTC)'),
      findsOneWidget,
    );
    expect(find.text('Last attempt: Never'), findsOneWidget);
    expect(find.text('Last success: Never'), findsOneWidget);
    expect(find.text('Last error: None'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Database optimization status'),
      findsOneWidget,
    );
    await show([
      MaintenanceScheduleRecord(
        jobType: 'openrouter_price_refresh',
        enabled: true,
        intervalSeconds: 86400,
        lastAttemptAtUtc: due,
        lastSuccessAtUtc: due,
        nextDueAtUtc: DateTime.utc(2026, 9, 8, 13),
      ),
    ]);
    expect(find.text('Last success: 2026-09-07 13:00:00 UTC'), findsOneWidget);
    expect(
      find.text('Last error: OpenRouter price refresh failed.'),
      findsNothing,
    );
    expect(find.text('Next due: 2026-09-08 13:00:00 UTC'), findsOneWidget);
    expect(
      find.text(
        'Observation state: Last observation within cadence; not a live price',
      ),
      findsOneWidget,
    );
    expect(saves, 0);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets(
    'a legacy hub token is kept on save and reported without its value',
    (tester) async {
      const secret = 'synthetic-legacy-hub-secret';
      final initial = AppSettings.fromTomlMap({
        'pricing': {'hub_token': secret, 'hub_machine_id': 'laptop-1'},
      });
      AppSettings? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            initialSettings: initial,
            onSave: (settings) async => saved = settings,
          ),
        ),
      );
      final warning = find.textContaining('legacy pricing.hub_token');
      expect(warning, findsOneWidget);
      expect(
        find.textContaining('CODEX_SESSIONS_HUB_MACHINE_TOKEN'),
        findsWidgets,
      );
      expect(find.textContaining(secret), findsNothing);
      final interval = find.bySemanticsLabel(
        'Price refresh interval (hours) input',
      );
      await tester.ensureVisible(interval);
      await tester.enterText(interval, '12');
      await tester.pump();
      await tester.tap(find.text('Save settings'));
      await tester.pump();
      final pricing = saved!.toTomlMap()['pricing'] as Map;
      expect(pricing['refresh_interval_hours'], 12);
      expect(pricing['hub_token'], secret);
      expect(pricing['hub_machine_id'], 'laptop-1');
    },
  );

  testWidgets('no legacy hub warning without a legacy token', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(initialSettings: AppSettings.defaults()),
      ),
    );
    expect(find.textContaining('legacy pricing.hub_token'), findsNothing);
  });

  testWidgets('changing the price interval away from 6 turns UTC slots off', (
    tester,
  ) async {
    AppSettings? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          initialSettings: AppSettings.defaults(),
          onSave: (settings) async => saved = settings,
        ),
      ),
    );
    Switch utcSwitch() => tester.widget<Switch>(
      find.descendant(
        of: find.ancestor(
          of: find.text('Use fixed UTC pricing slots'),
          matching: find.byType(Row),
        ),
        matching: find.byType(Switch),
      ),
    );
    expect(utcSwitch().value, isTrue);
    final interval = find.bySemanticsLabel(
      'Price refresh interval (hours) input',
    );
    await tester.ensureVisible(interval);
    await tester.enterText(interval, '12');
    await tester.pump();
    expect(utcSwitch().value, isFalse);
    expect(
      find.text('Cadence: interval after the last successful observation.'),
      findsOneWidget,
    );
    await tester.enterText(interval, '6');
    await tester.pump();
    // Returning to 6 hours does not silently re-enable slots.
    expect(utcSwitch().value, isFalse);
    await tester.tap(find.text('Save settings'));
    await tester.pump();
    expect(saved!.pricing.refreshIntervalHours, 6);
    expect(saved!.pricing.refreshUtcSlots, isFalse);
  });

  testWidgets(
    'edits maintenance schedules without losing them on unrelated changes',
    (tester) async {
      AppSettings? saved;
      final initial = AppSettings.defaults();
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            initialSettings: initial,
            onSave: (settings) async => saved = settings,
            onReload: () async => initial,
          ),
        ),
      );
      Future<void> toggle(String label) async {
        final control = find.bySemanticsLabel('$label setting');
        await tester.ensureVisible(control);
        await tester.tap(control);
        await tester.pump();
      }

      Future<void> enter(String label, String value) async {
        final control = find.bySemanticsLabel('$label input');
        await tester.ensureVisible(control);
        await tester.enterText(control, value);
      }

      expect(find.text('Automatic OpenRouter price refresh'), findsOneWidget);
      expect(find.text('Automatic database optimization'), findsOneWidget);
      await toggle('Automatic OpenRouter price refresh');
      await enter('Price refresh interval (hours)', '720');
      await toggle('OpenRouter pricing enabled');
      await toggle('Automatic database optimization');
      await enter('Database optimization interval (days)', '365');
      await tester.tap(find.text('Save settings'));
      await tester.pump();
      expect(saved!.pricing.automaticRefreshEnabled, isFalse);
      expect(saved!.pricing.useExternalPricing, isFalse);
      expect(saved!.pricing.refreshIntervalHours, 720);
      expect(saved!.pricing.refreshUtcSlots, isFalse);
      expect(saved!.maintenance.databaseOptimizeEnabled, isFalse);
      expect(saved!.maintenance.databaseOptimizeIntervalDays, 365);
      expect(saved!.pricing.openRouter, initial.pricing.openRouter);
      await enter('Database optimization interval (days)', '1');
      await tester.tap(find.text('Cancel changes'));
      await tester.pump();
      await tester.tap(find.text('Save settings'));
      await tester.pump();
      expect(saved!.maintenance.databaseOptimizeIntervalDays, 365);
      await tester.tap(find.text('Reload from file'));
      await tester.pump();
      await tester.tap(find.text('Save settings'));
      await tester.pump();
      expect(saved!.pricing.automaticRefreshEnabled, isTrue);
      expect(saved!.pricing.refreshIntervalHours, 6);
      expect(saved!.pricing.refreshUtcSlots, isTrue);
      await toggle('Use fixed UTC pricing slots');
      await tester.tap(find.text('Save settings'));
      await tester.pump();
      expect(saved!.pricing.refreshUtcSlots, isFalse);
      expect(saved!.pricing.refreshIntervalHours, 6);
      await toggle('Use fixed UTC pricing slots');
      await tester.tap(find.text('Save settings'));
      await tester.pump();
      expect(saved!.pricing.refreshUtcSlots, isTrue);
      expect(find.textContaining('Cadence: 00:00, 06:00'), findsOneWidget);
      expect(saved!.maintenance, const MaintenanceSettings());
    },
  );

  testWidgets('invalid maintenance intervals block saving and announce errors', (
    tester,
  ) async {
    final announcer = RecordingScreenReaderAnnouncer();
    var saves = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          announcer: announcer,
          onSave: (_) async => saves++,
        ),
      ),
    );
    for (final (label, values, error) in [
      (
        'Price refresh interval (hours)',
        ['0', '721', 'bad'],
        'Price refresh interval (hours) must be an integer from 1 to 720.',
      ),
      (
        'Database optimization interval (days)',
        ['0', '366', '1.5'],
        'Database optimization interval (days) must be an integer from 1 to 365.',
      ),
    ]) {
      final control = find.bySemanticsLabel('$label input');
      for (final value in values) {
        await tester.ensureVisible(control);
        await tester.enterText(control, value);
        await tester.tap(find.text('Save settings'));
        await tester.pump();
        expect(saves, 0);
        expect(find.text(error), findsOneWidget);
        expect(announcer.messages.last, error);
        expect(tester.takeException(), isNull);
      }
      await tester.ensureVisible(control);
      await tester.enterText(control, '1');
    }
    await tester.tap(find.text('Save settings'));
    await tester.pump();
    expect(saves, 1);
    expect(find.text('Settings saved.'), findsOneWidget);
  });

  testWidgets('shows required settings groups and saves explicit changes', (
    tester,
  ) async {
    final announcer = RecordingScreenReaderAnnouncer();
    AppSettings? saved;

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          initialSettings: AppSettings.defaults(),
          announcer: announcer,
          onSave: (settings) async {
            saved = settings;
          },
        ),
      ),
    );

    for (final section in const [
      'Application',
      'Paths',
      'WSL',
      'Terminal',
      'Scanner',
      'Appearance',
      'Voice-over',
      'Pricing',
      'Data and cache',
      'Diagnostics',
    ]) {
      expect(find.text(section), findsOneWidget);
    }

    for (final label in const [
      'Start at login',
      'Windows Codex path',
      'WSL Codex UNC path',
      'WSL distro name',
      'WSL Linux home path',
      'WSL UNC root',
      'Default terminal',
      'Alacritty executable path',
      'Windows Terminal executable path',
      'Scan interval (seconds)',
      'Background scan enabled',
      'Theme',
      'Font size (pixels)',
      'UI density',
      'Show icons',
      'Show text on buttons',
      'Voice-over enabled',
      'Voice-over file paths',
      'OpenRouter pricing enabled',
      'Price refresh interval (hours)',
      'Pricing overrides',
      'Cache/database location',
      'Export folder',
    ]) {
      expect(find.text(label), findsOneWidget);
    }

    for (final helper in const [
      'Launch Codex Session Viewer after signing in.',
      'Folder containing native Codex session files.',
      'UNC folder used to read WSL Codex sessions from Windows.',
      'Command profile used when launching resume commands.',
      'One voice-over event WAV path per line.',
      'Public model-pricing metadata only; no session content is sent.',
    ]) {
      expect(find.text(helper), findsOneWidget);
    }

    await tester.enterText(
      find.bySemanticsLabel('Windows Codex path input'),
      r'D:\Codex',
    );
    await tester.tap(find.text('Save settings'));
    await tester.pump();

    expect(saved?.paths.windowsCodexPath, r'D:\Codex');
    expect(find.text('Settings saved.'), findsOneWidget);
    expect(announcer.messages, contains('Settings saved.'));
  });

  testWidgets('settings screen edits start at login preference', (
    tester,
  ) async {
    AppSettings? saved;

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          initialSettings: AppSettings.defaults(),
          onSave: (settings) async {
            saved = settings;
          },
        ),
      ),
    );

    expect(find.text('Start at login'), findsOneWidget);

    final startupRow = find.ancestor(
      of: find.text('Start at login'),
      matching: find.byType(Row),
    );
    final startupSwitch = find.descendant(
      of: startupRow,
      matching: find.byType(Switch),
    );

    expect(tester.widget<Switch>(startupSwitch).value, isTrue);

    await tester.tap(startupSwitch);
    await tester.pump();
    await tester.tap(find.text('Save settings'));
    await tester.pump();

    expect(saved?.app.startWithWindows, isFalse);
  });

  testWidgets('cancel and reload make explicit state changes', (tester) async {
    final reloaded = AppSettings.defaults().copyWith(
      paths: const PathSettings(
        windowsCodexPath: r'E:\Reloaded',
        wslCodexUncPath: r'\\wsl.localhost\Ubuntu\home\pawel\.codex',
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          initialSettings: AppSettings.defaults(),
          onReload: () async => reloaded,
        ),
      ),
    );

    await tester.enterText(
      find.bySemanticsLabel('Windows Codex path input'),
      r'D:\Unsaved',
    );
    await tester.tap(find.text('Cancel changes'));
    await tester.pump();

    expect(find.text('Changes canceled.'), findsOneWidget);
    expect(find.text(r'C:\Users\pawel\.codex'), findsOneWidget);

    await tester.tap(find.text('Reload from file'));
    await tester.pump();

    expect(find.text('Settings reloaded.'), findsOneWidget);
    expect(find.text(r'E:\Reloaded'), findsOneWidget);
  });

  testWidgets('settings screen edits motion preference', (tester) async {
    AppSettings? saved;

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          initialSettings: AppSettings.defaults(),
          onSave: (settings) async {
            saved = settings;
          },
        ),
      ),
    );

    expect(find.text('Motion'), findsOneWidget);
    expect(find.text('system'), findsWidgets);

    await tester.ensureVisible(find.text('Motion'));
    await tester.pumpAndSettle();

    final motionRow = find.ancestor(
      of: find.text('Motion'),
      matching: find.byType(Row),
    );
    final motionDropdown = find.descendant(
      of: motionRow,
      matching: find.byType(DropdownButton<String>),
    );

    await tester.tap(motionDropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('normal').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save settings'));
    await tester.pump();

    expect(saved?.ui.motion, AppMotionMode.normal);
  });

  testWidgets('motion choice exposes an accessible control name', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(initialSettings: AppSettings.defaults()),
      ),
    );

    await tester.ensureVisible(find.text('Motion'));
    await tester.pumpAndSettle();

    final choice = find.bySemanticsLabel(RegExp(r'^Motion setting\n'));
    expect(choice, findsOneWidget);
    expect(
      tester.getSemantics(choice),
      matchesSemantics(
        hasTapAction: true,
        hasFocusAction: true,
        isButton: true,
        isFocusable: true,
        hasExpandedState: true,
        label: 'Motion setting\nsystem',
      ),
    );

    semantics.dispose();
  });
}
