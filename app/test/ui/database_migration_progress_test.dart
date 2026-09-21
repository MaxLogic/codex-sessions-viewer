import 'package:codex_sessions_viewer/src/database/database_maintenance.dart';
import 'package:codex_sessions_viewer/src/ui/widgets/database_migration_progress.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows determinate progress and operational details', (
    tester,
  ) async {
    final progress = ValueNotifier<DatabaseMaintenanceProgress?>(
      _progress(completed: 25, total: 100),
    );
    addTearDown(progress.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: DatabaseMigrationProgressHost(
          progress: progress,
          onStop: () async {},
          onResume: () async {},
          onRetry: () async {},
          child: const Text('Normal application'),
        ),
      ),
    );

    final indicator = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(indicator.value, 0.25);
    expect(indicator.semanticsValue, '25%');
    expect(find.text('25 of 100 events'), findsOneWidget);
    expect(find.text('50.0 events/s'), findsOneWidget);
    expect(find.text('Elapsed 00:05'), findsOneWidget);
    expect(find.text('ETA 00:15'), findsOneWidget);
    expect(find.text('WAL 2.0 MB'), findsOneWidget);
    expect(find.text('Normal application'), findsNothing);
  });

  testWidgets('shows indeterminate progress for an atomic phase', (
    tester,
  ) async {
    final progress = ValueNotifier<DatabaseMaintenanceProgress?>(
      _progress(
        phase: 'Building indexes',
        currentWork: 'Creating index 2 of 4',
        completed: 0,
        total: null,
        ratePerSecond: null,
        estimatedRemaining: null,
      ),
    );
    addTearDown(progress.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: DatabaseMigrationProgressHost(
          progress: progress,
          onStop: () async {},
          onResume: () async {},
          onRetry: () async {},
          child: const SizedBox(),
        ),
      ),
    );

    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      isNull,
    );
    expect(find.text('Building indexes'), findsOneWidget);
    expect(find.text('Creating index 2 of 4'), findsOneWidget);
  });

  testWidgets('hides and reopens without losing the latest progress', (
    tester,
  ) async {
    final progress = ValueNotifier<DatabaseMaintenanceProgress?>(_progress());
    addTearDown(progress.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: DatabaseMigrationProgressHost(
          progress: progress,
          onStop: () async {},
          onResume: () async {},
          onRetry: () async {},
          child: const Text('Normal application'),
        ),
      ),
    );

    await tester.tap(find.widgetWithText(TextButton, 'Hide'));
    await tester.pump();
    expect(
      find.text('Database maintenance continues in the background.'),
      findsOneWidget,
    );
    expect(find.text('Normal application'), findsNothing);

    progress.value = _progress(completed: 60, total: 100);
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Show progress'));
    await tester.pump();
    expect(find.text('60 of 100 events'), findsOneWidget);
  });

  testWidgets('stop is requested once at a safe boundary', (tester) async {
    final progress = ValueNotifier<DatabaseMaintenanceProgress?>(_progress());
    addTearDown(progress.dispose);
    var stopCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: DatabaseMigrationProgressHost(
          progress: progress,
          onStop: () async {
            stopCalls++;
          },
          onResume: () async {},
          onRetry: () async {},
          child: const SizedBox(),
        ),
      ),
    );

    final stop = find.widgetWithText(TextButton, 'Stop after current batch');
    await tester.tap(stop);
    await tester.pump();
    await tester.tap(stop, warnIfMissed: false);
    await tester.pump();

    expect(stopCalls, 1);
    expect(find.text('Stopping after the current batch...'), findsOneWidget);
  });

  testWidgets('stop can be requested again after resuming', (tester) async {
    final progress = ValueNotifier<DatabaseMaintenanceProgress?>(_progress());
    addTearDown(progress.dispose);
    var stopCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: DatabaseMigrationProgressHost(
          progress: progress,
          onStop: () async {
            stopCalls++;
          },
          onResume: () async {
            progress.value = _progress(currentWork: 'Resumed migration');
          },
          onRetry: () async {},
          child: const SizedBox(),
        ),
      ),
    );

    await tester.tap(
      find.widgetWithText(TextButton, 'Stop after current batch'),
    );
    await tester.pump();
    expect(stopCalls, 1);

    progress.value = _progress(state: DatabaseMaintenanceState.interrupted);
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Resume'));
    await tester.pump();

    final resumedStop = tester.widget<TextButton>(
      find.widgetWithText(TextButton, 'Stop after current batch'),
    );
    expect(resumedStop.onPressed, isNotNull);
    await tester.tap(
      find.widgetWithText(TextButton, 'Stop after current batch'),
    );
    await tester.pump();
    expect(stopCalls, 2);
  });

  testWidgets('stop is enabled after retrying a failed run', (tester) async {
    final progress = ValueNotifier<DatabaseMaintenanceProgress?>(_progress());
    addTearDown(progress.dispose);
    var stopCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: DatabaseMigrationProgressHost(
          progress: progress,
          onStop: () async {
            stopCalls++;
          },
          onResume: () async {},
          onRetry: () async {
            progress.value = _progress(currentWork: 'Retried migration');
          },
          child: const SizedBox(),
        ),
      ),
    );

    await tester.tap(
      find.widgetWithText(TextButton, 'Stop after current batch'),
    );
    await tester.pump();
    expect(stopCalls, 1);

    progress.value = _progress(
      state: DatabaseMaintenanceState.failed,
      errorMessage: 'Migration failed.',
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Retry'));
    await tester.pump();

    final retriedStop = tester.widget<TextButton>(
      find.widgetWithText(TextButton, 'Stop after current batch'),
    );
    expect(retriedStop.onPressed, isNotNull);
    await tester.tap(
      find.widgetWithText(TextButton, 'Stop after current batch'),
    );
    await tester.pump();
    expect(stopCalls, 2);
  });

  testWidgets('interrupted and failed states expose recovery actions', (
    tester,
  ) async {
    final progress = ValueNotifier<DatabaseMaintenanceProgress?>(
      _progress(state: DatabaseMaintenanceState.interrupted),
    );
    addTearDown(progress.dispose);
    var resumeCalls = 0;
    var retryCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: DatabaseMigrationProgressHost(
          progress: progress,
          onStop: () async {},
          onResume: () async {
            resumeCalls++;
          },
          onRetry: () async {
            retryCalls++;
          },
          child: const SizedBox(),
        ),
      ),
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Resume'));
    expect(resumeCalls, 1);

    progress.value = _progress(
      state: DatabaseMaintenanceState.failed,
      currentWork: 'Backup verification failed.',
      errorMessage: 'The backup did not pass SQLite integrity checks.',
    );
    await tester.pump();
    expect(find.text('Database maintenance failed'), findsOneWidget);
    expect(
      find.text('The backup did not pass SQLite integrity checks.'),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Retry'));
    expect(retryCalls, 1);
  });

  testWidgets('live-region label changes only at bounded milestones', (
    tester,
  ) async {
    final progress = ValueNotifier<DatabaseMaintenanceProgress?>(
      _progress(completed: 21, total: 100),
    );
    addTearDown(progress.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: DatabaseMigrationProgressHost(
          progress: progress,
          onStop: () async {},
          onResume: () async {},
          onRetry: () async {},
          child: const SizedBox(),
        ),
      ),
    );

    String liveLabel() => tester
        .widgetList<Semantics>(find.byType(Semantics))
        .singleWhere((widget) => widget.properties.liveRegion == true)
        .properties
        .label!;

    final first = liveLabel();
    progress.value = _progress(completed: 29, total: 100);
    await tester.pump();
    expect(liveLabel(), first);

    progress.value = _progress(completed: 30, total: 100);
    await tester.pump();
    expect(liveLabel(), isNot(first));
    expect(liveLabel(), contains('30 percent'));
  });
}

DatabaseMaintenanceProgress _progress({
  DatabaseMaintenanceState state = DatabaseMaintenanceState.running,
  String phase = 'Copying usage events',
  String currentWork = 'Copying event batch 1 of 4',
  int completed = 25,
  int? total = 100,
  double? ratePerSecond = 50,
  Duration elapsed = const Duration(seconds: 5),
  Duration? estimatedRemaining = const Duration(seconds: 15),
  int walBytes = 2 * 1024 * 1024,
  String? errorMessage,
}) => DatabaseMaintenanceProgress(
  state: state,
  phase: phase,
  currentWork: currentWork,
  unitLabel: 'events',
  completedUnits: completed,
  totalUnits: total,
  ratePerSecond: ratePerSecond,
  elapsed: elapsed,
  estimatedRemaining: estimatedRemaining,
  walBytes: walBytes,
  errorMessage: errorMessage,
);
