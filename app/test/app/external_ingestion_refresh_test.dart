import 'dart:async';
import 'dart:io';

import 'package:codex_sessions_viewer/src/database/external_database_changes.dart';
import 'package:codex_sessions_viewer/src/app/runtime_session_controller.dart';
import 'package:codex_sessions_viewer/src/app/codex_sessions_viewer_app.dart';
import 'package:codex_sessions_viewer/src/ui/screens/evals_screen.dart';
import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/database/database_maintenance.dart';
import 'package:codex_sessions_viewer/src/database/database_migrator.dart';
import 'package:codex_sessions_viewer/src/database/database_connection.dart'
    show configureFileBackedDatabase;
import 'package:codex_sessions_viewer/src/database/session_list_query.dart';
import 'package:codex_sessions_viewer/src/ui/screens/sessions_screen.dart';
import 'package:codex_sessions_viewer/src/ui/screens/context_search_screen.dart';
import 'package:codex_sessions_viewer/src/search/message_search.dart';
import 'package:codex_sessions_viewer/src/ui/widgets/session_detail_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test(
    'external commits coalesce and reconnect catches missed commits',
    () async {
      final dir = await Directory.systemTemp.createTemp('external_revision_');
      final file = File('${dir.path}/fixture.sqlite');
      final writer = sqlite3.open(file.path);
      writer.execute('create table events (value integer)');
      var revisions = 0;
      final watcher = ExternalDatabaseChanges(
        file,
        onChange: () => revisions++,
      );
      try {
        watcher.check();
        expect(revisions, 1);
        for (var i = 0; i < 4; i++) {
          writer.execute('insert into events values (?)', [i]);
        }
        watcher.check();
        expect(revisions, 2);
        watcher.check();
        expect(revisions, 2);
        watcher.disconnect();
        writer.execute('insert into events values (99)');
        watcher.check();
        expect(revisions, 3);
        watcher.dispose();
        writer.execute('insert into events values (100)');
        watcher.check();
        expect(revisions, 3);
      } finally {
        watcher.dispose();
        writer.close();
        dir.deleteSync(recursive: true);
      }
    },
  );

  test(
    'journal deltas read only changed sessions, coalesce, and retain tombstones',
    () async {
      final dir = Directory.systemTemp.createTempSync('external_journal_');
      final file = File('${dir.path}/viewer.sqlite');
      final writer = sqlite3.open(file.path);
      final scripts =
          [
            ...Directory('../sql/init').listSync().whereType<File>(),
            ...Directory('../sql/migration').listSync().whereType<File>(),
          ].where((file) => file.path.endsWith('.sql')).toList()..sort(
            (a, b) =>
                a.uri.pathSegments.last.compareTo(b.uri.pathSegments.last),
          );
      for (final script in scripts) {
        writer.execute(script.readAsStringSync());
      }
      final controller = RuntimeSessionController(
        settingsFile: File('${dir.path}/unused.toml'),
        databaseFile: file,
      );
      try {
        writer.execute('begin');
        for (var i = 0; i < 1000; i++) {
          writer.execute(
            """
          insert into sessions(id, session_id, source_type, source_file_path,
            display_path, platform_path, title, started_at_utc, created_at_utc, updated_at_utc)
          values (?, ?, 'windows', ?, ?, ?, ?, '2026-06-10T00:00:00Z', 'now', 'now')
        """,
            ['s$i', 's$i', 'path$i', 'path$i', 'path$i', 'title$i'],
          );
        }
        writer.execute('commit');
        final pointQuery = sessionListQuery(sessionIds: ['s7']);
        final plan = writer
            .select(
              'explain query plan ${pointQuery.sql}',
              pointQuery.parameters,
            )
            .map((row) => row['detail'] as String)
            .join('\n');
        expect(plan, contains('SEARCH s '));
        expect(plan, isNot(contains('SCAN s ')));
        final initial = await controller.loadExternalRowChanges();
        expect(initial.reset, isTrue);
        expect(initial.rows, hasLength(1000));
        // Ordinary scan bookkeeping and logs must not reload any session rows.
        writer.execute(
          "update sessions set last_scanned_utc = 'later', updated_at_utc = 'later'",
        );
        var delta = await controller.loadExternalRowChanges(
          afterRevision: initial.revision,
        );
        expect(delta.revision, initial.revision);
        expect(delta.rows, isEmpty);
        expect(identical(delta.merge(initial.rows), initial.rows), isTrue);
        for (var i = 0; i < 5; i++) {
          writer.execute('update sessions set title = ? where id = ?', [
            'updated $i',
            's7',
          ]);
        }
        delta = await controller.loadExternalRowChanges(
          afterRevision: initial.revision,
        );
        expect(delta.changedIds, {'s7'});
        expect(delta.rows.single.title, 'updated 4');
        final merged = delta.merge(initial.rows);
        expect(merged, hasLength(1000));
        expect(
          identical(
            merged.firstWhere((r) => r.id == 's8'),
            initial.rows.firstWhere((r) => r.id == 's8'),
          ),
          isTrue,
        );
        final cursor = delta.revision;
        writer.execute("delete from sessions where id = 's7'");
        writer.execute(
          "update sessions set scan_status = 'missing' where id = 's8'",
        );
        // A different reader instance recovers using the same durable cursor.
        final reconnected = RuntimeSessionController(
          settingsFile: File('unused'),
          databaseFile: file,
        );
        delta = await reconnected.loadExternalRowChanges(afterRevision: cursor);
        expect(delta.changedIds, {'s7', 's8'});
        expect(delta.rows, isEmpty);
        expect(delta.merge(merged), hasLength(998));
        expect(
          writer
              .select(
                "select deleted from session_changes where session_id = 's7'",
              )
              .single['deleted'],
          1,
        );
        expect(
          writer.select('select count(*) n from session_changes').single['n'],
          1000,
        );
        final reset = await reconnected.loadExternalRowChanges(
          afterRevision: delta.revision! + 1,
        );
        expect(
          reset.reset,
          isTrue,
          reason:
              'A restored database with an older watermark requires a snapshot.',
        );
        expect(reset.rows, hasLength(998));
        expect(
          File('${dir.path}/unused.toml').existsSync(),
          isFalse,
          reason:
              'External reads must not load/create settings or scan sources.',
        );
      } finally {
        writer.close();
        dir.deleteSync(recursive: true);
      }
    },
  );

  testWidgets(
    'context refresh retains query and ignores stale search results',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 820));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final pending = <Completer<List<MessageSearchResult>>>[];
      Future<void> show() => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ContextSearchScreen(
              initialSessionRows: <SessionRowViewModel>[],
              onSearchMessages: (query) {
                expect(query.text, 'needle');
                final result = Completer<List<MessageSearchResult>>();
                pending.add(result);
                return result.future;
              },
            ),
          ),
        ),
      );
      await show();
      await tester.enterText(find.bySemanticsLabel('Context query'), 'needle');
      await tester.tap(find.bySemanticsLabel('Search context'));
      await tester.pump();
      await show();
      // Row changes re-run the query once they settle.
      await tester.pump(const Duration(milliseconds: 500));
      expect(pending.length, 2);
      pending.last.complete([
        MessageSearchResult(
          sessionId: 'new',
          messageIndex: 1,
          author: 'assistant',
          snippet: 'new needle',
          sessionIdentity: 'new session',
          sessionTitle: 'new session',
          projectName: 'Viewer',
          sourceType: 'windows',
          timestampUtc: DateTime.utc(2026),
        ),
      ]);
      await tester.pump();
      pending.first.complete([]);
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Context Search, 1 result'), findsOneWidget);
      final field = tester.widget<TextField>(
        find.descendant(
          of: find.bySemanticsLabel('Context query'),
          matching: find.byType(TextField),
        ),
      );
      expect(field.controller!.text, 'needle');
    },
  );

  testWidgets(
    'app composition refreshes only its mounted data views after commits',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1800, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final dir = Directory.systemTemp.createTempSync('external_composition_');
      final file = File('${dir.path}/viewer.sqlite');
      final writer = sqlite3.open(file.path);
      configureFileBackedDatabase(writer);
      final scripts =
          [
            ...Directory('../sql/init').listSync().whereType<File>(),
            ...Directory('../sql/migration').listSync().whereType<File>(),
          ].where((file) => file.path.endsWith('.sql')).toList()..sort(
            (a, b) =>
                a.uri.pathSegments.last.compareTo(b.uri.pathSegments.last),
          );
      for (final script in scripts) {
        writer.execute(script.readAsStringSync());
      }
      writer.execute("""
      insert into sessions(id, session_id, source_type, source_file_path,
        display_path, platform_path, title, started_at_utc, created_at_utc, updated_at_utc)
      values ('live', 'live', 'windows', 'absent', 'absent', 'absent', 'before',
        '2026-06-10T00:00:00Z', 'now', 'now')
    """);
      final settingsFile = File('${dir.path}/settings.toml');
      final controller = RuntimeSessionController(
        settingsFile: settingsFile,
        databaseFile: file,
      );
      var usageLoads = 0;
      var scanCalls = 0;
      Future<void> until(bool Function() predicate) async {
        final deadline = DateTime.now().add(const Duration(seconds: 12));
        while (!predicate() && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
          await tester.pump();
        }
        expect(predicate(), isTrue);
      }

      try {
        await tester.runAsync(() async {
          final settings = AppSettings.defaults();
          await SettingsRepository(settingsFile).save(settings);
          await tester.pumpWidget(
            CodexSessionsViewerApp(
              databaseFile: file,
              settingsFile: settingsFile,
              settingsStartup: Future.value(settings),
              sessionRefresh: () {
                scanCalls++;
                return controller.loadExternalRows();
              },
              usageSummaryLoader: (_, _) async {
                usageLoads++;
                return null;
              },
            ),
          );
          await until(
            () =>
                find.byType(SessionsScreen).evaluate().isNotEmpty &&
                tester
                    .widget<SessionsScreen>(find.byType(SessionsScreen))
                    .initialRows
                    .isNotEmpty,
          );
          final initialScanCalls = scanCalls;
          final initialUsageLoads = usageLoads;
          writer.execute(
            "update sessions set title = 'after' where id = 'live'",
          );
          await until(
            () =>
                tester
                    .widget<SessionsScreen>(find.byType(SessionsScreen))
                    .initialRows
                    .single
                    .title ==
                'after',
          );
          expect(initialUsageLoads, 0);
          expect(
            usageLoads,
            0,
            reason: 'Hidden Usage must not query on ingestion.',
          );
          expect(scanCalls, initialScanCalls);
          await tester.tap(
            find.bySemanticsLabel(RegExp('^Context navigation\\nTab ')),
          );
          await tester.pump();
          await until(
            () =>
                find.byType(ContextSearchScreen).evaluate().isNotEmpty &&
                tester
                    .widget<ContextSearchScreen>(
                      find.byType(ContextSearchScreen),
                    )
                    .initialSessionRows
                    .isNotEmpty,
          );
          writer.execute(
            "update sessions set title = 'context update' where id = 'live'",
          );
          await until(
            () =>
                tester
                    .widget<ContextSearchScreen>(
                      find.byType(ContextSearchScreen),
                    )
                    .initialSessionRows
                    .single
                    .title ==
                'context update',
          );
          await tester.tap(
            find.bySemanticsLabel(RegExp('^Evals navigation\\nTab ')),
          );
          await tester.pump();
          await until(
            () =>
                find.byType(EvalsScreen).evaluate().isNotEmpty &&
                tester
                    .widget<EvalsScreen>(find.byType(EvalsScreen))
                    .initialRows
                    .isNotEmpty,
          );
          writer.execute(
            "update sessions set title = 'eval update' where id = 'live'",
          );
          await until(
            () =>
                tester
                    .widget<EvalsScreen>(find.byType(EvalsScreen))
                    .initialRows
                    .single
                    .title ==
                'eval update',
          );
          await tester.tap(
            find.bySemanticsLabel(RegExp('^Projects navigation\\nTab ')),
          );
          await tester.pump();
          writer.execute(
            "insert into projects(name, created_at_utc, updated_at_utc) values ('live project', 'now', 'now')",
          );
          writer.execute(
            "update sessions set project_id = ? where id = 'live'",
            [writer.lastInsertRowId],
          );
          await until(() => find.text('live project').evaluate().isNotEmpty);
          expect(usageLoads, 0);
          await tester.tap(
            find.bySemanticsLabel(RegExp('^Usage navigation\\nTab ')),
          );
          await tester.pump();
          await until(() => usageLoads > 0);
          final visibleUsageLoads = usageLoads;
          writer.execute(
            "update sessions set total_tokens = 7 where id = 'live'",
          );
          await until(() => usageLoads > visibleUsageLoads);
          await tester.pumpWidget(const SizedBox.shrink());
        });
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        writer.close();
        dir.deleteSync(recursive: true);
      }
    },
  );

  testWidgets(
    'collector snapshots update production selection without scanning',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1800, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final dir = Directory.systemTemp.createTempSync('external_collector_');
      final file = File('${dir.path}/viewer.sqlite');
      final settingsFile = File('${dir.path}/settings.toml');
      final root = Directory('${dir.path}/codex');
      final sessions = Directory('${root.path}/sessions');
      sessions.createSync(recursive: true);
      final source = File(
        '../samples/sessions/sample_codex_jsonl_session.jsonl',
      ).copySync('${sessions.path}/fixture.jsonl');
      final settings = AppSettings.defaults().copyWith(
        paths: PathSettings(
          windowsCodexPath: root.path,
          wslCodexUncPath: '${dir.path}/absent',
        ),
      );
      await tester.runAsync(() async {
        await SettingsRepository(settingsFile).save(settings);
        final result = await DatabaseMigrator(
          sqlRoot: Directory('../sql'),
        ).openAndMigrate(file, deferUsageMigration: true);
        expect(
          result.canStartNormalUi,
          isTrue,
          reason: result.fatalError?.details,
        );
        final migration = await startPendingDatabaseMigration(
          file,
          sqlRoot: Directory('../sql'),
        );
        if (migration != null) {
          final outcome = await migration.result;
          expect(outcome.succeeded, isTrue, reason: outcome.state.name);
        }
      });
      final executable =
          Platform.environment['CODEX_SESSIONS_COLLECTOR_EXE'] ??
          '../collector/target/debug/codex-sessions-collector.exe';
      Future<void> collect() async {
        final result = await Process.run(executable, [
          'codex',
          'scan',
          '--no-wsl-projects',
          '--settings',
          settingsFile.path,
          '--db',
          file.path,
        ]);
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
      }

      final controller = RuntimeSessionController(
        settingsFile: settingsFile,
        databaseFile: file,
      );
      var scans = 0;
      var revision = 0;
      var detailLoads = 0;
      Future<SessionRowViewModel?>? lastDetailLoad;
      final watcher = ExternalDatabaseChanges(file, onChange: () => revision++);
      watcher.check();
      try {
        late ExternalSessionRows snapshot;
        var displayedRows = <SessionRowViewModel>[];
        await tester.runAsync(() async {
          await collect();
          snapshot = await controller.loadExternalRowChanges();
          displayedRows = snapshot.merge(displayedRows);
        });
        expect(displayedRows, isNotEmpty);
        Future<void> show() => tester.pumpWidget(
          MaterialApp(
            home: SessionsScreen(
              initialRows: displayedRows,
              externalRevision: revision,
              now: () => DateTime.utc(2026, 6, 15),
              onRefresh: () async {
                scans++;
                return displayedRows;
              },
              onLoadSessionDetail: (id) async {
                detailLoads++;
                return lastDetailLoad = tester.runAsync<SessionRowViewModel?>(
                  () => controller.loadSessionDetail(id),
                );
              },
              watchSessionFile: (_) => const Stream.empty(),
            ),
          ),
        );
        watcher.check();
        await show();
        final sessionRow = find.byWidgetPredicate(
          (widget) =>
              widget is Semantics &&
              widget.properties.onTap != null &&
              (widget.properties.label ?? '').startsWith('Session ') &&
              (widget.properties.label ?? '').contains('. Status '),
        );
        expect(sessionRow, findsOneWidget);
        await tester.tap(sessionRow);
        expect(detailLoads, 1);
        expect(await lastDetailLoad, isNotNull);
        await tester.pump(const Duration(milliseconds: 300));
        final before = tester
            .widget<SessionDetailPane>(find.byType(SessionDetailPane))
            .row;
        final search = find.descendant(
          of: find.bySemanticsLabel('Session search'),
          matching: find.byType(TextField),
        );
        final query = before.title.split(' ').first;
        await tester.enterText(search, query);
        await tester.pump(const Duration(milliseconds: 350));
        final focus = FocusManager.instance.primaryFocus;
        final beforeUnrelatedLoads = detailLoads;
        await tester.runAsync(() async {
          final otherSource = File('${sessions.path}/other.jsonl');
          await otherSource.writeAsString(
            source.readAsStringSync().replaceAll(
              'jsonl-session-001',
              'jsonl-session-002',
            ),
          );
          await collect();
          final unrelated = await controller.loadExternalRowChanges(
            afterRevision: snapshot.revision,
          );
          expect(unrelated.changedIds, isNot(contains(before.id)));
          snapshot = unrelated;
          displayedRows = snapshot.merge(displayedRows);
        });
        watcher.check();
        await show();
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          detailLoads,
          beforeUnrelatedLoads,
          reason:
              'Another session commit must not reload the selected conversation.',
        );
        await tester.runAsync(() async {
          await source.writeAsString(
            '\n{"timestamp":"2026-06-15T10:05:00Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"external collector appended answer"}]}}\n',
            mode: FileMode.append,
          );
          await collect();
          snapshot = await controller.loadExternalRowChanges(
            afterRevision: snapshot.revision,
          );
          expect(snapshot.changedIds, {before.id});
          displayedRows = snapshot.merge(displayedRows);
        });
        expect(
          displayedRows.firstWhere((row) => row.id == before.id).messageCount,
          greaterThan(before.messageCount),
        );
        watcher.check();
        await show();
        await tester.pump(const Duration(milliseconds: 300));
        expect(detailLoads, greaterThan(1));
        final loadedDetail = await lastDetailLoad;
        expect(loadedDetail, isNotNull);
        expect(
          loadedDetail!.messageCount,
          greaterThan(before.messageCount),
          reason: 'The selected detail loader must see the collector commit.',
        );
        await tester.pump(const Duration(seconds: 1));
        final after = tester
            .widget<SessionDetailPane>(find.byType(SessionDetailPane).last)
            .row;
        expect(after.id, before.id);
        expect(after.messageCount, greaterThan(before.messageCount));
        expect(
          after.conversationMessages.any(
            (m) => m.body.contains('external collector appended answer'),
          ),
          isTrue,
        );
        expect(scans, 0);
        expect(tester.widget<TextField>(search).controller!.text, query);
        expect(FocusManager.instance.primaryFocus, same(focus));
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        watcher.dispose();
        dir.deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
