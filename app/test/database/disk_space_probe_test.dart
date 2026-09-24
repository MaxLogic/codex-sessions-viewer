@TestOn('windows')
library;

import 'dart:io';

import 'package:codex_sessions_viewer/src/database/disk_space_probe.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  const probe = WindowsDiskSpaceProbe();

  test('platform probe on Windows is the Win32 probe', () {
    expect(DiskSpaceProbe.forCurrentPlatform(), isA<WindowsDiskSpaceProbe>());
  });

  test('reports a volume GUID and free bytes for the system drive', () {
    final systemDrive = Platform.environment['SystemDrive'] ?? 'C:';
    final space = probe.probe(Directory('$systemDrive\\'));
    expect(space.volumeKey, startsWith(r'\\?\volume{'));
    expect(space.volumeKey, space.volumeKey.toLowerCase());
    expect(space.availableBytes, greaterThan(0));
  });

  test(
    'a missing directory resolves to its nearest existing ancestor',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'csv_disk_probe_',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final existing = probe.probe(temporary);
      final missing = probe.probe(
        Directory(p.join(temporary.path, 'not', 'created', 'yet')),
      );
      expect(missing.volumeKey, isNotEmpty);
      expect(missing.volumeKey, existing.volumeKey);
      expect(missing.availableBytes, greaterThan(0));
      expect(Directory(p.join(temporary.path, 'not')).existsSync(), isFalse);
    },
  );

  test('probing is fast enough to repeat at every phase boundary', () {
    final stopwatch = Stopwatch()..start();
    for (var i = 0; i < 30; i++) {
      probe.probe(Directory.systemTemp);
    }
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
  });
}
