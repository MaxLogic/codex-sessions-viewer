import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../accessibility/announcement_service.dart';
import '../../background_collection/background_collection.dart';
import 'app_button.dart';
import 'svg_icon.dart';

/// The Settings controls for collecting sessions while the viewer is closed.
/// Changes apply at once to the harness configuration and to the scheduler,
/// not on "Save settings", and every result is announced and shown as text.
class BackgroundCollectionPanel extends StatefulWidget {
  const BackgroundCollectionPanel({
    super.key,
    required this.collection,
    this.announcer,
    this.onOpenFolder,
  });

  final BackgroundCollection collection;
  final ScreenReaderAnnouncer? announcer;

  /// Opens a folder in the file manager; the button is hidden without it.
  final Future<void> Function(String folder)? onOpenFolder;

  static const intervalChoices = [5, 15, 30, 60];
  static const defaultIntervalMinutes = 5;

  /// Local time, one format for every timestamp on the panel.
  static String formatLocal(DateTime time) {
    final local = time.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  /// Formats a database UTC timestamp; "Never" when absent or unreadable.
  static String formatStored(String? utc) {
    final parsed = utc == null ? null : DateTime.tryParse(utc);
    return parsed == null ? 'Never' : formatLocal(parsed);
  }

  @override
  State<BackgroundCollectionPanel> createState() =>
      _BackgroundCollectionPanelState();
}

class _BackgroundCollectionPanelState extends State<BackgroundCollectionPanel> {
  BackgroundCollectionStatus? _status;
  String? _loadError;
  bool _busy = false;
  String _message = '';
  int _interval = BackgroundCollectionPanel.defaultIntervalMinutes;
  bool _intervalTouched = false;
  final _focus = <String, FocusNode>{};

  FocusNode _node(String name) =>
      _focus.putIfAbsent(name, () => FocusNode(debugLabel: 'background-$name'));

  @override
  void initState() {
    super.initState();
    _refresh(announce: false);
  }

  @override
  void dispose() {
    for (final node in _focus.values) {
      node.dispose();
    }
    super.dispose();
  }

  Future<void> _tell(String message) async {
    if (mounted) setState(() => _message = message);
    await widget.announcer?.announce(message);
  }

  /// A disabled button cannot hold focus, so focus goes back to a named
  /// control once the panel is enabled again.
  void _restoreFocus(String? name) {
    if (name == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // The named button may be gone (for example after a failed status
      // read); Refresh is always there.
      final target = _focus[name];
      (target != null && target.parent != null ? target : _node('refresh'))
          .requestFocus();
    });
  }

  Future<void> _refresh({
    bool announce = true,
    bool focus = false,
    bool keepBusy = false,
  }) async {
    setState(() => _busy = true);
    try {
      final status = await widget.collection.status();
      if (!mounted) return;
      setState(() {
        _status = status;
        _loadError = null;
        final installed = status.schedule.intervalMinutes;
        // A choice the user made and has not applied stays across refreshes.
        if (installed != null && !_intervalTouched) _interval = installed;
      });
      if (announce) await _tell(_summaryText(status));
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        // Rows from before the failure would look current; drop them.
        _status = null;
        _loadError = error is BackgroundCollectionException
            ? error.message
            : 'The status could not be read.';
      });
      await _tell('Could not read background collection status.');
    } finally {
      // A change in progress keeps the panel disabled until it finishes.
      if (mounted) {
        if (!keepBusy) setState(() => _busy = false);
        if (focus) _restoreFocus('refresh');
      }
    }
  }

  /// Runs one change with progress, result and focus handling. [focusAfter]
  /// names the control that survives a success; a failure keeps [focusOnFail].
  Future<void> _change({
    required String progress,
    required String failure,
    required Future<String> Function() action,
    required String focusAfter,
    required String focusOnFail,
  }) async {
    setState(() => _busy = true);
    await _tell(progress);
    var succeeded = false;
    try {
      final done = await action();
      succeeded = true;
      await _refresh(announce: false, keepBusy: true);
      await _tell(done);
    } on BackgroundCollectionException catch (error) {
      await _refresh(announce: false, keepBusy: true);
      await _tell('$failure ${error.message}');
    } on Object {
      await _refresh(announce: false, keepBusy: true);
      await _tell('$failure The change could not be applied.');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _restoreFocus(succeeded ? focusAfter : focusOnFail);
      }
    }
  }

  static String _summaryText(BackgroundCollectionStatus status) {
    final gaps = status.gaps;
    final detail = gaps.isEmpty ? '' : ': ${gaps.join('; ')}';
    return switch (status.summary) {
      BackgroundCollectionSummary.off => 'Background collection is off.',
      BackgroundCollectionSummary.partial =>
        'Background collection is partly on$detail.',
      BackgroundCollectionSummary.on => 'Background collection is on.',
      BackgroundCollectionSummary.attention =>
        'Background collection needs attention$detail.',
    };
  }

  static String _hookText(HookStatus hook) => switch (hook.state) {
    HookInstallState.installed => 'Installed',
    HookInstallState.outdated => 'Out of date. Update to fix.',
    HookInstallState.notInstalled => 'Not installed',
    HookInstallState.error =>
      'Needs attention: ${hook.detail ?? 'the configuration could not be checked.'}',
  };

  Future<void> _openFolder(String folder) async {
    try {
      await widget.onOpenFolder!(folder);
    } on Object {
      await _tell('Could not open the folder.');
    }
  }

  Future<void> _copyPath(String path) async {
    await Clipboard.setData(ClipboardData(text: path));
    await _tell('Path copied.');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = _status;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Collect sessions while the viewer is closed. Hooks add each '
          'finished turn as it happens; the periodic scan catches anything a '
          'hook missed and also runs while the viewer is open.',
          style: muted,
        ),
        const SizedBox(height: 4),
        Text(
          'Changes here apply immediately. They are not part of Save '
          'settings. Hooks edit your Codex config.toml and Claude Code '
          'settings.json: a backup is kept beside each file, and an existing '
          'Codex notify command is chained, then restored when you remove the '
          'hook. The periodic scan is a per-user scheduled task.',
          key: const Key('background-explanation'),
          style: muted,
        ),
        const SizedBox(height: 8),
        Semantics(
          liveRegion: true,
          container: true,
          child: Text(
            _loadError != null
                ? 'Status unavailable: $_loadError'
                : status == null
                ? 'Checking background collection...'
                : _summaryText(status),
            key: const Key('background-summary'),
            style: theme.textTheme.titleSmall,
          ),
        ),
        const SizedBox(height: 8),
        if (status != null) ...[
          for (final harness in CollectionHarness.values)
            _hookRow(harness, status.hooks[harness]!),
          _scheduleRow(status),
          const SizedBox(height: 4),
          Text(
            'Last scan finished: '
            '${BackgroundCollectionPanel.formatStored(status.lastScanFinishedUtc)}',
          ),
          Text(
            'Last session collected: '
            '${BackgroundCollectionPanel.formatStored(status.lastCollectionUtc)}',
          ),
        ],
        const SizedBox(height: 8),
        AppButton.outlined(
          key: const Key('background-refresh'),
          focusNode: _node('refresh'),
          onPressed: _busy ? null : () => _refresh(focus: true),
          icon: const AppSvgIcon(AppIcons.refresh),
          label: const Text('Refresh background status'),
        ),
        Semantics(
          liveRegion: true,
          container: true,
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_message, key: const Key('background-message')),
          ),
        ),
      ],
    );
  }

  static const _actionWidth = 320.0;

  Widget _row({
    required String label,
    required String state,
    required List<Widget> actions,
    Key? stateKey,
    List<Widget> details = const [],
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Semantics(
        container: true,
        child: LayoutBuilder(
          builder: (context, box) {
            final stateColumn = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(state, key: stateKey),
                ...details,
              ],
            );
            final actionColumn = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final action in actions)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: action,
                  ),
              ],
            );
            if (box.maxWidth < 760) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 2),
                  stateColumn,
                  const SizedBox(height: 6),
                  actionColumn,
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 200, child: Text(label)),
                Expanded(child: stateColumn),
                const SizedBox(width: 12),
                SizedBox(width: _actionWidth, child: actionColumn),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _hookRow(CollectionHarness harness, HookStatus hook) {
    final installed = hook.state == HookInstallState.installed;
    final path = hook.configPath;
    final canFix =
        hook.state == HookInstallState.notInstalled ||
        hook.state == HookInstallState.outdated;
    final removable = installed || hook.state == HookInstallState.outdated;
    final id = harness.id;
    return _row(
      label: harness.label,
      state: _hookText(hook),
      stateKey: Key('background-$id-state'),
      details: [
        if (hook.state == HookInstallState.error && path != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Configuration file: $path',
              key: Key('background-$id-path'),
            ),
          ),
      ],
      actions: [
        if (canFix)
          AppButton.filled(
            key: Key('background-$id-install'),
            focusNode: _node('$id-install'),
            onPressed: _busy
                ? null
                : () => _change(
                    progress: 'Installing ${harness.label}…',
                    failure: 'Could not install ${harness.label}.',
                    focusAfter: '$id-remove',
                    focusOnFail: '$id-install',
                    action: () async {
                      await widget.collection.installHook(harness);
                      return '${harness.label} installed.';
                    },
                  ),
            icon: const AppSvgIcon(AppIcons.play),
            label: Text(
              hook.state == HookInstallState.outdated
                  ? 'Update ${harness.label}'
                  : 'Install ${harness.label}',
            ),
          ),
        if (removable)
          AppButton.outlined(
            key: Key('background-$id-remove'),
            focusNode: _node('$id-remove'),
            onPressed: _busy
                ? null
                : () => _change(
                    progress: 'Removing ${harness.label}…',
                    failure: 'Could not remove ${harness.label}.',
                    focusAfter: '$id-install',
                    focusOnFail: '$id-remove',
                    action: () async {
                      final restored = await widget.collection.removeHook(
                        harness,
                      );
                      return restored
                          ? '${harness.label} removed. The previous hook '
                                'configuration was restored.'
                          : '${harness.label} removed.';
                    },
                  ),
            icon: const AppSvgIcon(AppIcons.cancel),
            label: Text('Remove ${harness.label}'),
          ),
        if (hook.state == HookInstallState.error && path != null) ...[
          AppButton.outlined(
            key: Key('background-$id-copy-path'),
            focusNode: _node('$id-copy'),
            onPressed: () => _copyPath(path),
            icon: const AppSvgIcon(AppIcons.copy),
            label: const Text('Copy path'),
          ),
          if (widget.onOpenFolder != null)
            AppButton.outlined(
              key: Key('background-$id-open-folder'),
              focusNode: _node('$id-open'),
              onPressed: () => _openFolder(p.dirname(path)),
              icon: const AppSvgIcon(AppIcons.folderOpen),
              label: const Text('Open folder'),
            ),
        ],
      ],
    );
  }

  Widget _scheduleRow(BackgroundCollectionStatus status) {
    final schedule = status.schedule;
    const stateKey = Key('background-schedule-state');
    if (!status.scheduleSupported) {
      return _row(
        label: 'Periodic scan',
        state: 'Not available on this operating system yet.',
        stateKey: stateKey,
        actions: const [],
      );
    }
    if (schedule.error != null) {
      return _row(
        label: 'Periodic scan',
        state: 'Needs attention: ${schedule.error}',
        stateKey: stateKey,
        actions: const [],
      );
    }
    final choices = {
      ...BackgroundCollectionPanel.intervalChoices,
      _interval,
      ?schedule.intervalMinutes,
    }.toList()..sort();
    final pending =
        schedule.installed &&
        schedule.intervalMinutes != null &&
        schedule.intervalMinutes != _interval;
    String state;
    if (!schedule.installed) {
      state = 'Not scheduled';
    } else {
      final every = schedule.intervalMinutes == null
          ? 'Scheduled'
          : 'Scheduled every ${schedule.intervalMinutes} minutes';
      final ran = schedule.running
          ? 'running now'
          : schedule.lastRun == null
          ? 'has not run yet'
          : 'last ran ${BackgroundCollectionPanel.formatLocal(schedule.lastRun!)}, '
                '${schedule.lastRunFailed
                    ? 'failed with code ${schedule.lastResult}'
                    : schedule.stopped
                    ? 'stopped'
                    : 'succeeded'}';
      state = '$every; $ran';
    }
    return _row(
      label: 'Periodic scan',
      state: state,
      stateKey: stateKey,
      details: [
        if (pending)
          Semantics(
            liveRegion: true,
            container: true,
            child: const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text(
                'Not applied yet. Press Update schedule.',
                key: Key('background-interval-pending'),
              ),
            ),
          ),
      ],
      actions: [
        Semantics(
          label: 'Periodic scan interval',
          container: true,
          child: DropdownButton<int>(
            key: const Key('background-interval'),
            value: _interval,
            items: [
              for (final minutes in choices)
                DropdownMenuItem(
                  value: minutes,
                  child: Text('Every $minutes minutes'),
                ),
            ],
            onChanged: _busy
                ? null
                : (value) {
                    if (value != null) {
                      setState(() {
                        _interval = value;
                        _intervalTouched = true;
                      });
                    }
                  },
          ),
        ),
        AppButton.filled(
          key: const Key('background-schedule-install'),
          focusNode: _node('schedule-install'),
          onPressed: _busy
              ? null
              : () => _change(
                  progress: 'Setting the periodic scan…',
                  failure: 'Could not set the periodic scan.',
                  focusAfter: 'schedule-install',
                  focusOnFail: 'schedule-install',
                  action: () async {
                    await widget.collection.installSchedule(_interval);
                    if (mounted) setState(() => _intervalTouched = false);
                    return 'Periodic scan set to every $_interval minutes.';
                  },
                ),
          icon: const AppSvgIcon(AppIcons.play),
          label: Text(schedule.installed ? 'Update schedule' : 'Schedule scan'),
        ),
        if (schedule.installed)
          AppButton.outlined(
            key: const Key('background-schedule-remove'),
            focusNode: _node('schedule-remove'),
            onPressed: _busy
                ? null
                : () => _change(
                    progress: 'Removing the periodic scan…',
                    failure: 'Could not remove the periodic scan.',
                    focusAfter: 'schedule-install',
                    focusOnFail: 'schedule-remove',
                    action: () async {
                      await widget.collection.removeSchedule();
                      if (mounted) setState(() => _intervalTouched = false);
                      return 'Periodic scan removed.';
                    },
                  ),
            icon: const AppSvgIcon(AppIcons.cancel),
            label: const Text('Remove schedule'),
          ),
      ],
    );
  }
}
