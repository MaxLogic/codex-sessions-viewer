import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:codex_sessions_viewer/src/app/codex_sessions_viewer_app.dart';
import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/database/database_migrator.dart';
import 'package:codex_sessions_viewer/src/database/database_connection.dart';
import 'package:codex_sessions_viewer/src/database/database_generation.dart';
import 'package:codex_sessions_viewer/src/database/collector_versions.dart';
import 'package:codex_sessions_viewer/src/ui/screens/sessions_screen.dart';
import 'package:codex_sessions_viewer/src/usage/usage_summary.dart';
import 'package:flutter/material.dart'
    show FilterChip, TextField, DateRangePickerDialog, SizedBox;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory isolated;
  setUp(() {
    isolated = Directory.systemTemp.createTempSync('usage_widget_');
    final db = sqlite3.open('${isolated.path}/unused.sqlite');
    configureFileBackedDatabase(db);
    db.execute('create table fixture (id integer)');
    db.close();
  });
  tearDown(() {
    isolated.deleteSync(recursive: true);
  });
  testWidgets(
    'opening Usage reads persisted data without observing pricing settings',
    (tester) async {
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
      await tester.binding.setSurfaceSize(const Size(1400, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final root = Directory.systemTemp.createTempSync('usage_read_only_');
      final file = File('${root.path}/fixture.sqlite');
      final db = sqlite3.open(file.path);
      addTearDown(() {
        db.close();
        root.deleteSync(recursive: true);
      });
      final scripts =
          [
            ...Directory('../sql/init').listSync().whereType<File>(),
            ...Directory('../sql/migration').listSync().whereType<File>(),
          ].where((item) => item.path.endsWith('.sql')).toList()..sort(
            (a, b) =>
                a.uri.pathSegments.last.compareTo(b.uri.pathSegments.last),
          );
      for (final script in scripts) {
        db.execute(script.readAsStringSync());
      }
      final generations = DatabaseGenerationRepository(db);
      final generation = generations.createBuilding(
        sourceSchemaVersion: 15,
        targetSchemaVersion: 16,
        sourceFingerprint: 'read-only-fixture',
      );
      generations.markReady(generation.id, validationReportJson: '{}');
      generations.activate(generation.id);
      final now = DateTime.now().toUtc().toIso8601String();
      db.execute(
        '''
      insert into sessions (id, session_id, source_type, source_file_path, display_path,
        platform_path, started_at_utc, created_at_utc, updated_at_utc)
      values ('fixture', 'fixture', 'windows', 'fixture', 'fixture', 'fixture', ?, ?, ?)
    ''',
        [now, now, now],
      );
      db.execute(
        "update sessions set parse_status = 'available', usage_projection_status = 'complete', parser_version = ?, usage_local_event_count = 1",
        [collectorCodexParserVersion],
      );
      db.execute(
        '''
      insert into usage_session_daily (session_id, day_utc, model_key, path_context_id,
        branch_scope, input_tokens, cached_input_tokens, cache_write_input_tokens,
        output_tokens, reasoning_output_tokens, total_tokens, cost_status,
        pricing_resolution_method, cost_projection_version, updated_at_utc)
      values ('fixture', ?, 'fixture/model', 1, 'local', 777, 0, 0, 0, 0, 777,
        'unknown', 'unknown', 1, ?)
    ''',
        [now.substring(0, 10), now],
      );
      final settings = _usageTestSettings().copyWith(
        pricing: const PricingSettings(
          provider: 'openrouter',
          useExternalPricing: false,
          cachePricingHours: 24,
          fallbackToOverrides: true,
          openRouter: OpenRouterSettings(
            modelsEndpoint: 'https://openrouter.ai/api/v1/models',
            apiKey: '',
          ),
          overrides: {
            'fixture/model': PricingOverrideSettings(
              prompt: '1',
              completion: '1',
              inputCacheRead: '1',
              inputCacheWrite: '1',
              internalReasoning: '1',
            ),
          },
        ),
      );
      await tester.runAsync(() async {
        await tester.pumpWidget(
          CodexSessionsViewerApp(
            databaseFile: file,
            databaseStartup: Future.value(
              DatabaseStartupResult.ready(lastAppliedSchemaVersion: 16),
            ),
            settingsStartup: Future.value(settings),
            deferInitialSessionLoad: (_) {},
          ),
        );
        await _pumpFrames(tester);
        await tester.tap(
          find.bySemanticsLabel(RegExp('^Usage navigation\\nTab ')),
        );
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (find.text('777').evaluate().isEmpty &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump();
        }
      });
      expect(find.text('777'), findsWidgets);
      expect(
        db
            .select('select pricing_settings_revision from database_state')
            .single['pricing_settings_revision'],
        0,
      );
      expect(db.select('select * from local_price_override_periods'), isEmpty);
    },
  );

  testWidgets('changing usage period reloads its summary', (tester) async {
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.binding.setSurfaceSize(const Size(1400, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var loadCalls = 0;
    await tester.pumpWidget(
      CodexSessionsViewerApp(
        databaseFile: File('${isolated.path}/unused.sqlite'),
        databaseStartup: Future.value(
          DatabaseStartupResult.ready(lastAppliedSchemaVersion: 16),
        ),
        settingsStartup: Future.value(_usageTestSettings()),
        deferInitialSessionLoad: (_) {},
        usageSummaryLoader: (_, request) async {
          loadCalls++;
          expect(
            request.period,
            [
              UsagePeriod.last30Days,
              UsagePeriod.today,
              UsagePeriod.custom,
            ][loadCalls - 1],
          );
          if (request.period == UsagePeriod.custom) {
            expect(request.resolve().startUtc, DateTime.utc(2026, 9, 1));
            expect(request.resolve().endExclusiveUtc, DateTime.utc(2026, 9, 5));
          }
          return _summary(
            title: 'Period $loadCalls',
            inputTokens: loadCalls,
            totalTokens: loadCalls == 1 ? 123 : 456,
          );
        },
      ),
    );
    await _pumpFrames(tester);
    await tester.tap(find.bySemanticsLabel(RegExp('^Usage navigation\\nTab ')));
    await _pumpFrames(tester);
    expect(find.text('123'), findsWidgets);
    await tester.tap(find.text('Today'));
    await _pumpFrames(tester);
    expect(loadCalls, 2);
    expect(find.text('456'), findsWidgets);
    expect(find.text('123'), findsNothing);
    await tester.tap(
      find.bySemanticsLabel(RegExp('^Sessions navigation\\nTab ')),
    );
    await _pumpFrames(tester);
    await tester.tap(find.bySemanticsLabel(RegExp('^Usage navigation\\nTab ')));
    await _pumpFrames(tester);
    expect(
      tester
          .widget<FilterChip>(find.widgetWithText(FilterChip, 'Today'))
          .selected,
      isTrue,
    );
    await tester.tap(find.text('Custom range'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Switch to input'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), '09/01/2026');
    await tester.enterText(find.byType(TextField).at(1), '09/04/2026');
    await tester.tap(find.text('OK'));
    await _pumpFrames(tester);
    expect(loadCalls, 3);
    await tester.tap(
      find.bySemanticsLabel(RegExp('^Sessions navigation\\nTab ')),
    );
    await _pumpFrames(tester);
    await tester.tap(find.bySemanticsLabel(RegExp('^Usage navigation\\nTab ')));
    await _pumpFrames(tester);
    expect(
      tester
          .widget<FilterChip>(find.widgetWithText(FilterChip, 'Custom range'))
          .selected,
      isTrue,
    );
    await tester.tap(find.text('Custom range'));
    await tester.pumpAndSettle();
    final range = tester
        .widget<DateRangePickerDialog>(find.byType(DateRangePickerDialog))
        .initialDateRange!;
    expect(
      (range.start.year, range.start.month, range.start.day),
      (2026, 9, 1),
    );
    expect((range.end.year, range.end.month, range.end.day), (2026, 9, 4));
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(loadCalls, 3);
  });

  testWidgets('failed usage refresh retains last successful snapshot', (
    tester,
  ) async {
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.binding.setSurfaceSize(const Size(1400, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var loadCalls = 0;
    await tester.pumpWidget(
      CodexSessionsViewerApp(
        databaseFile: File('${isolated.path}/unused.sqlite'),
        databaseStartup: Future.value(
          DatabaseStartupResult.ready(lastAppliedSchemaVersion: 15),
        ),
        settingsStartup: Future.value(_usageTestSettings()),
        deferInitialSessionLoad: (_) {},
        usageSummaryLoader: (_, _) {
          loadCalls++;
          return loadCalls == 1
              ? Future.value(
                  _summary(
                    title: 'Retained usage',
                    inputTokens: 11,
                    totalTokens: 12,
                  ),
                )
              : Future.error(StateError('private failure details'));
        },
        sessionRefresh: () async => const SessionsRefreshResult(
          rows: [],
          statusMessage: 'Scan finished.',
        ),
      ),
    );
    await _pumpFrames(tester);

    // Load the retained snapshot through the visible Usage route first.
    await tester.tap(find.bySemanticsLabel(RegExp('^Usage navigation\\nTab ')));
    await _pumpFrames(tester);
    await tester.tap(
      find.bySemanticsLabel(RegExp('^Sessions navigation\\nTab ')),
    );
    await _pumpFrames(tester);

    await tester.tap(find.text('Refresh'));
    await _pumpFrames(tester);
    await tester.tap(find.bySemanticsLabel(RegExp('^Usage navigation\\nTab ')));
    await _pumpFrames(tester);

    expect(
      find.text(
        'Usage status refresh failed; showing the last successful snapshot.',
      ),
      findsOneWidget,
    );
    expect(find.text('12'), findsWidgets);
    expect(find.textContaining('private failure details'), findsNothing);
  });

  testWidgets('usage status refreshes without blocking', (tester) async {
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.binding.setSurfaceSize(const Size(1400, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final refreshed = Completer<UsageSummary?>();
    var loadCalls = 0;
    await tester.pumpWidget(
      CodexSessionsViewerApp(
        databaseFile: File('${isolated.path}/unused.sqlite'),
        databaseStartup: Future.value(
          DatabaseStartupResult.ready(lastAppliedSchemaVersion: 15),
        ),
        settingsStartup: Future.value(_usageTestSettings()),
        deferInitialSessionLoad: (_) {},
        usageSummaryLoader: (_, _) {
          loadCalls++;
          return loadCalls == 1
              ? Future.value(
                  _summary(
                    title: 'Retained usage',
                    inputTokens: 11,
                    totalTokens: 12,
                  ),
                )
              : refreshed.future;
        },
        sessionRefresh: () async => const SessionsRefreshResult(
          rows: [],
          statusMessage: 'Scan finished.',
        ),
      ),
    );
    await _pumpFrames(tester);

    // Load the retained snapshot through the visible Usage route first.
    await tester.tap(find.bySemanticsLabel(RegExp('^Usage navigation\\nTab ')));
    await _pumpFrames(tester);
    await tester.tap(
      find.bySemanticsLabel(RegExp('^Sessions navigation\\nTab ')),
    );
    await _pumpFrames(tester);

    await tester.tap(find.text('Refresh'));
    await _pumpFrames(tester, count: 2);
    expect(find.text('Scan finished.'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel(RegExp('^Usage navigation\\nTab ')));
    await _pumpFrames(tester, count: 2);

    expect(find.text('Refreshing usage status…'), findsOneWidget);
    expect(find.text('12'), findsWidgets);

    refreshed.complete(
      _summary(title: 'Refreshed usage', inputTokens: 20, totalTokens: 25),
    );
    await _pumpFrames(tester);

    expect(find.text('Refreshing usage status…'), findsNothing);
    expect(find.text('25'), findsWidgets);
  });

  testWidgets('usage screen displays refreshed calculated statistics', (
    tester,
  ) async {
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.binding.setSurfaceSize(const Size(1400, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      CodexSessionsViewerApp(
        databaseFile: File('${isolated.path}/unused.sqlite'),
        databaseStartup: Future.value(
          DatabaseStartupResult.ready(lastAppliedSchemaVersion: 5),
        ),
        settingsStartup: Future.value(_usageTestSettings()),
        deferInitialSessionLoad: (_) {},
        usageSummaryLoader: (_, _) async =>
            _summary(title: 'Usage existing', inputTokens: 42, totalTokens: 70),
      ),
    );
    await _pumpFrames(tester);

    await tester.tap(find.bySemanticsLabel(RegExp('^Usage navigation\\nTab ')));
    await _pumpFrames(tester);

    expect(find.text('70'), findsWidgets);
    expect(find.text('42'), findsWidgets);
    await tester.tap(find.text('Top'));
    await _pumpFrames(tester);
    expect(find.text('Usage existing'), findsWidgets);
  });

  testWidgets('usage statistics update after refresh', (tester) async {
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.binding.setSurfaceSize(const Size(1400, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var loadCalls = 0;
    await tester.pumpWidget(
      CodexSessionsViewerApp(
        databaseFile: File('${isolated.path}/unused.sqlite'),
        databaseStartup: Future.value(
          DatabaseStartupResult.ready(lastAppliedSchemaVersion: 5),
        ),
        settingsStartup: Future.value(_usageTestSettings()),
        deferInitialSessionLoad: (_) {},
        usageSummaryLoader: (_, _) async {
          loadCalls++;
          return loadCalls == 1
              ? _summary(
                  title: 'Before refresh',
                  inputTokens: 1,
                  totalTokens: 2,
                )
              : _summary(title: 'Usage new', inputTokens: 10, totalTokens: 17);
        },
        sessionRefresh: () async => const SessionsRefreshResult(
          rows: [],
          statusMessage: 'Scan finished.',
        ),
      ),
    );
    await _pumpFrames(tester);

    // Load the retained snapshot through the visible Usage route first.
    await tester.tap(find.bySemanticsLabel(RegExp('^Usage navigation\\nTab ')));
    await _pumpFrames(tester);
    await tester.tap(
      find.bySemanticsLabel(RegExp('^Sessions navigation\\nTab ')),
    );
    await _pumpFrames(tester);

    await tester.tap(find.text('Refresh'));
    await _pumpFrames(tester);
    await tester.tap(find.bySemanticsLabel(RegExp('^Usage navigation\\nTab ')));
    await _pumpFrames(tester);

    expect(find.text('17'), findsWidgets);
    expect(find.text('10'), findsWidgets);
    await tester.tap(find.text('Top'));
    await _pumpFrames(tester);
    expect(find.text('Usage new'), findsWidgets);
  });
}

AppSettings _usageTestSettings() => AppSettings.defaults().copyWith(
  scanner: const ScannerSettings(
    backgroundRescanEnabled: false,
    backgroundRescanIntervalSeconds: 60,
  ),
);

UsageSummary _summary({
  required String title,
  required int inputTokens,
  required int totalTokens,
}) {
  return UsageSummary(
    period: UsageDateRange(
      startUtc: DateTime.utc(2026, 6, 1),
      endExclusiveUtc: DateTime.utc(2026, 7, 1),
    ),
    totalSessions: 1,
    totalMessages: 3,
    inputTokens: inputTokens,
    outputTokens: totalTokens - inputTokens,
    cachedInputTokens: 0,
    totalTokens: totalTokens,
    estimatedCostText: '0',
    costUnknown: false,
    mostUsedModel: 'gpt-5.4',
    mostActiveProject: 'Codex Viewer',
    mostActivePlatform: 'Windows',
    byDay: [
      UsageBreakdownRow(
        key: '2026-06-18',
        sessionCount: 1,
        messageCount: 3,
        inputTokens: inputTokens,
        outputTokens: totalTokens - inputTokens,
        cachedInputTokens: 0,
        totalTokens: totalTokens,
        estimatedCostText: '0',
        costUnknown: false,
      ),
    ],
    byWeek: const [],
    byMonth: const [],
    byModel: const [],
    byProject: const [],
    byPlatform: const [],
    byOrigin: const [],
    byArchiveState: const [],
    topSessionsByTokens: [
      UsageTopSession(
        sessionId: title,
        title: title,
        messageCount: 3,
        totalTokens: totalTokens,
        estimatedCostText: '0',
        costUnknown: false,
        originLabel: 'User',
      ),
    ],
    topSessionsByMessageCount: const [],
    topSessionsByEstimatedCost: const [],
  );
}

Future<void> _pumpFrames(WidgetTester tester, {int count = 5}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}
