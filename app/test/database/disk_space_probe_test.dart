import 'package:codex_sessions_viewer/src/platform/app_environment.dart';
import 'dart:io';
import 'dart:typed_data';

import 'package:codex_sessions_viewer/src/database/disk_space_probe.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  final probe = DiskSpaceProbe.forCurrentPlatform();

  test('each desktop platform gets its own probe', () {
    expect(
      probe,
      Platform.isWindows
          ? isA<WindowsDiskSpaceProbe>()
          : isA<PosixDiskSpaceProbe>(),
    );
    if (Platform.isLinux) {
      expect((probe as PosixDiskSpaceProbe).layout, StatvfsLayout.linux64);
    }
    if (Platform.isMacOS) {
      expect((probe as PosixDiskSpaceProbe).layout, StatvfsLayout.darwin64);
    }
  });

  group('statvfs layouts', () {
    ByteData statvfs(Map<int, (int, int)> fields) {
      final data = ByteData(StatvfsLayout.bufferBytes);
      for (final MapEntry(key: offset, value: (bytes, value))
          in fields.entries) {
        if (bytes == 8) {
          data.setUint64(offset, value, Endian.host);
        } else {
          data.setUint32(offset, value, Endian.host);
        }
      }
      return data;
    }

    test('Linux reads 64-bit counts and the file-system id', () {
      final space = StatvfsLayout.linux64.decode(
        statvfs({
          0: (8, 4096), // f_bsize
          8: (8, 4096), // f_frsize
          32: (8, 5000000000), // f_bavail, beyond 32 bits
          24: (8, 7), // f_bfree must not be used
          64: (8, 0xfd01), // f_fsid
        }),
      );
      expect(space.availableBytes, 4096 * 5000000000);
      expect(space.volumeKey, 'fsid:fd01');
    });

    test('macOS reads 32-bit counts after the 64-bit sizes', () {
      final space = StatvfsLayout.darwin64.decode(
        statvfs({
          8: (8, 1 << 20), // f_frsize, raised by libc for a large volume
          24: (4, 3000000), // f_bavail
          20: (4, 9), // f_bfree must not be used
          40: (8, 0x1000012), // f_fsid
        }),
      );
      expect(space.availableBytes, (1 << 20) * 3000000);
      expect(space.volumeKey, 'fsid:1000012');
    });

    test('a file-system id with the top bit set stays unsigned', () {
      final data = ByteData(StatvfsLayout.bufferBytes)
        ..setUint64(8, 512, Endian.host)
        ..setUint64(32, 1, Endian.host)
        ..setUint32(64, 0xffffffff, Endian.host)
        ..setUint32(68, 0xffffffff, Endian.host);
      expect(
        StatvfsLayout.linux64.decode(data).volumeKey,
        'fsid:ffffffffffffffff',
      );
    });

    test('nonsense sizes are refused rather than reported', () {
      expect(
        () => StatvfsLayout.linux64.decode(statvfs({32: (8, 10)})),
        throwsStateError,
      );
      expect(
        () => StatvfsLayout.linux64.decode(
          statvfs({8: (8, 1 << 40), 32: (8, 1 << 40)}),
        ),
        throwsStateError,
      );
    });
  });

  test('reports free bytes and one stable volume for the home folder and '
      'a missing nested folder', () async {
    final home =
        AppEnvironment.current['USERPROFILE'] ?? AppEnvironment.current['HOME'];
    expect(home, isNotNull);
    final existing = probe.probe(Directory(home!));
    expect(existing.availableBytes, greaterThan(0));
    expect(existing.volumeKey, isNotEmpty);
    expect(probe.probe(Directory(home)).volumeKey, existing.volumeKey);

    final absent = p.join(
      home,
      'csv-disk-probe-${DateTime.now().microsecondsSinceEpoch}',
    );
    final missing = probe.probe(Directory(p.join(absent, 'created', 'later')));
    expect(missing.volumeKey, existing.volumeKey);
    expect(missing.availableBytes, greaterThan(0));
    expect(Directory(absent).existsSync(), isFalse);
  });

  test('reports a volume GUID for the system drive', () {
    final systemDrive = Platform.environment['SystemDrive'] ?? 'C:';
    final space = probe.probe(Directory('$systemDrive\\'));
    expect(space.volumeKey, startsWith(r'\\?\volume{'));
    expect(space.volumeKey, space.volumeKey.toLowerCase());
    expect(space.availableBytes, greaterThan(0));
  }, testOn: 'windows');

  test('probing is fast enough to repeat at every phase boundary', () {
    final stopwatch = Stopwatch()..start();
    for (var i = 0; i < 30; i++) {
      probe.probe(Directory.systemTemp);
    }
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
  });
}
