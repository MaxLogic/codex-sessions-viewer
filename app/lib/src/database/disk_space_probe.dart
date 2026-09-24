import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

final class DiskVolumeSpace {
  const DiskVolumeSpace({
    required this.volumeKey,
    required this.availableBytes,
  });

  /// Lowercased stable identity of the volume, used to merge requirements.
  final String volumeKey;

  /// Free bytes available to the calling user (quota-aware).
  final int availableBytes;
}

/// Reports the volume that holds a directory and its free space.
///
/// A missing directory resolves to its nearest existing ancestor, so space can
/// be checked before a backup or temporary directory is created.
abstract interface class DiskSpaceProbe {
  factory DiskSpaceProbe.forCurrentPlatform() => Platform.isWindows
      ? const WindowsDiskSpaceProbe()
      : const _UnsupportedDiskSpaceProbe();

  DiskVolumeSpace probe(Directory directory);
}

final class _UnsupportedDiskSpaceProbe implements DiskSpaceProbe {
  const _UnsupportedDiskSpaceProbe();

  @override
  DiskVolumeSpace probe(Directory directory) => throw UnsupportedError(
    'Database migration disk probing requires Windows.',
  );
}

/// Direct Win32 probe; each call takes microseconds, unlike a PowerShell hop.
final class WindowsDiskSpaceProbe implements DiskSpaceProbe {
  const WindowsDiskSpaceProbe();

  @override
  DiskVolumeSpace probe(Directory directory) {
    if (!Platform.isWindows) {
      throw UnsupportedError(
        'Database migration disk probing requires Windows.',
      );
    }
    final existing = _nearestExistingDirectory(directory.path);
    final mountPoint = _volumeMountPoint(existing);
    final volumeKey = _volumeGuidPath(mountPoint) ?? mountPoint;
    return DiskVolumeSpace(
      volumeKey: volumeKey.toLowerCase(),
      availableBytes: _availableBytes(existing),
    );
  }
}

String _nearestExistingDirectory(String path) {
  var candidate = p.normalize(p.absolute(path));
  while (!Directory(candidate).existsSync()) {
    final parent = p.dirname(candidate);
    if (parent.isEmpty || parent == candidate) {
      throw StateError('Unable to determine migration disk headroom.');
    }
    candidate = parent;
  }
  return candidate;
}

String _volumeMountPoint(String path) => using((arena) {
  final capacity = math.max(path.length + 2, 261);
  final buffer = arena<Uint16>(capacity).cast<Utf16>();
  if (_getVolumePathName(
        path.toNativeUtf16(allocator: arena),
        buffer,
        capacity,
      ) ==
      0) {
    throw StateError('Unable to determine migration disk headroom.');
  }
  final mountPoint = buffer.toDartString();
  if (mountPoint.isEmpty) {
    throw StateError('Unable to determine migration disk headroom.');
  }
  return mountPoint;
});

/// Returns `\\?\Volume{GUID}\`, or null for volumes without one (for example
/// network shares), where the mount point is the best available identity.
String? _volumeGuidPath(String mountPoint) => using((arena) {
  const capacity = 64;
  final buffer = arena<Uint16>(capacity).cast<Utf16>();
  if (_getVolumeNameForVolumeMountPoint(
        mountPoint.toNativeUtf16(allocator: arena),
        buffer,
        capacity,
      ) ==
      0) {
    return null;
  }
  final name = buffer.toDartString();
  return name.isEmpty ? null : name;
});

int _availableBytes(String path) => using((arena) {
  final available = arena<Uint64>();
  if (_getDiskFreeSpaceEx(
        path.toNativeUtf16(allocator: arena),
        available,
        nullptr,
        nullptr,
      ) ==
      0) {
    throw StateError('Unable to determine migration disk headroom.');
  }
  final bytes = available.value;
  if (bytes < 0) {
    throw StateError('Disk headroom probe returned an invalid byte count.');
  }
  return bytes;
});

final _kernel32 = DynamicLibrary.open('kernel32.dll');

final _getVolumePathName = _kernel32
    .lookupFunction<
      Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32),
      int Function(Pointer<Utf16>, Pointer<Utf16>, int)
    >('GetVolumePathNameW');

final _getVolumeNameForVolumeMountPoint = _kernel32
    .lookupFunction<
      Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32),
      int Function(Pointer<Utf16>, Pointer<Utf16>, int)
    >('GetVolumeNameForVolumeMountPointW');

final _getDiskFreeSpaceEx = _kernel32
    .lookupFunction<
      Int32 Function(
        Pointer<Utf16>,
        Pointer<Uint64>,
        Pointer<Uint64>,
        Pointer<Uint64>,
      ),
      int Function(
        Pointer<Utf16>,
        Pointer<Uint64>,
        Pointer<Uint64>,
        Pointer<Uint64>,
      )
    >('GetDiskFreeSpaceExW');
