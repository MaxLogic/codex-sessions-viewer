import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/database/database_connection.dart';
import 'package:codex_sessions_viewer/src/pricing/pricing_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory tempDir;
  late File dbFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('csv_db_connection_test_');
    dbFile = File('${tempDir.path}${Platform.pathSeparator}viewer.sqlite');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('file-backed connections enable WAL and busy timeout', () {
    final db = openFileBackedDatabase(dbFile);
    addTearDown(db.close);

    final journalMode = db.select('pragma journal_mode').single.values.single;
    final busyTimeout = db.select('pragma busy_timeout').single.values.single;

    expect(journalMode, 'wal');
    expect(busyTimeout, greaterThan(0));
  });

  test('configuration fails when SQLite does not enable WAL', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);

    expect(
      () => configureFileBackedDatabase(db),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('WAL journal mode'),
        ),
      ),
    );
  });

  test('separate process writers serialize through the busy timeout', () async {
    final setup = openFileBackedDatabase(dbFile);
    setup.execute('create table actor_writes (value text not null)');
    setup.close();
    final signalBase = '${dbFile.path}.writer_test';
    final contender = await _startActor(dbFile, 'write', signalBase);
    _registerActorCleanup(contender, signalBase);
    expect(await contender.nextOutputLine(), 'ready');
    final holder = await _startActor(dbFile, 'hold', signalBase);
    _registerActorCleanup(holder, signalBase);
    expect(await holder.nextOutputLine(), 'locked');
    await File('$signalBase.start').create();
    expect(await contender.nextOutputLine(), 'attempting');

    await File('$signalBase.release').create();

    expect(await holder.process.exitCode, 0);
    expect(await contender.process.exitCode, 0);
    final verification = openFileBackedDatabase(dbFile);
    addTearDown(verification.close);
    expect(
      verification
          .select('select value from actor_writes order by rowid')
          .map((row) => row['value']),
      ['holder', 'contender'],
    );
  });

  test(
    'cached pricing remains readable while another process writes',
    () async {
      final setup = openFileBackedDatabase(dbFile);
      setup.execute(
        File('../sql/init/001_initial_schema.sql').readAsStringSync(),
      );
      setup.execute('create table actor_writes (value text not null)');
      setup.close();
      final signalBase = '${dbFile.path}.reader_test';
      final holder = await _startActor(dbFile, 'hold', signalBase);
      _registerActorCleanup(holder, signalBase);
      expect(await holder.nextOutputLine(), 'locked');
      final reader = openFileBackedDatabase(dbFile, busyTimeoutMs: 100);
      addTearDown(reader.close);

      final catalog = PricingRepository(
        reader,
      ).loadCached(_pricingSettings, nowUtc: DateTime.utc(2026, 6, 13, 10));

      expect(catalog.models['local/model']?.promptPricePerToken, '0.10');
      await File('$signalBase.release').create();
      expect(await holder.process.exitCode, 0);
    },
  );
}

Future<_ActorProcess> _startActor(
  File databaseFile,
  String mode,
  String signalBase,
) async {
  final helper = [
    Directory.current.path,
    'test',
    'database',
    'helpers',
    'database_process_actor.dart',
  ].join(Platform.pathSeparator);
  final process = await Process.start(_dartExecutable(), [
    '--packages=.dart_tool/package_config.json',
    helper,
    databaseFile.path,
    mode,
    signalBase,
  ], workingDirectory: Directory.current.path);
  return _ActorProcess(process);
}

void _registerActorCleanup(_ActorProcess actor, String signalBase) {
  addTearDown(() async {
    await File('$signalBase.start').create();
    await File('$signalBase.release').create();
    actor.process.kill();
    await actor.process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () => -1,
    );
  });
}

String _dartExecutable() {
  final separator = Platform.isWindows ? ';' : ':';
  final executableName = Platform.isWindows ? 'dart.exe' : 'dart';
  for (final entry in (Platform.environment['PATH'] ?? '').split(separator)) {
    final direct = File([entry, executableName].join(Platform.pathSeparator));
    if (direct.existsSync()) {
      return direct.path;
    }
    final flutterSdk = File(
      [
        entry,
        'cache',
        'dart-sdk',
        'bin',
        executableName,
      ].join(Platform.pathSeparator),
    );
    if (flutterSdk.existsSync()) {
      return flutterSdk.path;
    }
  }
  throw StateError('Unable to locate the Dart SDK executable.');
}

class _ActorProcess {
  _ActorProcess(this.process)
    : _lines = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );

  final Process process;
  final StreamIterator<String> _lines;

  Future<String> nextOutputLine() async {
    final hasLine = await _lines.moveNext().timeout(
      const Duration(seconds: 30),
    );
    if (!hasLine) {
      final error = await process.stderr.transform(utf8.decoder).join();
      throw StateError('Database actor exited without output. $error');
    }
    return _lines.current;
  }
}

const _pricingSettings = PricingSettings(
  provider: 'openrouter',
  useExternalPricing: false,
  cachePricingHours: 24,
  fallbackToOverrides: true,
  openRouter: OpenRouterSettings(
    modelsEndpoint: 'https://openrouter.ai/api/v1/models',
    apiKey: '',
  ),
  overrides: {
    'local/model': PricingOverrideSettings(
      prompt: '0.10',
      completion: '0.20',
      inputCacheRead: '0.03',
      inputCacheWrite: '0.04',
      internalReasoning: '0.05',
    ),
  },
);
