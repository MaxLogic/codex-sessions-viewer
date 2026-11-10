import 'dart:async';

import 'package:flutter/material.dart';

import '../../config/app_settings.dart';
import '../../config/parsed_with_settings.dart';
import '../motion.dart';
import '../scan_activity.dart';
import '../screens/sessions_screen.dart';
import '../themes.dart';
import 'app_button.dart';

/// Explicit history reparse action connected to the app-owned scan operation.
class ReparseSettingsNotice extends StatefulWidget {
  const ReparseSettingsNotice({
    super.key,
    required this.settings,
    required this.parsedWith,
    required this.reloadParsedWith,
    required this.onReparse,
    this.scanActivity,
  });

  final AppSettings settings;
  final Future<ParsedWithSettings> parsedWith;
  final Future<ParsedWithSettings> Function() reloadParsedWith;
  final SessionsRefreshOperationFactory onReparse;
  final ScanActivity? scanActivity;

  @override
  State<ReparseSettingsNotice> createState() => _ReparseSettingsNoticeState();
}

class _ReparseSettingsNoticeState extends State<ReparseSettingsNotice> {
  late Future<ParsedWithSettings> _parsedWith;
  late final ScanActivity _activity;
  final _cancelFocus = FocusNode(debugLabel: 'Cancel scan');
  final _statusFocus = FocusNode(debugLabel: 'Session scan status');
  final _noticeFocus = FocusNode(canRequestFocus: false, skipTraversal: true);
  bool _wasRunning = false;
  bool _startedHere = false;
  bool _cancelledHere = false;

  @override
  void initState() {
    super.initState();
    _parsedWith = widget.parsedWith;
    _activity = widget.scanActivity ?? ScanActivity();
    _wasRunning = _activity.running;
    _activity.addListener(_changed);
  }

  @override
  void didUpdateWidget(ReparseSettingsNotice oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.parsedWith != widget.parsedWith) {
      _parsedWith = widget.parsedWith;
    }
  }

  void _focusAfterFrame(FocusNode node) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && node.context != null) node.requestFocus();
    });
  }

  void _changed() {
    if (!mounted) return;
    if (_wasRunning != _activity.running) {
      if (_activity.running) {
        _cancelledHere = false;
        if (_startedHere && _activity.forced) {
          _focusAfterFrame(_cancelFocus);
        }
      } else if (_noticeFocus.hasFocus) {
        _focusAfterFrame(_statusFocus);
      }
      if (!_activity.running) _startedHere = false;
    }
    _wasRunning = _activity.running;
    setState(() {});
  }

  Future<void> _reparse() async {
    if (_activity.running) return;
    _startedHere = true;
    try {
      final operation = widget.onReparse(
        widget.scanActivity == null ? _activity.update : (_) {},
      );
      // Standalone Settings embedders may supply their own operation factory.
      // The shipping app always owns and updates the supplied activity.
      if (widget.scanActivity == null) _activity.start(operation, force: true);
      final result = await operation.result;
      if (widget.scanActivity != null) return;
      final recorded = await widget.reloadParsedWith();
      _activity.finish(result.statusMessage);
      if (mounted) {
        setState(() {
          _parsedWith = Future.value(recorded);
        });
      }
    } on Object catch (error) {
      if (widget.scanActivity == null) {
        _activity.finish('Could not complete the reparse. Details: $error');
      }
      _startedHere = false;
    }
  }

  @override
  void dispose() {
    _activity.removeListener(_changed);
    if (widget.scanActivity == null) _activity.dispose();
    _cancelFocus.dispose();
    _statusFocus.dispose();
    _noticeFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _noticeFocus,
    includeSemantics: false,
    child: FutureBuilder<ParsedWithSettings>(
      future: _parsedWith,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Semantics(
            liveRegion: true,
            child: Text(
              'Could not read the values stored sessions were parsed with. Details: ${snapshot.error}',
            ),
          );
        }
        final previous = snapshot.data;
        final changes = previous == null
            ? const <String>[]
            : ParsedWithSettings.capture(widget.settings).changesFrom(previous);
        final showStatus =
            (_activity.forced || _cancelledHere) && _activity.status.isNotEmpty;
        if (changes.isEmpty && !showStatus) return const SizedBox.shrink();
        final theme = Theme.of(context);
        final motion = CodexMotionPolicy.fromContext(
          context,
          mode: widget.settings.ui.motion,
        );
        return Container(
          padding: const EdgeInsets.all(12),
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (changes.isNotEmpty) ...[
                Row(
                  children: [
                    const Icon(Icons.info_outline),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: Text(
                          'History parsing settings changed',
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                for (final change in changes) Text(change),
                const Text(
                  'Stored sessions keep the old value; new turns use the new one. '
                  'Reparse all sessions to apply the new value to stored history. '
                  'It reads every session file and can take several minutes; you can cancel it.',
                ),
                const SizedBox(height: 8),
                Semantics(
                  hint: _activity.running && !_activity.forced
                      ? 'A session scan is running. Reparse becomes available when it finishes.'
                      : null,
                  child: AppButton.outlined(
                    onPressed: _activity.running ? null : _reparse,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Reparse all sessions'),
                  ),
                ),
                if (_activity.running && !_activity.forced)
                  const Text(
                    'A session scan is running. Reparse becomes available when it finishes.',
                  ),
              ],
              if (_activity.running) ...[
                TickerMode(
                  enabled: !motion.isReduced,
                  child: const LinearProgressIndicator(
                    semanticsLabel: 'Session scan progress',
                  ),
                ),
                AppButton.outlined(
                  key: const Key('reparse-cancel-scan'),
                  focusNode: _cancelFocus,
                  onPressed: _activity.cancelling
                      ? null
                      : () {
                          // The disabled Cancel button cannot retain focus.
                          _cancelledHere = true;
                          _statusFocus.requestFocus();
                          unawaited(_activity.cancel());
                        },
                  icon: const Icon(Icons.cancel_outlined),
                  label: const Text('Cancel scan'),
                ),
              ],
              if (showStatus || _activity.running)
                Focus(
                  focusNode: _statusFocus,
                  onFocusChange: (_) => setState(() {}),
                  child: Container(
                    key: const Key('reparse-status-focus'),
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: _statusFocus.hasFocus
                            ? theme.colorScheme.primary
                            : Colors.transparent,
                        width: theme.extension<CodexFocusStyle>()?.width ?? 2,
                      ),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Semantics(
                      liveRegion: true,
                      label: _activity.announcement,
                      child: ExcludeSemantics(child: Text(_activity.status)),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    ),
  );
}
