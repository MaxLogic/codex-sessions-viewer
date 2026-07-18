import 'dart:io';

import 'package:codex_sessions_viewer/src/platform/app_instance_lock.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('allows only one process lock for the same app data directory', () {
    final tempDir = Directory.systemTemp.createTempSync(
      'codex-viewer-instance-lock-',
    );
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final lockFile = File('${tempDir.path}${Platform.pathSeparator}app.lock');
    final first = AppInstanceLock(lockFile);
    final second = AppInstanceLock(lockFile);
    addTearDown(first.release);
    addTearDown(second.release);

    expect(first.tryAcquire(), isTrue);
    expect(second.tryAcquire(), isFalse);

    first.release();
    expect(second.tryAcquire(), isTrue);
  });
}
