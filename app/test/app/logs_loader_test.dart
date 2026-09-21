import 'dart:io';

import 'package:codex_sessions_viewer/src/app/logs_loader.dart';
import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/database/database_connection.dart';
import 'package:codex_sessions_viewer/src/database/database_maintenance.dart';
import 'package:codex_sessions_viewer/src/database/database_migrator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  testWidgets('Logs screen shows stored entries and clears old ones', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime.utc(2026, 9, 21, 12);
    late File databaseFile;
    await tester.runAsync(() async {
      final temp = await Directory.systemTemp.createTemp('csv_logs_loader_');
      addTearDown(() => temp.delete(recursive: true));
      databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
      final startup = await DatabaseMigrator(
        sqlRoot: Directory('../sql'),
      ).openAndMigrate(databaseFile);
      expect(startup.canStartNormalUi, isTrue);
      final db = openFileBackedDatabase(databaseFile);
      try {
        for (final (time, message) in [
          (now.subtract(const Duration(hours: 1)), 'Recent scan finished'),
          (now.subtract(const Duration(days: 30)), 'Ancient parse warning'),
        ]) {
          db.execute(
            'insert into logs (time_utc, level, category, message, details) '
            "values (?, 'warning', 'scanner', ?, null)",
            [time.toIso8601String(), message],
          );
        }
      } finally {
        db.close();
      }
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LogsLoader(
            databaseFile: databaseFile,
            settings: AppSettings.defaults().logging,
            writerCoordinator: DatabaseMaintenanceCoordinator(databaseFile),
            nowUtc: () => now,
          ),
        ),
      ),
    );
    await _pumpUntil(tester, find.textContaining('Recent scan finished'));

    expect(find.textContaining('Recent scan finished'), findsWidgets);
    expect(find.textContaining('Ancient parse warning'), findsWidgets);

    await tester.tap(find.textContaining('Clear old logs').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear logs'));
    await _pumpUntil(
      tester,
      find.textContaining('Ancient parse warning'),
      present: false,
    );

    expect(find.textContaining('Recent scan finished'), findsWidgets);
    expect(find.textContaining('Ancient parse warning'), findsNothing);
  });
}

Future<void> _pumpUntil(
  WidgetTester tester,
  Finder finder, {
  bool present = true,
}) async {
  for (var i = 0; i < 50; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    if (finder.evaluate().isNotEmpty == present) {
      return;
    }
  }
}
