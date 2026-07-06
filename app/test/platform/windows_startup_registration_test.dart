import 'dart:io';

import 'package:codex_sessions_viewer/src/platform/windows_startup_registration.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'enabling startup writes the current executable to the Run key',
    () async {
      final calls = <_ProcessCall>[];
      final registration = WindowsStartupRegistration(
        executablePath:
            r'C:\Program Files\Codex Session Viewer\codex_session_viewer.exe',
        isWindows: true,
        runProcess: (executable, arguments) async {
          calls.add(_ProcessCall(executable, arguments));
          return ProcessResult(1, 0, '', '');
        },
      );

      await registration.apply(enabled: true);

      expect(calls, [
        _ProcessCall('reg', [
          'add',
          WindowsStartupRegistration.runKey,
          '/v',
          WindowsStartupRegistration.runValueName,
          '/t',
          'REG_SZ',
          '/d',
          r'"C:\Program Files\Codex Session Viewer\codex_session_viewer.exe"',
          '/f',
        ]),
      ]);
    },
  );

  test('disabling startup removes the Run key value when it exists', () async {
    final calls = <_ProcessCall>[];
    final registration = WindowsStartupRegistration(
      isWindows: true,
      runProcess: (executable, arguments) async {
        calls.add(_ProcessCall(executable, arguments));
        return ProcessResult(1, 0, '', '');
      },
    );

    await registration.apply(enabled: false);

    expect(calls, [
      _ProcessCall('reg', [
        'query',
        WindowsStartupRegistration.runKey,
        '/v',
        WindowsStartupRegistration.runValueName,
      ]),
      _ProcessCall('reg', [
        'delete',
        WindowsStartupRegistration.runKey,
        '/v',
        WindowsStartupRegistration.runValueName,
        '/f',
      ]),
    ]);
  });

  test('disabling startup ignores an already missing Run key value', () async {
    final calls = <_ProcessCall>[];
    final registration = WindowsStartupRegistration(
      isWindows: true,
      runProcess: (executable, arguments) async {
        calls.add(_ProcessCall(executable, arguments));
        return ProcessResult(1, calls.length == 1 ? 1 : 0, '', '');
      },
    );

    await registration.apply(enabled: false);

    expect(calls, [
      _ProcessCall('reg', [
        'query',
        WindowsStartupRegistration.runKey,
        '/v',
        WindowsStartupRegistration.runValueName,
      ]),
    ]);
  });

  test('startup registration is a no-op outside Windows', () async {
    final calls = <_ProcessCall>[];
    final registration = WindowsStartupRegistration(
      isWindows: false,
      runProcess: (executable, arguments) async {
        calls.add(_ProcessCall(executable, arguments));
        return ProcessResult(1, 0, '', '');
      },
    );

    await registration.apply(enabled: true);
    await registration.apply(enabled: false);

    expect(calls, isEmpty);
  });
}

class _ProcessCall {
  const _ProcessCall(this.executable, this.arguments);

  final String executable;
  final List<String> arguments;

  @override
  bool operator ==(Object other) =>
      other is _ProcessCall &&
      executable == other.executable &&
      _listEquals(arguments, other.arguments);

  @override
  int get hashCode => Object.hash(executable, Object.hashAll(arguments));

  @override
  String toString() => '$executable ${arguments.join(' ')}';
}

bool _listEquals(List<String> left, List<String> right) {
  if (left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) {
      return false;
    }
  }
  return true;
}
