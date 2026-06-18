import 'package:codex_sessions_viewer/src/scanner/scan_batching.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('default scan batching is sized for large session sets', () {
    expect(
      defaultScanBatchingPolicy.parsedSessionFlushBatchSize,
      greaterThanOrEqualTo(250),
    );
    expect(
      defaultScanBatchingPolicy.fullRowSnapshotBatchSize,
      greaterThan(defaultScanBatchingPolicy.parsedSessionFlushBatchSize),
    );
  });

  test('estimates persistence flushes and full row snapshots', () {
    const policy = ScanBatchingPolicy(
      parsedSessionFlushBatchSize: 250,
      fullRowSnapshotBatchSize: 500,
    );

    expect(policy.estimatedPersistenceFlushCount(0), 0);
    expect(policy.estimatedPersistenceFlushCount(1), 1);
    expect(policy.estimatedPersistenceFlushCount(500), 2);
    expect(policy.estimatedPersistenceFlushCount(501), 3);

    expect(policy.estimatedFullRowSnapshotCount(0), 0);
    expect(policy.estimatedFullRowSnapshotCount(1), 1);
    expect(policy.estimatedFullRowSnapshotCount(500), 1);
    expect(policy.estimatedFullRowSnapshotCount(501), 2);
  });
}
