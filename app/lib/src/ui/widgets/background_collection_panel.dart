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
      });
      if (!keepBusy && widget.announcer != null) {
        final update = status.autostartUpdate?.takeAnnouncement();
        if (update != null) await widget.announcer!.announce(update);
      }
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
      _status?.autostartUpdate?.takeAnnouncement();
      await _tell(done);
    } on BackgroundCollectionException catch (error) {
      await _refresh(announce: false, keepBusy: true);
      _status?.autostartUpdate?.takeAnnouncement();
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
          'finished turn as it happens; session collection catches anything a '
          'hook missed and also runs while the viewer is open.',
          style: muted,
        ),
        const SizedBox(height: 4),
        Text(
          'Changes here apply immediately. They are not part of Save '
          'settings. Hooks edit your Codex config.toml and Claude Code '
          'settings.json: a backup is kept beside each file, and an existing '
          'Codex notify command is chained, then restored when you remove the '
          'hook. Start at sign-in uses a per-user scheduled task.',
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
        label: 'Start at sign-in',
        state: 'Not available on this operating system yet.',
        stateKey: stateKey,
        actions: const [],
      );
    }
    String state;
    if (schedule.error != null) {
      state = 'Needs attention: ${schedule.error}';
    } else if (!schedule.installed) {
      state = 'Not scheduled';
    } else {
      final every = schedule.outdated
          ? 'Needs an update'
          : !schedule.enabled
          ? 'Background collection is installed but turned off.'
          : 'Starts at sign-in; checked every 5 minutes';
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
      state = !schedule.enabled || schedule.outdated ? every : '$every; $ran';
    }
    return _row(
      label: 'Start at sign-in',
      state: state,
      stateKey: stateKey,
      details: [
        const Text(
          'Session collection checks for new sessions at the Scan interval (seconds) set in Settings above.',
        ),
        if (schedule.outdated && !schedule.enabled)
          const Text('Background collection is installed but turned off.'),
        if (status.autostartUpdate case final update?) ...[
          Text(update.message, key: const Key('background-autostart-update')),
          if (update.detail case final detail?)
            Text(detail, key: const Key('background-autostart-detail')),
          if (update.backupPath case final path?) ...[
            SelectableText(path, key: const Key('background-backup-path')),
            AppButton.outlined(
              key: const Key('background-backup-copy'),
              icon: const AppSvgIcon(AppIcons.copy),
              onPressed: _busy ? null : () => _copyPath(path),
              label: const Text('Copy backup path'),
            ),
          ],
        ],
      ],
      actions: [
        if (schedule.installed && !schedule.enabled)
          AppButton.filled(
            key: const Key('background-schedule-enable'),
            icon: const AppSvgIcon(AppIcons.play),
            focusNode: _node('schedule-enable'),
            onPressed: _busy
                ? null
                : () => _change(
                    progress: 'Turning on Background collection…',
                    failure: 'Could not turn on Background collection.',
                    focusAfter: 'schedule-install',
                    focusOnFail: 'schedule-enable',
                    action: () async {
                      await widget.collection.enableSchedule();
                      return 'Background collection was turned on.';
                    },
                  ),
            label: const Text('Turn on'),
          ),
        AppButton.filled(
          key: const Key('background-schedule-install'),
          focusNode: _node('schedule-install'),
          onPressed: _busy
              ? null
              : () => _change(
                  progress: 'Setting start at sign-in…',
                  failure: 'Could not set start at sign-in.',
                  focusAfter: 'schedule-install',
                  focusOnFail: 'schedule-install',
                  action: () async {
                    await widget.collection.installSchedule();
                    return schedule.installed
                        ? 'Start at sign-in was updated.'
                        : 'Start at sign-in was installed.';
                  },
                ),
          icon: const AppSvgIcon(AppIcons.play),
          label: Text(
            schedule.outdated ||
                    schedule.error != null ||
                    status.autostartUpdate?.error != null
                ? 'Retry update'
                : schedule.installed
                ? 'Reinstall start at sign-in'
                : 'Install start at sign-in',
          ),
        ),
        if (schedule.installed)
          AppButton.outlined(
            key: const Key('background-schedule-remove'),
            focusNode: _node('schedule-remove'),
            onPressed: _busy
                ? null
                : () => _change(
                    progress: 'Removing start at sign-in…',
                    failure: 'Could not remove start at sign-in.',
                    focusAfter: 'schedule-install',
                    focusOnFail: 'schedule-remove',
                    action: () async {
                      await widget.collection.removeSchedule();
                      return 'Start at sign-in was removed.';
                    },
                  ),
            icon: const AppSvgIcon(AppIcons.cancel),
            label: const Text('Remove start at sign-in'),
          ),
      ],
    );
  }
}
