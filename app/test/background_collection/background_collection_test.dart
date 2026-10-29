import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../support/autostart_fixture.dart';
import 'package:xml/xml.dart';

import 'package:codex_sessions_viewer/src/background_collection/background_collection.dart';
import 'package:codex_sessions_viewer/src/background_collection/collector_autostart.dart';
import 'package:flutter_test/flutter_test.dart';

ProcessResult _ok([String out = '']) => ProcessResult(0, 0, out, '');
ProcessResult _fail([String err = 'boom']) => ProcessResult(0, 1, '', err);

const _taskName = r'Codex Session Viewer\Background collection';
const _listWithTask =
    '"\\Adobe Task","01.10.2026 20:00:00","Ready"\r\n'
    '"\\Codex Session Viewer\\Background collection","01.10.2026 20:00:00","Ready"\r\n';
const _listWithoutTask = '"\\Adobe Task","01.10.2026 20:00:00","Ready"\r\n';

class _FakeScheduler implements CollectorAutostart {
  _FakeScheduler({this.supported = true});

  final bool supported;
  ScheduledScanState state = const ScheduledScanState(installed: false);
  CollectorAutostartRequest? installed;
  int removed = 0;
  CollectorAutostartException? failure;
  CollectorAutostartException? queryFailure;

  @override
  bool get isSupported => supported;

  @override
  Future<ScheduledScanState> query({
    CollectorAutostartRequest? expected,
  }) async {
    if (queryFailure != null) throw queryFailure!;
    return state;
  }

  @override
  Future<void> install(CollectorAutostartRequest request) async {
    if (failure != null) throw failure!;
    installed = request;
    state = ScheduledScanState(
      installed: true,
      intervalMinutes: 5,
      enabled: request.enabled,
    );
  }

  int upgrades = 0;
  @override
  Future<String?> upgrade(
    CollectorAutostartRequest request,
    Directory backups,
  ) async {
    upgrades++;
    if (failure != null) throw failure!;
    if (!state.installed || !state.outdated) return null;
    final enabled = state.enabled;
    await install(request);
    state = ScheduledScanState(installed: true, enabled: enabled);
    return '${backups.path}/old-task.xml';
  }

  @override
  Future<void> enable() async {
    state = ScheduledScanState(
      installed: state.installed,
      outdated: state.outdated,
    );
  }

  @override
  Future<void> remove() async {
    removed++;
    state = const ScheduledScanState(installed: false);
  }
}

void main() {
  group('resident autostart upgrade', () {
    late Directory root;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('cxv185-unit-');
    });
    tearDown(() async {
      await root.delete(recursive: true);
    });
    test(
      'outdated installed task is backed up before automatic rewrite, once',
      () async {
        final fixture = AutostartFixture(root);
        await Future.wait([
          fixture.collection.initialize(),
          fixture.collection.initialize(),
        ]);
        final status = await fixture.collection.status();
        expect(fixture.creates, 1);
        expect(fixture.backupBeforeCreate, isTrue);
        expect(status.schedule.outdated, isFalse);
        expect(status.autostartUpdate?.backupPath, fixture.backups.single.path);
        expect(
          XmlDocument.parse(
            fixture.backups.single.readAsStringSync(),
          ).rootElement.toXmlString(),
          XmlDocument.parse(fixture.original!).rootElement.toXmlString(),
        );
      },
    );
    test('outdated disabled task stays disabled after rewrite', () async {
      final fixture = AutostartFixture(root, enabled: false);
      final status = await fixture.collection.status();
      expect(fixture.creates, 1);
      expect(status.schedule.outdated, isFalse);
      expect(status.schedule.enabled, isFalse);
      expect(status.autostartUpdate?.keptDisabled, isTrue);
    });
    test(
      'explicit enable turns on a disabled installed task without rewriting it',
      () async {
        final fixture = AutostartFixture(root, enabled: false);
        await fixture.collection.initialize();
        expect((await fixture.collection.status()).schedule.enabled, isFalse);
        final creates = fixture.creates;
        await fixture.collection.enableSchedule();
        expect((await fixture.collection.status()).schedule.enabled, isTrue);
        expect(fixture.creates, creates);
      },
    );
    test(
      'absent and current tasks are never automatically registered',
      () async {
        final fixture = AutostartFixture(root, installed: false);
        await fixture.collection.status();
        expect(fixture.creates, 0);
        expect(fixture.backups, isEmpty);
        final current = AutostartFixture(root);
        current.xml = WindowsTaskScheduler.buildTaskXml(
          current.request,
          userId: AutostartFixture.sid,
        );
        await current.collection.status();
        expect(current.creates, 0);
      },
    );
    test('backup failure prevents replacement and is reported', () async {
      final fixture = AutostartFixture(root);
      File('${root.path}/logs').writeAsStringSync('blocks directory');
      final status = await fixture.collection.status();
      expect(fixture.creates, 0);
      expect(status.schedule.outdated, isTrue);
      expect(
        status.autostartUpdate?.error,
        contains('backup could not be saved'),
      );
    });
    test(
      'registration failure keeps outdated status and supports explicit retry',
      () async {
        final fixture = AutostartFixture(root)
          ..createFailure = 'Access is denied.';
        final failed = await fixture.collection.status();
        expect(failed.schedule.outdated, isTrue);
        expect(failed.autostartUpdate?.error, contains('Access is denied.'));
        await fixture.collection.status();
        expect(fixture.creates, 1);
        fixture.createFailure = null;
        await fixture.collection.installSchedule();
        expect((await fixture.collection.status()).schedule.outdated, isFalse);
      },
    );
    test(
      'registration success without a changed task is a verification failure',
      () async {
        final fixture = AutostartFixture(root)..ignoreCreate = true;
        final status = await fixture.collection.status();
        expect(status.schedule.outdated, isTrue);
        expect(
          status.autostartUpdate?.detail,
          contains('could not be verified'),
        );
      },
    );
    for (final failRestore in [false, true]) {
      test(
        'verification failure restores the previous task; restore fails=$failRestore',
        () async {
          final fixture = AutostartFixture(root)
            ..disableReplacement = true
            ..failRestore = failRestore;
          final status = await fixture.collection.status();
          expect(fixture.creates, 2);
          expect(
            status.autostartUpdate?.error,
            contains(
              failRestore
                  ? 'previous setting could not be put back'
                  : 'previous setting was restored',
            ),
          );
          if (failRestore) {
            expect(
              status.autostartUpdate?.backupPath,
              fixture.backups.single.path,
            );
          } else {
            expect(
              XmlDocument.parse(fixture.xml!).rootElement.toXmlString(),
              XmlDocument.parse(fixture.original!).rootElement.toXmlString(),
            );
            expect(status.schedule.enabled, isTrue);
            expect(status.schedule.outdated, isTrue);
          }
        },
      );
    }

    String normalizedFixture(String name, AutostartFixture fixture) =>
        File(p.join('test', 'background_collection', 'fixtures', name))
            .readAsStringSync()
            .replaceAll('{{USER_SID}}', AutostartFixture.sid)
            .replaceAll('{{USER_ACCOUNT}}', r'FIXTURE\viewer')
            .replaceAll('{{USER_NAME}}', 'viewer')
            .replaceAll('{{LAUNCHER}}', fixture.request.launcherExecutable)
            .replaceAll('{{DATABASE}}', fixture.request.databaseFile)
            .replaceAll('{{SETTINGS}}', fixture.request.settingsFile);

    test(
      'normalized Windows export is current; old export is outdated',
      () async {
        final fixture = AutostartFixture(root);
        fixture.xml = normalizedFixture('task-final.xml', fixture);
        final current = await fixture.scheduler.query(
          expected: fixture.request,
        );
        expect(current.outdated, isFalse);
        expect(current.enabled, isTrue);
        fixture.xml = normalizedFixture('task-backup.xml', fixture);
        final old = await fixture.scheduler.query(expected: fixture.request);
        expect(old.outdated, isTrue);
        expect(old.enabled, isFalse);
      },
    );

    test(
      'normalized automatic upgrade verifies once without rollback',
      () async {
        final fixture = AutostartFixture(root);
        fixture.normalizeRegistration = (_) =>
            normalizedFixture('task-final.xml', fixture);
        final updated = await fixture.collection.status();
        expect(updated.schedule.outdated, isFalse);
        expect(updated.autostartUpdate?.error, isNull);
        expect(fixture.creates, 1);
        await fixture.collection.status();
        expect(fixture.creates, 1);
        expect(fixture.backups, hasLength(1));
      },
    );

    test(
      'normalized namespaces defaults dates booleans and Windows quoting',
      () async {
        final fixture = AutostartFixture(root);
        final good = normalizedFixture('task-final.xml', fixture);
        final doc = XmlDocument.parse(good);
        final task = doc.rootElement;
        final children = task.childElements.toList();
        task.children.clear();
        task.children.addAll(children.reversed);
        final reordered = doc.toXmlString();
        final explicit = good
            .replaceAll('<StartWhenAvailable>true', '<StartWhenAvailable>TRUE')
            .replaceAll('>false<', '>FALSE<')
            .replaceFirst(
              '<LogonTrigger>',
              '<LogonTrigger><Enabled>TRUE</Enabled><Delay>PT0S</Delay>',
            )
            .replaceFirst('<TimeTrigger>', '<TimeTrigger><Enabled>1</Enabled>')
            .replaceFirst(
              '<Interval>PT5M</Interval>',
              '<Interval>PT300S</Interval><Duration>PT0S</Duration><StopAtDurationEnd>FALSE</StopAtDurationEnd>',
            )
            .replaceFirst('<Settings>', '<Settings><Enabled>TRUE</Enabled>')
            .replaceFirst(
              '<LogonType>',
              '<RunLevel>LeastPrivilege</RunLevel><LogonType>',
            )
            .replaceFirst('2026-10-24T10:58:32', '2020-01-01T00:00:00.000Z');
        final prefixed = good
            .replaceAllMapped(
              RegExp(r'<(/?)([A-Z][A-Za-z]*)'),
              (m) => '<${m[1]}t:${m[2]}',
            )
            .replaceFirst('xmlns=', 'xmlns:t=');
        final alternateQuotes = good
            .replaceFirst('<Arguments>--db "', '<Arguments>"--db" "')
            .replaceFirst(' --settings "', '  "--settings"  "');
        for (final xml in [
          reordered,
          explicit,
          prefixed,
          alternateQuotes,
          good
              .replaceFirst('<Command>', '<Command>"')
              .replaceFirst('</Command>', '"</Command>'),
        ]) {
          fixture.xml = xml;
          expect(
            (await fixture.scheduler.query(expected: fixture.request)).outdated,
            isFalse,
            reason: xml,
          );
        }
        for (final xml in [
          good.replaceFirst('FIXTURE\\viewer', 'OTHER\\viewer'),
          good.replaceFirst(
            '<Interval>PT5M</Interval>',
            '<Interval>PT5M</Interval><Duration>PT1H</Duration>',
          ),
          good.replaceFirst(
            '<LogonTrigger>',
            '<LogonTrigger><Enabled>false</Enabled>',
          ),
          good.replaceFirst(
            '<TimeTrigger>',
            '<TimeTrigger><EndBoundary>2020-01-01T00:00:00Z</EndBoundary>',
          ),
          good.replaceFirst(
            '<Settings>',
            '<Settings><RunOnlyIfIdle>true</RunOnlyIfIdle>',
          ),
          good.replaceFirst(
            '<Actions Context="Author">',
            '<Actions Context="Other">',
          ),
          good.replaceFirst('</Arguments>', ' --extra</Arguments>'),
        ]) {
          fixture.xml = xml;
          expect(
            (await fixture.scheduler.query(expected: fixture.request)).outdated,
            isTrue,
            reason: xml,
          );
        }
      },
    );

    test('normalized missing task limit uses Windows PT72H default', () async {
      final fixture = AutostartFixture(root);
      fixture.xml = normalizedFixture(
        'task-final.xml',
        fixture,
      ).replaceFirst('<ExecutionTimeLimit>PT0S</ExecutionTimeLimit>', '');
      expect(
        (await fixture.scheduler.query(expected: fixture.request)).outdated,
        isTrue,
      );
    });

    test('normalized logon trigger must be active now', () async {
      final fixture = AutostartFixture(root);
      final good = normalizedFixture('task-final.xml', fixture);
      for (final boundary in [
        '<StartBoundary>2099-01-01T00:00:00Z</StartBoundary>',
        '<EndBoundary>2020-01-01T00:00:00Z</EndBoundary>',
        '<Enabled>false</Enabled>',
      ]) {
        fixture.xml = good.replaceFirst(
          '<LogonTrigger>',
          '<LogonTrigger>$boundary',
        );
        expect(
          (await fixture.scheduler.query(expected: fixture.request)).outdated,
          isTrue,
          reason: boundary,
        );
      }
      fixture.xml = good.replaceFirst(
        '<LogonTrigger>',
        '<LogonTrigger><StartBoundary>2020-01-01T00:00:00Z</StartBoundary>'
            '<EndBoundary>2099-01-01T00:00:00Z</EndBoundary>',
      );
      expect(
        (await fixture.scheduler.query(expected: fixture.request)).outdated,
        isFalse,
      );
    });

    test(
      'query detects settings, action, principal and trigger drift',
      () async {
        final fixture = AutostartFixture(root);
        final good = WindowsTaskScheduler.buildTaskXml(
          fixture.request,
          userId: AutostartFixture.sid,
        );
        for (final xml in [
          good.replaceFirst('PT0S', 'PT1H'),
          good
              .replaceFirst('<LogonTrigger>', '<BootTrigger>')
              .replaceFirst('</LogonTrigger>', '</BootTrigger>'),
          good.replaceFirst('PT5M', 'PT15M'),
          good.replaceFirst('IgnoreNew', 'Parallel'),
          good.replaceFirst('InteractiveToken', 'Password'),
          good.replaceFirst('launcher.exe', 'other.exe'),
          good.replaceFirst(
            '<StartWhenAvailable>true',
            '<StartWhenAvailable>false',
          ),
        ]) {
          fixture.xml = xml;
          expect(
            (await fixture.scheduler.query(expected: fixture.request)).outdated,
            isTrue,
          );
        }
      },
    );
  });

  group('ScheduledScanState', () {
    test('running and never-run results are not failures', () {
      expect(
        const ScheduledScanState(installed: true, lastResult: 0).lastRunFailed,
        isFalse,
      );
      expect(
        const ScheduledScanState(
          installed: true,
          lastResult: 267009,
        ).lastRunFailed,
        isFalse,
      );
      expect(
        const ScheduledScanState(installed: true, lastResult: 267009).running,
        isTrue,
      );
      expect(
        const ScheduledScanState(
          installed: true,
          lastResult: 267011,
        ).lastRunFailed,
        isFalse,
      );
      expect(
        const ScheduledScanState(installed: true, lastResult: 3).lastRunFailed,
        isTrue,
      );
      expect(
        const ScheduledScanState(
          installed: true,
          lastResult: 267014,
        ).lastRunFailed,
        isFalse,
      );
      expect(
        const ScheduledScanState(installed: true, lastResult: 267014).stopped,
        isTrue,
      );
      expect(const ScheduledScanState(installed: true).lastRunFailed, isFalse);
    });
  });

  group('WindowsTaskScheduler', () {
    const request = CollectorAutostartRequest(
      launcherExecutable:
          r'C:\Apps\Viewer & Co\codex-sessions-scan-launcher.exe',
      databaseFile: r'C:\Users\a\AppData\Roaming\db.sqlite',
      settingsFile: r'C:\Apps\settings.toml',
    );

    test('the definition is one windowless launcher run as the user', () {
      final xml = WindowsTaskScheduler.buildTaskXml(
        request,
        userId: 'S-1-5-21-123',
      );
      expect(xml, contains('<Interval>PT5M</Interval>'));
      expect(xml, contains('<LogonTrigger>'));
      expect(xml, contains('<ExecutionTimeLimit>PT0S</ExecutionTimeLimit>'));
      expect(xml, contains('<StopAtDurationEnd>false</StopAtDurationEnd>'));
      expect(xml, contains('<StartWhenAvailable>true</StartWhenAvailable>'));
      expect(
        xml,
        contains(
          '<DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>',
        ),
      );
      expect(
        xml,
        contains('<StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>'),
      );
      final evidence = Platform.environment['CXV_EVIDENCE_DIR'];
      if (evidence != null) {
        File('$evidence/background-collection-sample.xml').writeAsStringSync(
          xml.replaceFirst('encoding="UTF-16"', 'encoding="UTF-8"'),
        );
      }
      expect(xml, contains('<LogonType>InteractiveToken</LogonType>'));
      expect(xml, contains('<RunLevel>LeastPrivilege</RunLevel>'));
      expect(xml, contains('<MultipleInstancesPolicy>IgnoreNew<'));
      expect(
        xml,
        contains(
          r'<Command>C:\Apps\Viewer &amp; Co\codex-sessions-scan-launcher.exe</Command>',
        ),
      );
      expect(
        xml,
        contains(
          '<Arguments>--db "C:\\Users\\a\\AppData\\Roaming\\db.sqlite" '
          '--settings "C:\\Apps\\settings.toml"</Arguments>',
        ),
      );
      expect('<Exec>'.allMatches(xml), hasLength(1));
      expect(xml, isNot(contains('codex scan')));
    });

    test('refuses paths a task cannot carry', () {
      CollectorAutostartRequest with_({String? exe}) =>
          CollectorAutostartRequest(
            launcherExecutable: exe ?? request.launcherExecutable,
            databaseFile: request.databaseFile,
            settingsFile: request.settingsFile,
          );
      for (final bad in [with_(exe: 'a"b.exe'), with_(exe: 'a\nb.exe')]) {
        expect(
          () => WindowsTaskScheduler.buildTaskXml(bad, userId: 'S-1-5-21-123'),
          throwsA(isA<CollectorAutostartException>()),
        );
      }
    });

    test('parses intervals, csv rows and task info', () {
      expect(
        WindowsTaskScheduler.parseIntervalMinutes('<Interval>PT5M</Interval>'),
        5,
      );
      expect(
        WindowsTaskScheduler.parseIntervalMinutes('<Interval>PT2H</Interval>'),
        120,
      );
      expect(WindowsTaskScheduler.parseIntervalMinutes('<x/>'), isNull);
      expect(WindowsTaskScheduler.parseVerboseCsv('"a","b c","d"\r\n'), [
        'a',
        'b c',
        'd',
      ]);
      final info = WindowsTaskScheduler.parseTaskInfo(
        '2026-09-30T20:14:44.0000000+02:00|0\r\n',
      )!;
      expect(info.$1, DateTime.parse('2026-09-30T18:14:44Z').toLocal());
      expect(info.$2, 0);
      expect(WindowsTaskScheduler.parseTaskInfo('|267011'), (null, null));
      expect(
        WindowsTaskScheduler.parseTaskInfo('1999-11-30T00:00:00.0000000|0'),
        (null, null),
      );
      expect(WindowsTaskScheduler.parseTaskInfo('garbage'), isNull);
      expect(WindowsTaskScheduler.parseTaskInfo(''), isNull);
    });

    WindowsTaskScheduler scheduler({
      ProcessResult? xml,
      ProcessResult? list,
      ProcessResult? info,
      List<List<String>>? calls,
      ProcessResult? delete,
    }) => WindowsTaskScheduler(
      runProcess: (exe, args) async {
        calls?.add([exe, ...args]);
        if (exe == 'whoami.exe') return _ok('S-1-5-21-123');
        if (exe == 'powershell.exe') return info ?? _fail();
        if (args.contains('/XML')) return xml ?? _fail();
        if (args.first == '/Query') return list ?? _ok(_listWithTask);
        return delete ?? _ok();
      },
    );

    test('query reports absent only when the task list says so', () async {
      expect(
        (await scheduler(list: _ok(_listWithoutTask)).query()).installed,
        isFalse,
      );
      // The list cannot be read: never "absent".
      await expectLater(
        scheduler(list: _fail('Access is denied.')).query(),
        throwsA(
          isA<CollectorAutostartException>().having(
            (e) => e.message,
            'message',
            contains('Access is denied.'),
          ),
        ),
      );
      // Listed but unreadable definition: an error too.
      await expectLater(
        scheduler(xml: _fail('denied')).query(),
        throwsA(isA<CollectorAutostartException>()),
      );
    });

    test('a missing schtasks is a clear scheduler error', () async {
      final missing = WindowsTaskScheduler(
        runProcess: (exe, args) =>
            throw const ProcessException('schtasks', [], 'not found'),
      );
      await expectLater(
        missing.query(),
        throwsA(
          isA<CollectorAutostartException>().having(
            (e) => e.message,
            'message',
            contains('schtasks.exe'),
          ),
        ),
      );
    });

    test('query reads interval, last run and running state', () async {
      final state = await scheduler(
        xml: _ok('<Interval>PT5M</Interval>'),
        info: _ok('2026-09-30T18:14:44.0000000Z|0'),
      ).query();
      expect(state.installed, isTrue);
      expect(state.intervalMinutes, 5);
      expect(state.lastRun, DateTime.parse('2026-09-30T18:14:44Z').toLocal());
      expect(state.lastResult, 0);
      final running = await scheduler(
        xml: _ok('<Interval>PT5M</Interval>'),
        info: _ok('2026-09-30T18:14:44.0000000Z|267009'),
      ).query();
      expect(running.running, isTrue);
      expect(running.lastRunFailed, isFalse);
      // Task info that cannot be read leaves the run unknown, not an error.
      final unknown = await scheduler(
        xml: _ok('<Interval>PT5M</Interval>'),
      ).query();
      expect(unknown.installed, isTrue);
      expect(unknown.lastRun, isNull);
      expect(unknown.error, isNull);
    });

    test('install stages UTF-16 xml for /Create and cleans it up', () async {
      final temp = await Directory.systemTemp.createTemp('cxv-test-');
      addTearDown(() => temp.delete(recursive: true));
      List<String>? args;
      List<int>? staged;
      final scheduler = WindowsTaskScheduler(
        taskName: r'CxvTest\Unit',
        temporaryDirectory: temp,
        runProcess: (exe, arguments) async {
          if (exe == 'whoami.exe') return _ok('S-1-5-21-123');
          expect(exe, 'schtasks');
          args = arguments;
          staged = await File(
            arguments[arguments.indexOf('/XML') + 1],
          ).readAsBytes();
          return _ok();
        },
      );
      await scheduler.install(request);
      expect(args!.take(3), ['/Create', '/TN', r'CxvTest\Unit']);
      expect(args, contains('/F'));
      expect(staged!.take(2), [0xFF, 0xFE]);
      expect(temp.listSync(), isEmpty);
    });

    test(
      'install failure names the scheduler message, not the paths',
      () async {
        final failing = WindowsTaskScheduler(
          runProcess: (exe, arguments) async => exe == 'whoami.exe'
              ? _ok('S-1-5-21-123')
              : _fail('Access is denied.'),
        );
        await expectLater(
          failing.install(request),
          throwsA(
            isA<CollectorAutostartException>().having(
              (e) => e.message,
              'message',
              allOf(contains('Access is denied.'), isNot(contains('settings'))),
            ),
          ),
        );
      },
    );

    test('remove deletes the task, then its empty folder', () async {
      final calls = <List<String>>[];
      var listed = _listWithTask;
      final s = WindowsTaskScheduler(
        runProcess: (exe, args) async {
          calls.add([exe, ...args]);
          if (exe == 'whoami.exe') return _ok('S-1-5-21-123');
          if (exe == 'powershell.exe') return _ok('|267011');
          if (args.contains('/XML')) return _ok('<Interval>PT5M</Interval>');
          if (args.first == '/Query') return _ok(listed);
          if (args.contains(_taskName)) listed = _listWithoutTask;
          return _ok();
        },
      );
      await s.remove();
      final deletes = calls.where((c) => c.contains('/Delete')).toList();
      expect(deletes, hasLength(2));
      expect(deletes[0], contains(_taskName));
      expect(deletes[1], contains(r'\Codex Session Viewer'));
    });

    test('remove keeps a folder that still holds another task', () async {
      final calls = <List<String>>[];
      final s = WindowsTaskScheduler(
        runProcess: (exe, args) async {
          calls.add([exe, ...args]);
          if (exe == 'whoami.exe') return _ok('S-1-5-21-123');
          if (exe == 'powershell.exe') return _ok('|267011');
          if (args.contains('/XML')) return _ok('<Interval>PT5M</Interval>');
          if (args.first == '/Query') {
            return _ok(
              '$_listWithTask"\\Codex Session Viewer\\Other","x","Ready"\r\n',
            );
          }
          return _ok();
        },
      );
      await s.remove();
      expect(calls.where((c) => c.contains('/Delete')), hasLength(1));
    });

    test('remove is a no-op only when the task is absent', () async {
      final calls = <List<String>>[];
      await scheduler(list: _ok(_listWithoutTask), calls: calls).remove();
      expect(calls.where((c) => c.contains('/Delete')), isEmpty);
      await expectLater(
        scheduler(list: _fail('Access is denied.')).remove(),
        throwsA(isA<CollectorAutostartException>()),
      );
    });

    test('the factory picks the implementation in one place', () {
      expect(
        CollectorAutostart.forCurrentPlatform().isSupported,
        Platform.isWindows,
      );
    });
  });

  test('an unsupported platform says so and installs nothing', () async {
    const scheduler = UnsupportedCollectorAutostart();
    expect(scheduler.isSupported, isFalse);
    expect((await scheduler.query()).installed, isFalse);
    await scheduler.remove();
    await expectLater(
      scheduler.install(
        const CollectorAutostartRequest(
          launcherExecutable: 'c',
          databaseFile: 'd',
          settingsFile: 's',
        ),
      ),
      throwsA(
        isA<CollectorAutostartException>().having(
          (e) => e.message,
          'message',
          contains('not available'),
        ),
      ),
    );
  });

  group('CollectorBackgroundCollection', () {
    late _FakeScheduler scheduler;
    late List<List<String>> runs;
    late Map<String, ProcessResult> replies;
    var launcherPresent = true;

    setUp(() {
      scheduler = _FakeScheduler();
      runs = [];
      replies = {};
      launcherPresent = true;
    });

    CollectorBackgroundCollection build() => CollectorBackgroundCollection(
      collectorExecutable: r'C:\Apps\codex-sessions-collector.exe',
      databaseFile: r'C:\db.sqlite',
      settingsFile: r'C:\settings.toml',
      scheduler: scheduler,
      fileExists: (path) => launcherPresent,
      run: (exe, args, {environment}) async {
        expect(exe, r'C:\Apps\codex-sessions-collector.exe');
        runs.add(args);
        return replies[args.take(2).join(' ')] ?? _fail();
      },
    );

    ProcessResult status(
      String? state, {
      String? error,
      String? scan,
      String? collected,
      String? config,
    }) => ProcessResult(
      0,
      state == 'registered' ? 0 : 1,
      jsonEncode({
        'configuration': {
          'hook_state': state,
          'error': error,
          'config': config,
        },
        'database': {
          'last_scan_finished_utc': scan,
          'last_collection_utc': collected,
        },
      }),
      '',
    );

    void statuses(String codex, String claude) {
      replies['codex status'] = status(codex);
      replies['claude status'] = status(claude);
    }

    test(
      'status combines both hooks, the schedule and the newest times',
      () async {
        replies['codex status'] = status(
          'registered',
          scan: '2026-09-29T10:00:00Z',
          collected: '2026-09-29T09:00:00Z',
        );
        replies['claude status'] = status(
          'absent',
          scan: '2026-09-29T11:00:00Z',
          config: r'C:\Users\a\.claude\settings.json',
        );
        scheduler.state = const ScheduledScanState(
          installed: true,
          intervalMinutes: 5,
        );
        final result = await build().status();
        expect(
          result.hooks[CollectionHarness.codex]!.state,
          HookInstallState.installed,
        );
        expect(
          result.hooks[CollectionHarness.claude]!.state,
          HookInstallState.notInstalled,
        );
        expect(
          result.hooks[CollectionHarness.claude]!.configPath,
          r'C:\Users\a\.claude\settings.json',
        );
        expect(result.summary, BackgroundCollectionSummary.partial);
        expect(result.gaps, ['Claude Code hooks not installed']);
        expect(result.lastScanFinishedUtc, '2026-09-29T11:00:00Z');
        expect(result.lastCollectionUtc, '2026-09-29T09:00:00Z');
        expect(runs.first, [
          'codex',
          'status',
          '--json',
          '--db',
          r'C:\db.sqlite',
        ]);
      },
    );

    test('summary is off, on, partial (outdated) or attention', () async {
      statuses('absent', 'absent');
      expect((await build().status()).summary, BackgroundCollectionSummary.off);
      statuses('registered', 'registered');
      scheduler.state = const ScheduledScanState(installed: true);
      expect((await build().status()).summary, BackgroundCollectionSummary.on);
      replies['claude status'] = status('different_arguments');
      final outdated = await build().status();
      expect(outdated.summary, BackgroundCollectionSummary.partial);
      expect(outdated.gaps.single, contains('out of date'));
      replies['claude status'] = status(null, error: 'invalid Claude JSON');
      final broken = await build().status();
      expect(broken.summary, BackgroundCollectionSummary.attention);
      expect(
        broken.hooks[CollectionHarness.claude]!.detail,
        'invalid Claude JSON',
      );
    });

    test(
      'a failed last scheduled run needs attention and names itself',
      () async {
        statuses('registered', 'registered');
        scheduler.state = const ScheduledScanState(
          installed: true,
          intervalMinutes: 5,
          lastResult: 3,
        );
        final result = await build().status();
        expect(result.summary, BackgroundCollectionSummary.attention);
        expect(result.gaps.single, contains('last scheduled scan failed'));
        scheduler.state = const ScheduledScanState(
          installed: true,
          intervalMinutes: 5,
          lastResult: 267009,
        );
        expect(
          (await build().status()).summary,
          BackgroundCollectionSummary.on,
        );
      },
    );

    test('an unreadable scheduler keeps the hook rows', () async {
      statuses('registered', 'absent');
      scheduler.queryFailure = const CollectorAutostartException(
        'Windows Task Scheduler (schtasks.exe) could not be started.',
      );
      final result = await build().status();
      expect(result.hooks, hasLength(2));
      expect(
        result.hooks[CollectionHarness.codex]!.state,
        HookInstallState.installed,
      );
      expect(result.schedule.error, contains('schtasks.exe'));
      expect(result.summary, BackgroundCollectionSummary.attention);
      expect(result.gaps, contains('start at sign-in cannot be checked'));
    });

    test(
      'an unsupported scheduler does not stop the hooks reading as on',
      () async {
        scheduler = _FakeScheduler(supported: false);
        statuses('registered', 'registered');
        final result = await build().status();
        expect(result.scheduleSupported, isFalse);
        expect(result.summary, BackgroundCollectionSummary.on);
      },
    );

    test('install and remove call the collector setup with --apply', () async {
      replies['codex setup'] = ProcessResult(0, 0, '{"ok":true}', '');
      replies['claude setup'] = ProcessResult(
        0,
        0,
        '{"ok":true,"changed":true,"preserves_existing_hook":true}',
        '',
      );
      final collection = build();
      await collection.installHook(CollectionHarness.codex);
      expect(await collection.removeHook(CollectionHarness.claude), isTrue);
      expect(runs[0], [
        'codex',
        'setup',
        '--apply',
        '--json',
        '--db',
        r'C:\db.sqlite',
      ]);
      expect(runs[1], [
        'claude',
        'setup',
        '--remove',
        '--apply',
        '--json',
        '--db',
        r'C:\db.sqlite',
      ]);
    });

    test(
      'remove reports a restore only when the collector restored one',
      () async {
        replies['codex setup'] = ProcessResult(
          0,
          0,
          '{"ok":true,"changed":true,"preserves_existing_hook":false}',
          '',
        );
        expect(await build().removeHook(CollectionHarness.codex), isFalse);
        replies['codex setup'] = ProcessResult(
          0,
          0,
          '{"ok":true,"changed":false,"preserves_existing_hook":false}',
          '',
        );
        expect(await build().removeHook(CollectionHarness.codex), isFalse);
      },
    );

    test(
      'a refused setup surfaces the collector error and nothing else',
      () async {
        replies['codex setup'] = ProcessResult(
          0,
          1,
          '{"ok":false,"error":"invalid Codex TOML; repair configuration before setup"}',
          'api_key = private',
        );
        await expectLater(
          build().installHook(CollectionHarness.codex),
          throwsA(
            isA<BackgroundCollectionException>().having(
              (e) => e.message,
              'message',
              allOf(contains('invalid Codex TOML'), isNot(contains('private'))),
            ),
          ),
        );
        replies['claude setup'] = _fail('unparsable');
        await expectLater(
          build().removeHook(CollectionHarness.claude),
          throwsA(isA<BackgroundCollectionException>()),
        );
      },
    );

    test('a missing collector is reported as such', () async {
      final collection = CollectorBackgroundCollection(
        collectorExecutable: 'missing.exe',
        databaseFile: 'd',
        settingsFile: 's',
        scheduler: scheduler,
        run: (exe, args, {environment}) =>
            throw const ProcessException('missing.exe', [], 'not found'),
      );
      await expectLater(
        collection.status(),
        throwsA(
          isA<BackgroundCollectionException>().having(
            (e) => e.message,
            'message',
            contains('Session collection could not be started'),
          ),
        ),
      );
    });

    test(
      'the schedule runs the launcher next to the collector',
      () async {
        final collection = build();
        await collection.installSchedule();
        final request = scheduler.installed!;
        expect(
          request.launcherExecutable,
          r'C:\Apps\codex-sessions-scan-launcher.exe',
        );
        expect(request.databaseFile, r'C:\db.sqlite');
        expect(request.settingsFile, r'C:\settings.toml');
        expect(request.enabled, isTrue);
        scheduler.failure = const CollectorAutostartException('denied');
        await expectLater(
          collection.installSchedule(),
          throwsA(isA<BackgroundCollectionException>()),
        );
        await collection.removeSchedule();
        expect(scheduler.removed, 1);
      },
      skip: Platform.isWindows
          ? false
          : 'Only Windows Task Scheduler runs the scan launcher.',
    );

    test(
      'a missing launcher stops the schedule with a clear message',
      () async {
        launcherPresent = false;
        await expectLater(
          build().installSchedule(),
          throwsA(
            isA<BackgroundCollectionException>().having(
              (e) => e.message,
              'message',
              contains('component is missing'),
            ),
          ),
        );
        expect(scheduler.installed, isNull);
      },
    );
  });
}
