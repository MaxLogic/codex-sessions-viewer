@TestOn('windows')
library;

import 'dart:io';

import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/database/database_migrator.dart';
import 'package:codex_sessions_viewer/src/scanner/resident_collector_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'collector_fixture.dart';

void main() {
  test(
    'fixture guard reports an open SQLite handle before deleting files',
    () async {
      final root = await Directory.systemTemp.createTemp('csv_fixture_handle_');
      final marker = File('${root.path}/keep.txt')..writeAsStringSync('keep');
      final db = sqlite3.open('${root.path}/viewer.sqlite');
      db.execute('create table probe (id integer)');
      try {
        await expectLater(deleteCollectorFixture(root), throwsStateError);
        expect(marker.existsSync(), isTrue);
      } finally {
        db.close();
        await deleteCollectorFixture(root);
      }
    },
  );

  test(
    'fixture guard rejects an undisposed bridge, then stops its owned resident',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'csv_fixture_resident_',
      );
      final db = File('${root.path}/viewer.sqlite');
      final settings = File('${root.path}/settings.toml');
      await SettingsRepository(settings).save(
        AppSettings.defaults().copyWith(
          paths: PathSettings(
            windowsCodexPath: '${root.path}/empty',
            wslCodexUncPath: '${root.path}/absent',
          ),
          scanner: const ScannerSettings(
            backgroundRescanEnabled: false,
            backgroundRescanIntervalSeconds: 3600,
          ),
        ),
      );
      expect(
        (await DatabaseMigrator(
          sqlRoot: Directory('../sql'),
        ).openAndMigrate(db)).canStartNormalUi,
        isTrue,
      );
      final client = ResidentCollectorClient(
        databaseFile: db,
        settingsFile: settings,
      );
      try {
        await client.connect();
        await expectLater(deleteCollectorFixture(root), throwsStateError);
        expect(root.existsSync(), isTrue);
        await client.dispose();
        // Production's viewer resident is still inside its 30-second idle grace.
        // The shared teardown must stop it and assert every handle is released.
        await deleteCollectorFixture(root);
        expect(root.existsSync(), isFalse);
      } finally {
        await client.dispose();
        if (root.existsSync()) await deleteCollectorFixture(root);
      }
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );
}
