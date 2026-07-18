import 'dart:io';

class AppInstanceLock {
  AppInstanceLock(this.file);

  final File file;
  RandomAccessFile? _handle;

  bool tryAcquire() {
    if (_handle != null) {
      return true;
    }
    file.parent.createSync(recursive: true);
    final handle = file.openSync(mode: FileMode.append);
    try {
      handle.lockSync(FileLock.exclusive);
      _handle = handle;
      return true;
    } on FileSystemException {
      handle.closeSync();
      return false;
    }
  }

  void release() {
    final handle = _handle;
    if (handle == null) {
      return;
    }
    _handle = null;
    try {
      handle.unlockSync();
    } finally {
      handle.closeSync();
    }
  }
}
