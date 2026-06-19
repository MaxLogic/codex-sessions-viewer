import 'package:flutter/material.dart';

import '../config/app_settings.dart';

abstract final class CodexMotionDurations {
  static const Duration fast = Duration(milliseconds: 120);
  static const Duration page = Duration(milliseconds: 190);
  static const Duration pane = Duration(milliseconds: 180);
  static const Duration expand = Duration(milliseconds: 180);
  static const Duration transient = Duration(milliseconds: 140);
  static const Duration dialog = Duration(milliseconds: 170);
  static const Duration rowUpdate = Duration(milliseconds: 220);
}

class CodexMotionPolicy {
  const CodexMotionPolicy({
    required this.mode,
    required this.isReduced,
    required this.disableAnimations,
    required this.accessibleNavigation,
    required this.screenReaderActive,
    required this.highContrast,
  });

  final AppMotionMode mode;
  final bool isReduced;
  final bool disableAnimations;
  final bool accessibleNavigation;
  final bool screenReaderActive;
  final bool highContrast;

  static CodexMotionPolicy resolve({
    required AppMotionMode mode,
    required bool disableAnimations,
    required bool accessibleNavigation,
    required bool screenReaderActive,
    required bool highContrast,
  }) {
    final reduced = switch (mode) {
      AppMotionMode.reduced => true,
      AppMotionMode.normal => false,
      AppMotionMode.system => disableAnimations,
    };

    return CodexMotionPolicy(
      mode: mode,
      isReduced: reduced,
      disableAnimations: disableAnimations,
      accessibleNavigation: accessibleNavigation,
      screenReaderActive: screenReaderActive,
      highContrast: highContrast,
    );
  }

  static CodexMotionPolicy fromContext(
    BuildContext context, {
    required AppMotionMode mode,
    bool screenReaderActive = false,
  }) {
    final media = MediaQuery.maybeOf(context);
    return resolve(
      mode: mode,
      disableAnimations: media?.disableAnimations ?? false,
      accessibleNavigation: media?.accessibleNavigation ?? false,
      screenReaderActive: screenReaderActive,
      highContrast: media?.highContrast ?? false,
    );
  }

  Duration get fastDuration =>
      isReduced ? Duration.zero : CodexMotionDurations.fast;
  Duration get pageDuration =>
      isReduced ? Duration.zero : CodexMotionDurations.page;
  Duration get paneDuration =>
      isReduced ? Duration.zero : CodexMotionDurations.pane;
  Duration get expandDuration =>
      isReduced ? Duration.zero : CodexMotionDurations.expand;
  Duration get transientDuration =>
      isReduced ? Duration.zero : CodexMotionDurations.transient;
  Duration get dialogDuration =>
      isReduced ? Duration.zero : CodexMotionDurations.dialog;
  Duration get rowUpdateDuration =>
      isReduced ? Duration.zero : CodexMotionDurations.rowUpdate;

  Curve get standardCurve => Curves.easeOutCubic;
  Curve get emphasizedCurve => Curves.easeInOutCubic;
}

abstract final class CodexMotion {
  static Widget pageFadeSlide({
    required CodexMotionPolicy policy,
    required Animation<double> animation,
    required Widget child,
    AxisDirection direction = AxisDirection.left,
  }) => _slideFade(
    policy: policy,
    animation: animation,
    begin: _offsetFor(direction, 0.035),
    child: child,
  );

  static Widget paneFadeSlide({
    required CodexMotionPolicy policy,
    required Animation<double> animation,
    required Widget child,
    AxisDirection direction = AxisDirection.left,
  }) => _slideFade(
    policy: policy,
    animation: animation,
    begin: _offsetFor(direction, 0.025),
    child: child,
  );

  static Widget expandCollapse({
    required CodexMotionPolicy policy,
    required Widget child,
    AlignmentGeometry alignment = Alignment.topCenter,
  }) => ClipRect(
    child: AnimatedSize(
      duration: policy.expandDuration,
      curve: policy.emphasizedCurve,
      alignment: alignment,
      child: child,
    ),
  );

  static Widget transientSlideFade({
    required CodexMotionPolicy policy,
    required Animation<double> animation,
    required Widget child,
    AxisDirection direction = AxisDirection.up,
  }) => _slideFade(
    policy: policy,
    animation: animation,
    begin: _offsetFor(direction, 0.03),
    child: child,
  );

  static Widget dialogTransition({
    required CodexMotionPolicy policy,
    required Animation<double> animation,
    required Widget child,
  }) {
    if (policy.isReduced) {
      return child;
    }

    final curved = CurvedAnimation(
      parent: animation,
      curve: policy.emphasizedCurve,
      reverseCurve: policy.standardCurve,
    );
    return FadeTransition(
      opacity: curved,
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.98, end: 1).animate(curved),
        child: child,
      ),
    );
  }

  static Widget rowUpdateTransition({
    required CodexMotionPolicy policy,
    required Animation<double> animation,
    required Widget child,
  }) {
    if (policy.isReduced) {
      return FadeTransition(
        opacity: Tween<double>(begin: 0.82, end: 1).animate(animation),
        child: child,
      );
    }
    return _slideFade(
      policy: policy,
      animation: animation,
      begin: const Offset(0, 0.018),
      child: child,
    );
  }

  static Widget _slideFade({
    required CodexMotionPolicy policy,
    required Animation<double> animation,
    required Offset begin,
    required Widget child,
  }) {
    if (policy.isReduced) {
      return child;
    }

    final curved = CurvedAnimation(
      parent: animation,
      curve: policy.standardCurve,
      reverseCurve: policy.emphasizedCurve,
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(begin: begin, end: Offset.zero).animate(curved),
        child: child,
      ),
    );
  }

  static Offset _offsetFor(AxisDirection direction, double distance) {
    return switch (direction) {
      AxisDirection.up => Offset(0, distance),
      AxisDirection.down => Offset(0, -distance),
      AxisDirection.left => Offset(distance, 0),
      AxisDirection.right => Offset(-distance, 0),
    };
  }
}
