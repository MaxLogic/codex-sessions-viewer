const defaultScanBatchingPolicy = ScanBatchingPolicy();

class ScanBatchingPolicy {
  const ScanBatchingPolicy({
    this.parsedSessionFlushBatchSize = 250,
    this.parsedSessionFlushSourceBytes = 512 * 1024 * 1024,
    this.fullRowSnapshotBatchSize = 500,
  }) : assert(parsedSessionFlushBatchSize > 0),
       assert(parsedSessionFlushSourceBytes > 0),
       assert(fullRowSnapshotBatchSize > 0);

  final int parsedSessionFlushBatchSize;
  final int parsedSessionFlushSourceBytes;
  final int fullRowSnapshotBatchSize;

  int estimatedPersistenceFlushCount(int parsedCount) {
    return _ceilDiv(parsedCount, parsedSessionFlushBatchSize);
  }

  int estimatedFullRowSnapshotCount(int parsedCount) {
    return _ceilDiv(parsedCount, fullRowSnapshotBatchSize);
  }

  bool shouldFlushParsedSessions({
    required int pendingCount,
    required int pendingSourceBytes,
  }) =>
      pendingCount >= parsedSessionFlushBatchSize ||
      pendingSourceBytes >= parsedSessionFlushSourceBytes;

  bool shouldEmitFullRowSnapshot({
    required int parsedCount,
    required int lastSnapshotParsedCount,
    bool force = false,
  }) {
    if (parsedCount <= lastSnapshotParsedCount) {
      return false;
    }
    return force ||
        parsedCount - lastSnapshotParsedCount >= fullRowSnapshotBatchSize;
  }
}

int _ceilDiv(int value, int divisor) {
  if (value <= 0) {
    return 0;
  }
  return (value + divisor - 1) ~/ divisor;
}
