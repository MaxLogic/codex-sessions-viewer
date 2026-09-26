import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

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
  factory DiskSpaceProbe.forCurrentPlatform() {
    if (Platform.isWindows) return const WindowsDiskSpaceProbe();
    final layout = StatvfsLayout.forCurrentPlatform();
    return layout == null
        ? const _UnsupportedDiskSpaceProbe()
        : PosixDiskSpaceProbe(layout);
  }

  DiskVolumeSpace probe(Directory directory);
}

final class _UnsupportedDiskSpaceProbe implements DiskSpaceProbe {
  const _UnsupportedDiskSpaceProbe();

  @override
  DiskVolumeSpace probe(Directory directory) => throw UnsupportedError(
    'Database migration disk probing is not supported on this platform.',
  );
}

/// Where the fields this probe reads sit in the C library's
/// `struct statvfs`, which differs between operating systems.
final class StatvfsLayout {
  const StatvfsLayout._({
    required this.name,
    required this.fragmentSizeOffset,
    required this.availableBlocksOffset,
    required this.availableBlocksBytes,
    required this.filesystemIdOffset,
  });

  /// glibc and musl on 64-bit Linux: every field is 64 bits wide.
  static const linux64 = StatvfsLayout._(
    name: 'linux64',
    fragmentSizeOffset: 8,
    availableBlocksOffset: 32,
    availableBlocksBytes: 8,
    filesystemIdOffset: 64,
  );

  /// 64-bit macOS: block and file counts are 32 bits wide; libc raises the
  /// fragment size so large volumes still fit.
  static const darwin64 = StatvfsLayout._(
    name: 'darwin64',
    fragmentSizeOffset: 8,
    availableBlocksOffset: 24,
    availableBlocksBytes: 4,
    filesystemIdOffset: 40,
  );

  /// Room for the structure on every supported system (glibc uses 112).
  static const bufferBytes = 256;

  /// The layout for this process, or null where none is known (Windows,
  /// 32-bit systems, other operating systems).
  static StatvfsLayout? forCurrentPlatform() {
    if (sizeOf<IntPtr>() != 8) return null;
    if (Platform.isLinux) return linux64;
    if (Platform.isMacOS) return darwin64;
    return null;
  }

  final String name;
  final int fragmentSizeOffset;
  final int availableBlocksOffset;
  final int availableBlocksBytes;
  final int filesystemIdOffset;

  /// Reads a filled `struct statvfs` in host (little-endian) byte order.
  DiskVolumeSpace decode(ByteData statvfs) {
    final fragmentSize = statvfs.getUint64(fragmentSizeOffset, Endian.host);
    final availableBlocks = availableBlocksBytes == 8
        ? statvfs.getUint64(availableBlocksOffset, Endian.host)
        : statvfs.getUint32(availableBlocksOffset, Endian.host);
    final filesystemId = statvfs.getUint64(filesystemIdOffset, Endian.host);
    final bytes = fragmentSize * availableBlocks;
    if (fragmentSize <= 0 ||
        availableBlocks < 0 ||
        bytes < 0 ||
        (availableBlocks != 0 && bytes ~/ availableBlocks != fragmentSize)) {
      throw StateError('Disk headroom probe returned an invalid byte count.');
    }
    return DiskVolumeSpace(
      volumeKey:
          'fsid:${BigInt.from(filesystemId).toUnsigned(64).toRadixString(16)}',
      availableBytes: bytes,
    );
  }
}

/// `statvfs(3)` through the C library on Linux and macOS: free bytes for an
/// unprivileged user (`f_bavail * f_frsize`) and the file-system id as the
/// volume identity.
final class PosixDiskSpaceProbe implements DiskSpaceProbe {
  const PosixDiskSpaceProbe(this.layout);

  final StatvfsLayout layout;

  @override
  DiskVolumeSpace probe(Directory directory) {
    final existing = _nearestExistingDirectory(directory.path);
    return using((arena) {
      final buffer = arena<Uint8>(StatvfsLayout.bufferBytes);
      if (_statvfs(existing.toNativeUtf8(allocator: arena), buffer) != 0) {
        throw StateError('Unable to determine migration disk headroom.');
      }
      final bytes = Uint8List.fromList(
        buffer.asTypedList(StatvfsLayout.bufferBytes),
      );
      return layout.decode(ByteData.sublistView(bytes));
    });
  }
}

final _statvfs = DynamicLibrary.process()
    .lookupFunction<
      Int32 Function(Pointer<Utf8>, Pointer<Uint8>),
      int Function(Pointer<Utf8>, Pointer<Uint8>)
    >('statvfs');

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
