import 'package:codex_sessions_viewer/src/scanner/scan_batching.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'default batching yields before accumulating 32 MiB of parsed source',
    () {
      expect(
        defaultScanBatchingPolicy.shouldFlushParsedSessions(
          pendingCount: 1,
          pendingSourceBytes: 32 * 1024 * 1024 - 1,
        ),
        isFalse,
      );
      expect(
        defaultScanBatchingPolicy.shouldFlushParsedSessions(
          pendingCount: 1,
          pendingSourceBytes: 32 * 1024 * 1024,
        ),
        isTrue,
      );
    },
  );

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

  test('bounds pending parsed sessions at the persistence batch size', () {
    const policy = ScanBatchingPolicy(parsedSessionFlushBatchSize: 250);

    expect(
      policy.shouldFlushParsedSessions(
        pendingCount: 249,
        pendingSourceBytes: 1,
      ),
      isFalse,
    );
    expect(
      policy.shouldFlushParsedSessions(
        pendingCount: 250,
        pendingSourceBytes: 1,
      ),
      isTrue,
    );
    expect(
      policy.shouldFlushParsedSessions(
        pendingCount: 251,
        pendingSourceBytes: 1,
      ),
      isTrue,
    );
  });

  test('flushes unusually large parsed models by measured source weight', () {
    const policy = ScanBatchingPolicy(
      parsedSessionFlushBatchSize: 250,
      parsedSessionFlushSourceBytes: 512 * 1024 * 1024,
    );

    expect(
      policy.shouldFlushParsedSessions(
        pendingCount: 1,
        pendingSourceBytes: 512 * 1024 * 1024 - 1,
      ),
      isFalse,
    );
    expect(
      policy.shouldFlushParsedSessions(
        pendingCount: 1,
        pendingSourceBytes: 512 * 1024 * 1024,
      ),
      isTrue,
    );
  });
}
