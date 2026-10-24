import 'test_environment.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:codex_sessions_viewer/src/scanner/collector_process.dart';
import 'package:path/path.dart' as p;

/// Stop only residents attached to databases in this test's allocated root.
/// Dispose clients/widgets and close database handles before calling this.
/// Production viewer residents intentionally survive disconnect for 30 seconds;
/// tests explicitly stop their own residents instead of changing that contract.
/// Shared by unit, widget and integration fixtures. No deletion retries: leaked
/// processes/handles fail teardown before any fixture evidence is removed.
Future<void> deleteCollectorFixture(Directory root) async {
  final path = p.normalize(root.absolute.path);
  if (!p.isWithin(Directory.systemTemp.absolute.path, path)) {
    throw StateError(
      'Collector fixture is outside the allocated temp parent: $path',
    );
  }
  if (!await root.exists()) return;
  if (!p.equals(path, p.normalize(await root.resolveSymbolicLinks()))) {
    throw StateError('Unexpected fixture root link: $path');
  }
  var files = await root.list(recursive: true, followLinks: false).toList();
  if (files.any((file) => file is Link)) {
    throw StateError('Unexpected fixture link.');
  }
  // Widget disposal joins asynchronously. Give already-disposing bridges a
  // bounded opportunity to exit, but report an undisposed one as a test leak.
  final processes = await _fixtureProcesses(path);
  await _waitForExit(processes.where((process) => !process.resident));
  for (final file in files.whereType<File>()) {
    const suffix = '.collector.lock';
    if (file.path.endsWith(suffix)) {
      final result = await _run(CollectorProcess.defaultExecutable(), [
        'resident',
        'stop',
        '--db',
        file.path.substring(0, file.path.length - suffix.length),
      ]);
      if (result.exitCode != 0) {
        throw StateError('Fixture resident stop failed: ${result.stderr}');
      }
    }
  }
  // The instance lock proves shutdown; the process exit guard also catches a
  // late destructor/bridge/replacement worker holding a fixture file open.
  await _waitForExit(processes.where((process) => process.resident));
  final remaining = await _fixtureProcesses(path);
  if (remaining.isNotEmpty) {
    throw StateError('Collector fixture leaked processes: $remaining');
  }
  files = await root.list(recursive: true, followLinks: false).toList();
  if (files.any((file) => file is Link)) {
    throw StateError('Unexpected fixture link.');
  }
  if (Platform.isWindows) {
    final checked = await _run(
      r'C:\Program Files\PowerShell\7\pwsh.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-File',
        p.absolute('test/support/fixture_process_0.ps1'),
      ],
      environment: {'CSV_TEST_FIXTURE_ROOT': path},
    );
    if (checked.exitCode != 0) {
      throw StateError(
        'Collector fixture has an open or inaccessible file: ${checked.stderr}',
      );
    }
  }
  await root.delete(recursive: true);
  if (await root.exists()) {
    throw StateError('Collector fixture survived deletion: $path');
  }
}

Future<ProcessResult> _run(
  String executable,
  List<String> arguments, {
  Map<String, String>? environment,
}) async {
  final process = await startTestProcess(
    executable,
    arguments,
    environment: environment,
  );
  final output = process.stdout.transform(utf8.decoder).join();
  final errors = process.stderr.transform(utf8.decoder).join();
  try {
    return await (() async {
      await process.stdin.close();
      final code = await process.exitCode;
      return ProcessResult(process.pid, code, await output, await errors);
    })().timeout(const Duration(seconds: 15));
  } on TimeoutException {
    process.kill();
    await process.exitCode.timeout(const Duration(seconds: 3));
    throw StateError('Fixture command timed out: $executable $arguments');
  }
}

typedef _FixtureProcess = ({int pid, bool resident});

Future<List<_FixtureProcess>> _fixtureProcesses(String root) async {
  final result = Platform.isWindows
      ? await _run(
          r'C:\Program Files\PowerShell\7\pwsh.exe',
          [
            '-NoProfile',
            '-NonInteractive',
            '-File',
            p.absolute('test/support/fixture_process_1.ps1'),
          ],
          environment: {'CSV_TEST_FIXTURE_ROOT': root},
        )
      : await _run('ps', ['-eo', 'pid=,args=']);
  if (result.exitCode != 0) {
    throw StateError('Fixture process guard failed: ${result.stderr}');
  }
  if (Platform.isWindows) {
    if ((result.stdout as String).trim().isEmpty) return [];
    final decoded = jsonDecode(result.stdout as String);
    final rows = decoded is List ? decoded : [decoded];
    return [
      for (final row in rows)
        (pid: row['pid'] as int, resident: row['resident'] as bool),
    ];
  }
  return [
    for (final line in (result.stdout as String).split('\n'))
      if (line.contains('$root/'))
        (
          pid: int.parse(line.trim().split(RegExp(r'\s+')).first),
          resident: RegExp(r'\sserve(?:-replacement)?\s').hasMatch(line),
        ),
  ];
}

Future<void> _waitForExit(Iterable<_FixtureProcess> processes) async {
  final pids = processes.map((process) => process.pid).toList();
  if (pids.isEmpty) return;
  if (Platform.isWindows) {
    final result = await _run(
      r'C:\Program Files\PowerShell\7\pwsh.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-File',
        p.absolute('test/support/fixture_process_2.ps1'),
      ],
      environment: {'CSV_TEST_FIXTURE_PIDS': pids.join(',')},
    );
    if (result.exitCode != 0) {
      throw StateError('Collector fixture leaked processes: ${result.stderr}');
    }
    return;
  }
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  for (final pid in pids) {
    while ((await _run('ps', ['-p', '$pid', '-o', 'pid='])).exitCode == 0) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError(
          'Collector fixture leaked process $pid; dispose its client before teardown.',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }
}
