import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../database/database_maintenance.dart';

typedef DatabaseMaintenanceAction = Future<void> Function();

class DatabaseMigrationProgressHost extends StatefulWidget {
  const DatabaseMigrationProgressHost({
    required this.progress,
    required this.onStop,
    required this.onResume,
    required this.onRetry,
    required this.child,
    super.key,
  });

  final ValueListenable<DatabaseMaintenanceProgress?> progress;
  final DatabaseMaintenanceAction onStop;
  final DatabaseMaintenanceAction onResume;
  final DatabaseMaintenanceAction onRetry;
  final Widget child;

  @override
  State<DatabaseMigrationProgressHost> createState() =>
      _DatabaseMigrationProgressHostState();
}

class _DatabaseMigrationProgressHostState
    extends State<DatabaseMigrationProgressHost> {
  var _hidden = false;
  var _stopRequested = false;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<DatabaseMaintenanceProgress?>(
      valueListenable: widget.progress,
      builder: (context, progress, _) {
        if (progress == null ||
            progress.state == DatabaseMaintenanceState.succeeded) {
          return widget.child;
        }
        if (_hidden) {
          return _HiddenMaintenanceView(
            progress: progress,
            onShow: () => setState(() => _hidden = false),
          );
        }
        return Scaffold(
          body: SafeArea(
            child: Center(
              child: DatabaseMigrationProgressDialog(
                progress: progress,
                stopRequested: _stopRequested,
                onHide: () => setState(() => _hidden = true),
                onStop: _requestStop,
                onResume: () => _restart(widget.onResume),
                onRetry: () => _restart(widget.onRetry),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _requestStop() async {
    if (_stopRequested) {
      return;
    }
    setState(() => _stopRequested = true);
    await widget.onStop();
  }

  Future<void> _restart(DatabaseMaintenanceAction action) async {
    if (_stopRequested) {
      setState(() => _stopRequested = false);
    }
    await action();
  }
}

class DatabaseMigrationProgressDialog extends StatelessWidget {
  const DatabaseMigrationProgressDialog({
    required this.progress,
    required this.stopRequested,
    required this.onHide,
    required this.onStop,
    required this.onResume,
    required this.onRetry,
    super.key,
  });

  final DatabaseMaintenanceProgress progress;
  final bool stopRequested;
  final VoidCallback onHide;
  final DatabaseMaintenanceAction onStop;
  final DatabaseMaintenanceAction onResume;
  final DatabaseMaintenanceAction onRetry;

  @override
  Widget build(BuildContext context) {
    final percentage = progress.percentage;
    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: 'Database maintenance progress',
      child: AlertDialog(
        title: Text(
          progress.state == DatabaseMaintenanceState.failed
              ? 'Database maintenance failed'
              : 'Updating the database',
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: FocusTraversalGroup(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Semantics(
                  liveRegion: true,
                  label: progress.boundedAnnouncement,
                  child: ExcludeSemantics(
                    child: Text(
                      progress.phase,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(progress.currentWork),
                const SizedBox(height: 16),
                LinearProgressIndicator(
                  value: progress.fraction,
                  semanticsLabel: progress.totalUnits == null
                      ? 'Database maintenance progress'
                      : 'Database maintenance progress, $percentage percent',
                  semanticsValue: percentage == null ? null : '$percentage%',
                ),
                const SizedBox(height: 12),
                if (progress.totalUnits != null)
                  Text(
                    '${progress.completedUnits} of ${progress.totalUnits} '
                    '${progress.unitLabel}',
                  )
                else
                  Text('${progress.completedUnits} ${progress.unitLabel}'),
                if (progress.ratePerSecond != null)
                  Text(
                    '${progress.ratePerSecond!.toStringAsFixed(1)} '
                    '${progress.unitLabel}/s',
                  ),
                Text('Elapsed ${_duration(progress.elapsed)}'),
                if (progress.estimatedRemaining != null)
                  Text('ETA ${_duration(progress.estimatedRemaining!)}'),
                Text('WAL ${_bytes(progress.walBytes)}'),
                if (stopRequested) ...[
                  const SizedBox(height: 12),
                  const Text('Stopping after the current batch...'),
                ],
                if (progress.errorMessage != null) ...[
                  const SizedBox(height: 12),
                  Semantics(
                    label: 'Database maintenance error',
                    child: Text(progress.errorMessage!),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: _actions(),
      ),
    );
  }

  List<Widget> _actions() {
    switch (progress.state) {
      case DatabaseMaintenanceState.running:
        return [
          TextButton(onPressed: onHide, child: const Text('Hide')),
          TextButton(
            onPressed: stopRequested ? null : () => unawaited(onStop()),
            child: const Text('Stop after current batch'),
          ),
        ];
      case DatabaseMaintenanceState.interrupted:
        return [
          TextButton(onPressed: onHide, child: const Text('Hide')),
          FilledButton(
            onPressed: () => unawaited(onResume()),
            child: const Text('Resume'),
          ),
        ];
      case DatabaseMaintenanceState.failed:
        return [
          FilledButton(
            onPressed: () => unawaited(onRetry()),
            child: const Text('Retry'),
          ),
        ];
      case DatabaseMaintenanceState.succeeded:
        return const [];
    }
  }
}

class _HiddenMaintenanceView extends StatelessWidget {
  const _HiddenMaintenanceView({required this.progress, required this.onShow});

  final DatabaseMaintenanceProgress progress;
  final VoidCallback onShow;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Database maintenance')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Database maintenance continues in the background.'),
              const SizedBox(height: 8),
              Text(progress.currentWork),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: onShow,
                child: const Text('Show progress'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _duration(Duration value) {
  final totalSeconds = value.inSeconds < 0 ? 0 : value.inSeconds;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  final short =
      '${minutes.toString().padLeft(2, '0')}:'
      '${seconds.toString().padLeft(2, '0')}';
  return hours == 0 ? short : '${hours.toString().padLeft(2, '0')}:$short';
}

String _bytes(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '$bytes B';
}
