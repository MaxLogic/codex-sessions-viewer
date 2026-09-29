import 'dart:convert';
import 'dart:io';

import 'package:codex_sessions_viewer/src/background_collection/background_collection.dart';
import 'package:codex_sessions_viewer/src/background_collection/scan_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

ProcessResult _ok([String out = '']) => ProcessResult(0, 0, out, '');
ProcessResult _fail([String err = 'boom']) => ProcessResult(0, 1, '', err);

const _taskName = r'Codex Session Viewer\Background collection';
const _listWithTask =
    '"\\Adobe Task","01.10.2026 20:00:00","Ready"\r\n'
    '"\\Codex Session Viewer\\Background collection","01.10.2026 20:00:00","Ready"\r\n';
const _listWithoutTask = '"\\Adobe Task","01.10.2026 20:00:00","Ready"\r\n';

class _FakeScheduler implements ScanScheduler {
  _FakeScheduler({this.supported = true});

  final bool supported;
  ScheduledScanState state = const ScheduledScanState(installed: false);
  ScanScheduleRequest? installed;
  int removed = 0;
  ScanSchedulerException? failure;
  ScanSchedulerException? queryFailure;

  @override
  bool get isSupported => supported;

  @override
  Future<ScheduledScanState> query() async {
    if (queryFailure != null) throw queryFailure!;
    return state;
  }

  @override
  Future<void> install(ScanScheduleRequest request) async {
    if (failure != null) throw failure!;
    installed = request;
    state = ScheduledScanState(
      installed: true,
      intervalMinutes: request.intervalMinutes,
    );
  }

  @override
  Future<void> remove() async {
    removed++;
    state = const ScheduledScanState(installed: false);
  }
}

void main() {
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
    const request = ScanScheduleRequest(
      launcherExecutable:
          r'C:\Apps\Viewer & Co\codex-sessions-scan-launcher.exe',
      databaseFile: r'C:\Users\a\AppData\Roaming\db.sqlite',
      settingsFile: r'C:\Apps\settings.toml',
      intervalMinutes: 45,
    );

    test('the definition is one windowless launcher run as the user', () {
      final xml = WindowsTaskScheduler.buildTaskXml(request);
      expect(xml, contains('<Interval>PT45M</Interval>'));
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

    test('refuses paths and intervals a task cannot carry', () {
      ScanScheduleRequest with_({String? exe, int? minutes}) =>
          ScanScheduleRequest(
            launcherExecutable: exe ?? request.launcherExecutable,
            databaseFile: request.databaseFile,
            settingsFile: request.settingsFile,
            intervalMinutes: minutes ?? request.intervalMinutes,
          );
      for (final bad in [
        with_(exe: 'a"b.exe'),
        with_(minutes: 0),
        with_(minutes: 1441),
      ]) {
        expect(
          () => WindowsTaskScheduler.buildTaskXml(bad),
          throwsA(isA<ScanSchedulerException>()),
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
          isA<ScanSchedulerException>().having(
            (e) => e.message,
            'message',
            contains('Access is denied.'),
          ),
        ),
      );
      // Listed but unreadable definition: an error too.
      await expectLater(
        scheduler(xml: _fail('denied')).query(),
        throwsA(isA<ScanSchedulerException>()),
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
          isA<ScanSchedulerException>().having(
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
          runProcess: (exe, arguments) async => _fail('Access is denied.'),
        );
        await expectLater(
          failing.install(request),
          throwsA(
            isA<ScanSchedulerException>().having(
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
        throwsA(isA<ScanSchedulerException>()),
      );
    });

    test('the factory picks the implementation in one place', () {
      expect(
        ScanScheduler.forCurrentPlatform().isSupported,
        Platform.isWindows,
      );
    });
  });

  test('an unsupported platform says so and installs nothing', () async {
    const scheduler = UnsupportedScanScheduler();
    expect(scheduler.isSupported, isFalse);
    expect((await scheduler.query()).installed, isFalse);
    await scheduler.remove();
    await expectLater(
      scheduler.install(
        const ScanScheduleRequest(
          launcherExecutable: 'c',
          databaseFile: 'd',
          settingsFile: 's',
          intervalMinutes: 30,
        ),
      ),
      throwsA(
        isA<ScanSchedulerException>().having(
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
      scheduler.queryFailure = const ScanSchedulerException(
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
      expect(result.gaps, contains('the periodic scan cannot be checked'));
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
            contains('collector could not be started'),
          ),
        ),
      );
    });

    test('the schedule runs the launcher next to the collector', () async {
      final collection = build();
      await collection.installSchedule(15);
      final request = scheduler.installed!;
      expect(
        request.launcherExecutable,
        r'C:\Apps\codex-sessions-scan-launcher.exe',
      );
      expect(request.databaseFile, r'C:\db.sqlite');
      expect(request.settingsFile, r'C:\settings.toml');
      expect(request.intervalMinutes, 15);
      scheduler.failure = const ScanSchedulerException('denied');
      await expectLater(
        collection.installSchedule(30),
        throwsA(isA<BackgroundCollectionException>()),
      );
      await collection.removeSchedule();
      expect(scheduler.removed, 1);
    });

    test(
      'a missing launcher stops the schedule with a clear message',
      () async {
        launcherPresent = false;
        await expectLater(
          build().installSchedule(5),
          throwsA(
            isA<BackgroundCollectionException>().having(
              (e) => e.message,
              'message',
              contains('codex-sessions-scan-launcher.exe'),
            ),
          ),
        );
        expect(scheduler.installed, isNull);
      },
    );
  });
}
