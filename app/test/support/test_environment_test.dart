import 'test_environment.dart';
import 'package:codex_sessions_viewer/src/platform/app_environment.dart';
import 'package:codex_sessions_viewer/src/config/default_session_folders.dart';
import 'dart:io';

import 'package:codex_sessions_viewer/src/platform/app_locations.dart';
import 'package:codex_sessions_viewer/src/scanner/collector_process.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('system locations cannot be inherited from a profile', () {
    final ctx = TestEnvironment.current;
    for (final key in [
      'SYSTEMROOT',
      'WINDIR',
      'COMSPEC',
      'PROGRAMDATA',
      'PROGRAMFILES',
      'SYSTEMDRIVE',
    ]) {
      expect(
        () => TestEnvironment.create(
          inherited: {
            ...Platform.environment,
            key: p.join(ctx.environment['APPDATA']!, 'poison-system'),
          },
        ),
        throwsStateError,
        reason: key,
      );
    }
  });
  test('native hub endpoints require an owned loopback fixture', () async {
    final ctx = TestEnvironment.current;
    for (final url in ['https://example.invalid', 'http://127.0.0.1:12345']) {
      expect(
        () => ctx.admit(
          ctx.environment['CODEX_SESSIONS_COLLECTOR_EXE']!,
          ['codex', 'verify', '--hub-url', url],
          ctx.environment,
          ctx.root.path,
        ),
        throwsStateError,
        reason: url,
      );
    }
    final fixture = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    try {
      final uri = Uri.parse('http://127.0.0.1:${fixture.port}');
      ctx.ownEndpoint(uri);
      expect(
        () => ctx.admit(
          ctx.environment['CODEX_SESSIONS_COLLECTOR_EXE']!,
          ['codex', 'verify', '--hub-url', '$uri'],
          ctx.environment,
          ctx.root.path,
        ),
        returnsNormally,
      );
    } finally {
      await fixture.close();
    }
  });
  test(
    'mixed-case profile overrides and native store tools fail closed',
    () async {
      final ctx = TestEnvironment.current;
      expect(
        () => ctx.admit(
          ctx.environment['CODEX_SESSIONS_COLLECTOR_EXE']!,
          ['version'],
          {...ctx.environment, 'APPDATA': '.'},
          ctx.root.path,
        ),
        throwsStateError,
      );

      await expectLater(
        runTestProcess(
          Platform.resolvedExecutable,
          ['--version'],
          environment: {
            'appdata': p.join(p.dirname(ctx.root.path), 'poisoned-profile'),
          },
        ),
        throwsStateError,
      );
      for (final tool in [
        'schtasks',
        'reg',
        'powershell.exe',
        'wsl.exe',
        'unknown.exe',
      ]) {
        expect(
          () => ctx.admit(tool, ['/Create'], ctx.environment, ctx.root.path),
          throwsStateError,
          reason: tool,
        );
      }
    },
  );
  test('child environments exclude arbitrary inherited variables', () {
    final ctx = TestEnvironment.create(
      inherited: {...Platform.environment, 'UNRECOGNIZED_PROFILE': 'sentinel'},
    );
    expect(ctx.environment.containsKey('UNRECOGNIZED_PROFILE'), isFalse);
  });
  test('native scan ignores poisoned inherited default settings', () async {
    final parent = TestEnvironment.current;
    final poison = Directory(
      p.join(parent.root.path, 'synthetic-inherited-profile'),
    )..createSync();
    final sentinel = File(
      p.join(poison.path, 'CodexSessionViewer', 'settings.toml'),
    );
    sentinel.parent.createSync();
    sentinel.writeAsStringSync('POISONED_INHERITED_SETTINGS = [');
    final isolated = TestEnvironment.create(
      inherited: {...Platform.environment, 'APPDATA': poison.path},
    );
    await isolated.run(() async {
      final output = await runTestProcess(
        isolated.environment['CODEX_SESSIONS_COLLECTOR_EXE']!,
        [
          'codex',
          'scan',
          '--standalone',
          p.join(isolated.root.path, 'sentinel.sqlite'),
          '--no-wsl-projects',
          '--json',
        ],
      );
      expect(output.exitCode, 0, reason: output.stderr.toString());
      expect(
        output.stderr.toString(),
        isNot(contains('POISONED_INHERITED_SETTINGS')),
      );
      expect(sentinel.readAsStringSync(), 'POISONED_INHERITED_SETTINGS = [');
    });
  });
  test(
    'collector launch rejects an escaped database before spawning',
    () async {
      await expectLater(
        startCollectorProcess('missing-cxv-isolation-probe', [
          'version',
          '--db',
          p.join(
            Directory.current.path,
            'synthetic-real-profile',
            'viewer.sqlite',
          ),
        ]),
        throwsStateError,
      );
    },
  );

  test('default app storage never resolves into the inherited profile', () {
    final inherited =
        Platform.environment['APPDATA'] ?? Platform.environment['HOME']!;
    expect(
      p.isWithin(inherited, AppLocations.current().databaseFile.path),
      isFalse,
    );
  });
  test(
    'every inherited profile variable is rejected after overrides',
    () async {
      final context = TestEnvironment.current;
      final syntheticReal = p.join(
        p.dirname(context.root.path),
        'synthetic-real-profile',
      );
      for (final key in TestEnvironment.profileKeys) {
        await expectLater(
          runTestProcess(
            'missing-native-isolation-probe',
            ['version'],
            environment: {key: syntheticReal},
          ),
          throwsStateError,
          reason: key,
        );
      }
      await expectLater(
        runTestProcess(
          'missing-native-isolation-probe',
          [],
          environment: {'CODEX_SESSIONS_COLLECTOR_FUTURE_LOG': syntheticReal},
        ),
        throwsStateError,
      );
    },
  );

  test('native launches reject settings with escaped session roots', () async {
    final settings = File(
      p.join(TestEnvironment.current.root.path, 'unsafe.toml'),
    );
    await settings.writeAsString(
      "[paths]\nwindows_codex_path = 'C:\\synthetic-real-profile\\sessions'",
    );
    await expectLater(
      runTestProcess(
        TestEnvironment.current.environment['CODEX_SESSIONS_COLLECTOR_EXE']!,
        ['codex', 'scan', '--settings', settings.path],
      ),
      throwsStateError,
    );
    await settings.delete();
  });

  test(
    'in-process default homes and app data remain inside the owned root',
    () {
      final context = TestEnvironment.current;
      final locations = AppLocations.current();
      for (final path in [
        locations.settingsFile.path,
        locations.databaseFile.path,
        locations.logDirectory.path,
        locations.backupDirectory.path,
        locations.queueDirectory.path,
        DefaultSessionFolders.current().windowsCodexPath,
        DefaultSessionFolders.current().claudeProjectsRoot,
        Directory.systemTemp.path,
      ]) {
        expect(() => context.guard(path), returnsNormally, reason: path);
      }
      expect(
        AppEnvironment.current['HOME'],
        isNot(Platform.environment['HOME']),
      );
    },
  );

  test(
    'worker isolates preserve defaults and fail-fast launch checks',
    () async {
      final root = TestEnvironment.current.root.path;
      final result = await AppEnvironment.runIsolate(() async {
        TestEnvironment.current.guard(AppLocations.current().databaseFile.path);
        TestEnvironment.current.guard(Directory.systemTemp.path);
        try {
          await startCollectorProcess('missing-isolate-probe', [
            'version',
            '--db',
            'C:\\synthetic-real-profile\\viewer.sqlite',
          ]);
        } on StateError {
          return AppEnvironment.current['HOME'];
        }
        throw StateError('worker did not reject unowned database');
      });
      expect(p.isWithin(root, result!), isTrue);
    },
  );

  test(
    'an unsafe sandbox parent is rejected before creating a profile folder',
    () {
      final fakeReal = p.join(
        TestEnvironment.current.root.path,
        'must-not-be-created',
      );
      expect(
        () => TestEnvironment.create(
          inherited: {
            ...Platform.environment,
            'USERPROFILE': fakeReal,
            'CXV_TEST_SANDBOX_PARENT': p.join(fakeReal, 'tests'),
          },
        ),
        throwsStateError,
      );
      expect(Directory(fakeReal).existsSync(), isFalse);
    },
  );
  test(
    'the temp override preserves native file and link type checks',
    () async {
      final root = await Directory.systemTemp.createTemp('native-types-');
      try {
        final file = File(p.join(root.path, 'file'))
          ..writeAsStringSync('fixture');
        expect(
          FileSystemEntity.typeSync(file.path, followLinks: false),
          FileSystemEntityType.file,
        );
        expect(
          await FileSystemEntity.type(file.path, followLinks: false),
          FileSystemEntityType.file,
        );
        TestEnvironment.current.guard(file.path);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
  test(
    'all input and benchmark path flags reject unowned paths before spawn',
    () async {
      for (final flag in ['--input', '--root', '--work', '--result']) {
        await expectLater(
          runTestProcess('missing-path-probe', [
            flag,
            'C:/synthetic-real-profile/input',
          ]),
          throwsStateError,
          reason: flag,
        );
      }
      await expectLater(
        runTestProcess('missing-path-probe', [
          'codex',
          'ingest',
          'C:/synthetic-real-profile/input',
          '--db',
          '${TestEnvironment.current.root.path}/owned.sqlite',
        ]),
        throwsStateError,
      );
    },
  );
  test(
    'hook transcript escape is rejected before the hook process starts',
    () async {
      await expectLater(
        startTestProcess(
          'missing-hook-probe',
          [],
          hookInput: {
            'transcript_path': 'C:/synthetic-real-profile/transcript.jsonl',
          },
        ),
        throwsStateError,
      );
    },
  );
}
