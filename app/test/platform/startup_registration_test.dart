import 'dart:io';

import 'package:codex_sessions_viewer/src/platform/app_locations.dart';
import 'package:codex_sessions_viewer/src/platform/startup_registration.dart';
import 'package:codex_sessions_viewer/src/platform/windows_startup_registration.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;
  late List<String> requested;
  File fileForPath(String path) {
    requested.add(path);
    return File(p.join(temp.path, p.posix.basename(path)));
  }

  setUp(() {
    temp = Directory.systemTemp.createTempSync('cxv_startup_');
    requested = [];
  });
  tearDown(() => temp.deleteSync(recursive: true));

  for (final platform in [AppHostPlatform.macos, AppHostPlatform.linux]) {
    test(
      '$platform failed write retains old registration and cleans staging',
      () async {
        final owned = File(p.join(temp.path, 'registration'))
          ..writeAsStringSync('OLD');
        final failure = FileSystemException('injected failed flush');
        final registration = StartupRegistration.forCurrentPlatform(
          platform: platform,
          environment: {'HOME': '/fixture'},
          executablePath: '/opt/viewer',
          fileForPath: (_) => owned,
          writeReplacementFile: (file, content) async {
            await file.writeAsString('PARTIAL');
            throw failure;
          },
        );
        await expectLater(
          registration.apply(enabled: true),
          throwsA(same(failure)),
        );
        expect(await owned.readAsString(), 'OLD');
        expect(temp.listSync().map((entry) => p.basename(entry.path)), [
          'registration',
        ]);
      },
    );
    test(
      '$platform failed rename retains destination directory and cleans staging',
      () async {
        final owned = Directory(p.join(temp.path, 'registration'))
          ..createSync();
        final other = File(p.join(owned.path, 'keep'))
          ..writeAsStringSync('KEEP');
        final registration = StartupRegistration.forCurrentPlatform(
          platform: platform,
          environment: {'HOME': '/fixture'},
          executablePath: '/opt/viewer',
          fileForPath: (_) => File(owned.path),
        );
        await expectLater(
          registration.apply(enabled: true),
          throwsA(isA<FileSystemException>()),
        );
        expect(await other.readAsString(), 'KEEP');
        expect(temp.listSync().map((entry) => p.basename(entry.path)), [
          'registration',
        ]);
      },
    );
    for (final symbolic in [false, true]) {
      test(
        '$platform enable replaces ${symbolic ? 'symbolic' : 'hard'} link without changing its target',
        () async {
          final target = File(p.join(temp.path, 'unrelated'))
            ..writeAsStringSync('KEEP TARGET');
          final owned = File(p.join(temp.path, 'registration'));
          if (symbolic) {
            await Link(owned.path).create(target.path);
          } else if (Platform.isWindows) {
            final result = await Process.run('fsutil', [
              'hardlink',
              'create',
              owned.path,
              target.path,
            ]);
            expect(
              result.exitCode,
              0,
              reason: '${result.stdout} ${result.stderr}',
            );
          } else {
            final result = await Process.run('ln', [target.path, owned.path]);
            expect(
              result.exitCode,
              0,
              reason: '${result.stdout} ${result.stderr}',
            );
          }
          final registration = StartupRegistration.forCurrentPlatform(
            platform: platform,
            environment: {'HOME': '/fixture'},
            executablePath: '/opt/viewer',
            fileForPath: (_) => owned,
          );
          await registration.apply(enabled: true);
          expect(await target.readAsString(), 'KEEP TARGET');
          expect(
            await owned.readAsString(),
            contains(
              platform == AppHostPlatform.macos ? '<plist' : '[Desktop Entry]',
            ),
          );
          expect(
            await FileSystemEntity.type(owned.path, followLinks: false),
            FileSystemEntityType.file,
          );
          await registration.apply(enabled: false);
          expect(await target.readAsString(), 'KEEP TARGET');
          expect(temp.listSync().map((entry) => p.basename(entry.path)), [
            'unrelated',
          ]);
        },
      );
    }
  }

  test(
    'macOS registers a direct executable LaunchAgent and removes only it',
    () async {
      final other = File(p.join(temp.path, 'other.plist'))
        ..writeAsStringSync('keep');
      final registration = StartupRegistration.forCurrentPlatform(
        platform: AppHostPlatform.macos,
        environment: {'HOME': '/Users/A & B'},
        executablePath:
            '/Applications/A & <B> "quoted".app/Contents/MacOS/viewer',
        fileForPath: fileForPath,
      );
      await registration.apply(enabled: true);
      expect(
        requested.single,
        '/Users/A & B/Library/LaunchAgents/eu.maxlogic.codexsessionsviewer.plist',
      );
      final file = fileForPath(requested.single);
      expect(
        await file.readAsString(),
        contains(
          '<string>/Applications/A &amp; &lt;B&gt; "quoted".app/Contents/MacOS/viewer</string>',
        ),
      );
      expect(
        await file.readAsString(),
        contains('<key>RunAtLoad</key>\n  <true/>'),
      );
      expect(await file.readAsString(), isNot(contains('/bin/sh')));
      await registration.apply(enabled: false);
      await registration.apply(enabled: false);
      expect(await file.exists(), isFalse);
      expect(await other.readAsString(), 'keep');
    },
  );

  test(
    'Linux uses XDG autostart and quotes both desktop value and Exec layers',
    () async {
      final registration = StartupRegistration.forCurrentPlatform(
        platform: AppHostPlatform.linux,
        environment: {
          'HOME': '/home/user',
          'XDG_CONFIG_HOME': '/custom/config',
        },
        executablePath: r'/opt/A "quoted" $d `tick` \back %f & ; viewer',
        fileForPath: fileForPath,
      );
      await registration.apply(enabled: true);
      expect(
        requested.single,
        '/custom/config/autostart/eu.maxlogic.codexsessionsviewer.desktop',
      );
      final file = fileForPath(requested.single);
      expect(await file.readAsString(), r'''[Desktop Entry]
Type=Application
Name=Codex Session Viewer
Exec="/opt/A \\"quoted\\" \\$d \\`tick\\` \\\\back %%f & ; viewer"
Terminal=false
''');
      await registration.apply(enabled: false);
      await registration.apply(enabled: false);
      expect(await file.exists(), isFalse);
    },
  );

  for (final config in [null, '', 'relative/config']) {
    test(
      'Linux falls back to HOME for invalid XDG_CONFIG_HOME: $config',
      () async {
        final registration = StartupRegistration.forCurrentPlatform(
          platform: AppHostPlatform.linux,
          environment: {'HOME': '/home/user', 'XDG_CONFIG_HOME': ?config},
          executablePath: '/opt/viewer',
          fileForPath: fileForPath,
        );
        await registration.apply(enabled: true);
        expect(
          requested.single,
          '/home/user/.config/autostart/eu.maxlogic.codexsessionsviewer.desktop',
        );
      },
    );
  }

  test('valid XDG config does not require HOME', () async {
    final registration = StartupRegistration.forCurrentPlatform(
      platform: AppHostPlatform.linux,
      environment: {'XDG_CONFIG_HOME': '/config'},
      executablePath: '/opt/viewer',
      fileForPath: fileForPath,
    );
    await registration.apply(enabled: true);
    expect(
      requested.single,
      '/config/autostart/eu.maxlogic.codexsessionsviewer.desktop',
    );
  });

  test(
    'invalid HOME, executable or desktop executable fails before writing',
    () async {
      for (final platform in [AppHostPlatform.macos, AppHostPlatform.linux]) {
        for (final invalid in [
          <String, String>{},
          {'HOME': 'relative'},
        ]) {
          expect(
            () => StartupRegistration.forCurrentPlatform(
              platform: platform,
              environment: invalid,
              executablePath: '/opt/viewer',
              fileForPath: fileForPath,
            ),
            throwsArgumentError,
          );
        }
        for (final exe in [
          'relative/viewer',
          '/opt/viewer\nentry',
          '/opt/viewer\u0000',
        ]) {
          final registration = StartupRegistration.forCurrentPlatform(
            platform: platform,
            environment: {'HOME': '/home/user'},
            executablePath: exe,
            fileForPath: fileForPath,
          );
          await expectLater(
            registration.apply(enabled: true),
            throwsArgumentError,
          );
        }
      }
      final registration = StartupRegistration.forCurrentPlatform(
        platform: AppHostPlatform.linux,
        environment: {'HOME': '/home/user'},
        executablePath: '/opt/a=b',
        fileForPath: fileForPath,
      );
      await expectLater(registration.apply(enabled: true), throwsArgumentError);
      expect(temp.listSync(), isEmpty);
    },
  );

  test('Windows factory retains registry Run-key behavior', () async {
    final calls = <List<String>>[];
    final registration = StartupRegistration.forCurrentPlatform(
      platform: AppHostPlatform.windows,
      environment: {},
      executablePath: r'C:\Program Files\viewer.exe',
      runProcess: (executable, arguments) async {
        expect(executable, 'reg');
        calls.add(arguments);
        return ProcessResult(1, 0, '', '');
      },
    );
    await registration.apply(enabled: true);
    await registration.apply(enabled: false);
    expect(calls.first, contains(WindowsStartupRegistration.runKey));
    expect(calls.first, contains(r'"C:\Program Files\viewer.exe"'));
    expect(calls.map((call) => call.first), ['add', 'query', 'delete']);
  });
}
