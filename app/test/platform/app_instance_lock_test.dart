import 'dart:io';

import 'package:codex_sessions_viewer/src/platform/app_instance_lock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/test_environment.dart';

void main() {
  test('allows only one process lock for the same app data directory', () async {
    final tempDir = Directory.systemTemp.createTempSync(
      'codex-viewer-instance-lock-',
    );
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final lockFile = File('${tempDir.path}${Platform.pathSeparator}app.lock');
    final probe = File(p.join(tempDir.path, 'lock_probe.dart'))
      ..writeAsStringSync(
        "import 'dart:io';\n"
        "import 'package:codex_sessions_viewer/src/platform/app_instance_lock.dart';\n"
        'void main(List<String> args) => '
        'stdout.write(AppInstanceLock(File(args.single)).tryAcquire());\n',
      );
    final dart = p.join(
      Platform.environment['FLUTTER_ROOT']!,
      'bin',
      'cache',
      'dart-sdk',
      'bin',
      Platform.isWindows ? 'dart.exe' : 'dart',
    );
    Future<String> acquireInAnotherProcess() async {
      final result = await runTestProcess(dart, [
        '--packages=${p.absolute('.dart_tool', 'package_config.json')}',
        probe.path,
        lockFile.path,
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      return (result.stdout as String).trim();
    }

    final first = AppInstanceLock(lockFile);
    final second = AppInstanceLock(lockFile);
    addTearDown(first.release);
    addTearDown(second.release);

    expect(first.tryAcquire(), isTrue);
    // POSIX record locks belong to the process, so only Windows refuses a
    // second handle in the same process.
    if (Platform.isWindows) expect(second.tryAcquire(), isFalse);
    expect(await acquireInAnotherProcess(), 'false');

    first.release();
    expect(await acquireInAnotherProcess(), 'true');
    if (Platform.isWindows) expect(second.tryAcquire(), isTrue);
  });
}
