import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../scanner/resident_collector_client.dart';
import '../../config/app_settings.dart';
import '../motion.dart';

/// A short, non-blocking status shared by the startup and normal app shells.
class CollectorStatus extends StatefulWidget {
  const CollectorStatus({
    super.key,
    required this.client,
    this.motionMode = AppMotionMode.system,
  });
  final ResidentCollectorClient client;
  final AppMotionMode motionMode;

  @override
  State<CollectorStatus> createState() => _CollectorStatusState();
}

class _CollectorStatusState extends State<CollectorStatus> {
  late int _seenRecovery;

  @override
  void initState() {
    super.initState();
    _seenRecovery = widget.client.reconnectionAnnouncement;
    widget.client.addListener(_changed);
  }

  void _changed() {
    if (_seenRecovery == widget.client.reconnectionAnnouncement) return;
    _seenRecovery = widget.client.reconnectionAnnouncement;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        SemanticsService.sendAnnouncement(
          View.of(context),
          'Session collection reconnected.',
          Directionality.of(context),
        ),
      );
    });
  }

  @override
  void didUpdateWidget(covariant CollectorStatus oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.client, widget.client)) {
      oldWidget.client.removeListener(_changed);
      _seenRecovery = widget.client.reconnectionAnnouncement;
      widget.client.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.client.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.client,
    builder: (context, _) {
      final text = widget.client.statusText;
      final policy = CodexMotionPolicy.fromContext(
        context,
        mode: widget.motionMode,
      );
      final band = text.isEmpty
          ? const SizedBox.shrink()
          : Material(
              color: Theme.of(context).colorScheme.surfaceContainer,
              shape: Border(
                top: BorderSide(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
              child: Semantics(
                container: true,
                liveRegion: true,
                label: text,
                excludeSemantics: true,
                child: SizedBox(
                  width: double.infinity,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Text(text),
                  ),
                ),
              ),
            );
      return AnimatedSwitcher(
        duration: policy.transientDuration,
        transitionBuilder: (child, animation) => CodexMotion.transientSlideFade(
          policy: policy,
          animation: animation,
          child: child,
        ),
        // Outgoing semantics must disappear immediately rather than reannounce.
        layoutBuilder: (currentChild, previousChildren) =>
            currentChild ?? const SizedBox.shrink(),
        child: KeyedSubtree(key: ValueKey(text), child: band),
      );
    },
  );
}
