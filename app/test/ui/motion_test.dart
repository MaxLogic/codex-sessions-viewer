import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/ui/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('resolves motion policy modes', () {
    final systemReduced = CodexMotionPolicy.resolve(
      mode: AppMotionMode.system,
      disableAnimations: true,
      accessibleNavigation: false,
      screenReaderActive: false,
      highContrast: false,
    );

    expect(systemReduced.isReduced, isTrue);
    expect(systemReduced.pageDuration, Duration.zero);

    final systemWithAccessibilityService = CodexMotionPolicy.resolve(
      mode: AppMotionMode.system,
      disableAnimations: false,
      accessibleNavigation: true,
      screenReaderActive: true,
      highContrast: false,
    );

    expect(systemWithAccessibilityService.isReduced, isFalse);

    final explicitReduced = CodexMotionPolicy.resolve(
      mode: AppMotionMode.reduced,
      disableAnimations: false,
      accessibleNavigation: false,
      screenReaderActive: false,
      highContrast: false,
    );

    expect(explicitReduced.isReduced, isTrue);
    expect(explicitReduced.rowUpdateDuration, Duration.zero);

    final normalOverride = CodexMotionPolicy.resolve(
      mode: AppMotionMode.normal,
      disableAnimations: true,
      accessibleNavigation: true,
      screenReaderActive: true,
      highContrast: true,
    );

    expect(normalOverride.isReduced, isFalse);
    expect(normalOverride.pageDuration, CodexMotionDurations.page);
    expect(normalOverride.standardCurve, isNot(Curves.linear));
  });

  testWidgets('motion helpers build reusable transition primitives', (
    tester,
  ) async {
    final policy = CodexMotionPolicy.resolve(
      mode: AppMotionMode.normal,
      disableAnimations: false,
      accessibleNavigation: false,
      screenReaderActive: false,
      highContrast: false,
    );

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Column(children: _motionDemoChildren(policy)),
      ),
    );

    expect(find.byType(FadeTransition), findsAtLeastNWidgets(5));
    expect(find.byType(SlideTransition), findsAtLeastNWidgets(4));
    expect(find.byType(AnimatedSize), findsOneWidget);
    expect(find.byType(ScaleTransition), findsOneWidget);
  });

  testWidgets('reduced motion helpers avoid movement transforms', (
    tester,
  ) async {
    final policy = CodexMotionPolicy.resolve(
      mode: AppMotionMode.reduced,
      disableAnimations: false,
      accessibleNavigation: false,
      screenReaderActive: false,
      highContrast: false,
    );

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Column(
          children: [
            CodexMotion.pageFadeSlide(
              policy: policy,
              animation: const AlwaysStoppedAnimation<double>(1),
              child: const Text('page'),
            ),
            CodexMotion.dialogTransition(
              policy: policy,
              animation: const AlwaysStoppedAnimation<double>(1),
              child: const Text('dialog'),
            ),
            CodexMotion.rowUpdateTransition(
              policy: policy,
              animation: const AlwaysStoppedAnimation<double>(1),
              child: const Text('row'),
            ),
          ],
        ),
      ),
    );

    expect(find.byType(SlideTransition), findsNothing);
    expect(find.byType(ScaleTransition), findsNothing);
    expect(find.text('page'), findsOneWidget);
    expect(find.text('dialog'), findsOneWidget);
    expect(find.text('row'), findsOneWidget);
  });
}

List<Widget> _motionDemoChildren(CodexMotionPolicy policy) => [
  CodexMotion.pageFadeSlide(
    policy: policy,
    animation: const AlwaysStoppedAnimation<double>(1),
    direction: AxisDirection.left,
    child: const Text('page'),
  ),
  CodexMotion.paneFadeSlide(
    policy: policy,
    animation: const AlwaysStoppedAnimation<double>(1),
    child: const Text('pane'),
  ),
  CodexMotion.expandCollapse(policy: policy, child: const Text('expand')),
  CodexMotion.transientSlideFade(
    policy: policy,
    animation: const AlwaysStoppedAnimation<double>(1),
    child: const Text('transient'),
  ),
  CodexMotion.dialogTransition(
    policy: policy,
    animation: const AlwaysStoppedAnimation<double>(1),
    child: const Text('dialog'),
  ),
  CodexMotion.rowUpdateTransition(
    policy: policy,
    animation: const AlwaysStoppedAnimation<double>(1),
    child: const Text('row'),
  ),
];
