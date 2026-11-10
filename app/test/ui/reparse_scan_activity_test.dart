import 'dart:async';

import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/config/parsed_with_settings.dart';
import 'package:codex_sessions_viewer/src/ui/scan_activity.dart';
import 'package:codex_sessions_viewer/src/ui/themes.dart';
import 'package:codex_sessions_viewer/src/ui/screens/sessions_screen.dart';
import 'package:codex_sessions_viewer/src/ui/widgets/reparse_settings_notice.dart';
import 'package:codex_sessions_viewer/src/ui/widgets/app_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

AppSettings settings(int preview) => AppSettings.fromTomlMap({
  'tool_output': {'max_tool_output_preview_chars': preview},
  'ui': {'motion': 'reduced'},
});

void main() {
  testWidgets('S1 remounted reparse retains focus on natural completion', (
    tester,
  ) async {
    final activity = ScanActivity();
    addTearDown(activity.dispose);
    final completion = Completer<SessionsRefreshResult>();
    final baseline = ParsedWithSettings.capture(settings(4000));
    Widget host(bool visible) => MaterialApp(
      home: Scaffold(
        body: visible
            ? ReparseSettingsNotice(
                settings: settings(8000),
                parsedWith: Future.value(baseline),
                reloadParsedWith: () async => baseline,
                scanActivity: activity,
                onReparse: (_) {
                  final operation = SessionsRefreshOperation(
                    result: completion.future,
                    cancel: () async {},
                  );
                  activity.start(operation, force: true);
                  return operation;
                },
              )
            : const SizedBox.shrink(),
      ),
    );
    await tester.pumpWidget(host(true));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reparse all sessions'));
    await tester.pump();
    await tester.pumpWidget(host(false));
    await tester.pump();
    expect(activity.running, isTrue);
    await tester.pumpWidget(host(true));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'Cancel scan');
    const result = SessionsRefreshResult(
      rows: [],
      statusMessage: 'Reparse finished.',
    );
    completion.complete(result);
    activity.finish(result.statusMessage);
    await tester.pumpAndSettle();
    expect(find.text(result.statusMessage), findsOneWidget);
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'Session scan status',
    );
  });

  testWidgets('S2 new foreign scan clears prior local cancellation status', (
    tester,
  ) async {
    final activity = ScanActivity();
    addTearDown(activity.dispose);
    final baseline = ParsedWithSettings.capture(settings(4000));
    SessionsRefreshOperation operation() => SessionsRefreshOperation(
      result: Completer<SessionsRefreshResult>().future,
      cancel: () async {},
    );
    activity.start(operation(), force: false);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReparseSettingsNotice(
            settings: settings(8000),
            parsedWith: Future.value(baseline),
            reloadParsedWith: () async => baseline,
            scanActivity: activity,
            onReparse: (_) => throw StateError('not started here'),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('reparse-cancel-scan')));
    await tester.pump();
    activity.finish('Scan cancelled.');
    await tester.pumpAndSettle();
    expect(find.text('Scan cancelled.'), findsOneWidget);
    activity.start(operation(), force: false);
    await tester.pump();
    activity.finish('Later ordinary scan finished.');
    await tester.pumpAndSettle();
    expect(find.text('Later ordinary scan finished.'), findsNothing);
    expect(find.text('Reparse all sessions'), findsOneWidget);
  });

  for (final forced in [false, true]) {
    testWidgets(
      'UX9 Cancel focuses retained status for foreign scan forced=$forced',
      (tester) async {
        final activity = ScanActivity();
        addTearDown(activity.dispose);
        final completion = Completer<SessionsRefreshResult>();
        final baseline = ParsedWithSettings.capture(settings(4000));
        activity.start(
          SessionsRefreshOperation(
            result: completion.future,
            cancel: () async {},
          ),
          force: forced,
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ReparseSettingsNotice(
                settings: settings(8000),
                parsedWith: Future.value(baseline),
                reloadParsedWith: () async => baseline,
                onReparse: (_) => throw StateError('not started here'),
                scanActivity: activity,
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump();
        const hint =
            'A session scan is running. Reparse becomes available when it finishes.';
        expect(find.text(hint), forced ? findsNothing : findsOneWidget);
        final cancel = find.byKey(const Key('reparse-cancel-scan'));
        if (!forced) {
          // A keyboard user explicitly cancelling a foreign ordinary scan.
          tester.widget<AppButton>(cancel).focusNode!.requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        } else {
          // Pointer cancellation must also focus status after notice remount.
          await tester.tap(cancel);
        }
        await tester.pump();
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          'Session scan status',
        );
        const result = SessionsRefreshResult(
          rows: [],
          statusMessage: 'Scan cancelled.',
          cancelled: true,
        );
        completion.complete(result);
        activity.finish(result.statusMessage);
        await tester.pumpAndSettle();
        expect(find.text('Scan cancelled.'), findsOneWidget);
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          'Session scan status',
        );
      },
    );
  }

  testWidgets('UX10 own reparse omits waiting hint and helper', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      final activity = ScanActivity();
      addTearDown(activity.dispose);
      final completion = Completer<SessionsRefreshResult>();
      final baseline = ParsedWithSettings.capture(settings(4000));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReparseSettingsNotice(
              settings: settings(8000),
              parsedWith: Future.value(baseline),
              reloadParsedWith: () async => baseline,
              scanActivity: activity,
              onReparse: (_) {
                final operation = SessionsRefreshOperation(
                  result: completion.future,
                  cancel: () async {},
                );
                activity.start(operation, force: true);
                return operation;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reparse all sessions'));
      await tester.pump();
      const hint =
          'A session scan is running. Reparse becomes available when it finishes.';
      expect(find.text(hint), findsNothing);
      expect(
        find.byWidgetPredicate(
          (widget) => widget is Semantics && widget.properties.hint == hint,
        ),
        findsNothing,
      );
      completion.complete(
        const SessionsRefreshResult(
          rows: [],
          statusMessage: 'Reparse finished.',
        ),
      );
      activity.finish('Reparse finished.');
      await tester.pumpAndSettle();
    } finally {
      semantics.dispose();
    }
  });

  for (final mode in [
    CodexThemeMode.light,
    CodexThemeMode.dark,
    CodexThemeMode.highContrastLight,
    CodexThemeMode.highContrastDark,
  ]) {
    testWidgets('UX11 status focus uses theme width $mode', (tester) async {
      final activity = ScanActivity();
      addTearDown(activity.dispose);
      activity.start(
        SessionsRefreshOperation(
          result: Completer<SessionsRefreshResult>().future,
          cancel: () async {},
        ),
        force: true,
      );
      activity.finish('Reparse finished.');
      final baseline = ParsedWithSettings.capture(settings(4000));
      await tester.pumpWidget(
        MaterialApp(
          theme: CodexAppTheme.themeData(mode),
          home: Scaffold(
            body: ReparseSettingsNotice(
              settings: settings(4000),
              parsedWith: Future.value(baseline),
              reloadParsedWith: () async => baseline,
              scanActivity: activity,
              onReparse: (_) => throw StateError('not started here'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final box = find.byKey(const Key('reparse-status-focus'));
      Focus.of(tester.element(box)).requestFocus();
      await tester.pumpAndSettle();
      final decoration =
          tester.widget<Container>(box).decoration! as BoxDecoration;
      final border = decoration.border! as Border;
      expect(
        border.top.width,
        mode == CodexThemeMode.highContrastLight ||
                mode == CodexThemeMode.highContrastDark
            ? 4
            : 2,
      );
      expect(
        border.top.color,
        Theme.of(tester.element(box)).colorScheme.primary,
      );
    });
  }

  testWidgets('UX7 finishing a local reparse preserves focus moved outside', (
    tester,
  ) async {
    final activity = ScanActivity();
    final outside = FocusNode(debugLabel: 'Outside notice');
    addTearDown(activity.dispose);
    addTearDown(outside.dispose);
    final completion = Completer<SessionsRefreshResult>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              TextButton(
                focusNode: outside,
                onPressed: () {},
                child: const Text('Outside'),
              ),
              ReparseSettingsNotice(
                settings: settings(8000),
                parsedWith: Future.value(
                  ParsedWithSettings.capture(settings(4000)),
                ),
                reloadParsedWith: () async =>
                    ParsedWithSettings.capture(settings(4000)),
                scanActivity: activity,
                onReparse: (_) {
                  final operation = SessionsRefreshOperation(
                    result: completion.future,
                    cancel: () async {},
                  );
                  activity.start(operation, force: true);
                  return operation;
                },
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reparse all sessions'));
    await tester.pump();
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'Cancel scan');
    outside.requestFocus();
    await tester.pump();
    const result = SessionsRefreshResult(
      rows: [],
      statusMessage: 'Reparse finished.',
    );
    completion.complete(result);
    activity.finish(result.statusMessage);
    await tester.pumpAndSettle();
    expect(outside.hasFocus, isTrue);
  });

  for (final alreadyRunning in [false, true]) {
    testWidgets(
      'UX7 unrelated scan preserves focus (already running: $alreadyRunning)',
      (tester) async {
        final activity = ScanActivity();
        final outside = FocusNode(debugLabel: 'Outside notice');
        addTearDown(activity.dispose);
        addTearDown(outside.dispose);
        final operation = SessionsRefreshOperation(
          result: Completer<SessionsRefreshResult>().future,
          cancel: () async {},
        );
        if (alreadyRunning) activity.start(operation, force: false);
        Widget host(bool showNotice) => MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                TextButton(
                  focusNode: outside,
                  autofocus: true,
                  onPressed: () {},
                  child: const Text('Outside'),
                ),
                if (showNotice)
                  ReparseSettingsNotice(
                    settings: settings(8000),
                    parsedWith: Future.value(
                      ParsedWithSettings.capture(settings(4000)),
                    ),
                    reloadParsedWith: () async =>
                        ParsedWithSettings.capture(settings(4000)),
                    onReparse: (_) => throw StateError('not started here'),
                    scanActivity: activity,
                  ),
              ],
            ),
          ),
        );
        await tester.pumpWidget(host(false));
        await tester.pump();
        expect(outside.hasFocus, isTrue);
        await tester.pumpWidget(host(true));
        await tester.pump();
        await tester.pump();
        expect(outside.hasFocus, isTrue);
        if (!alreadyRunning) {
          activity.start(operation, force: false);
          await tester.pump();
          await tester.pump();
          expect(outside.hasFocus, isTrue);
        }
        activity.finish('Scan finished.');
        await tester.pumpAndSettle();
        expect(outside.hasFocus, isTrue);
      },
    );
  }

  testWidgets(
    'UX6 reparse cost, focus, bounded announcements, reduced motion and cancel',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final activity = ScanActivity();
        addTearDown(activity.dispose);
        final completion = Completer<SessionsRefreshResult>();
        var cancels = 0;
        final baseline = ParsedWithSettings.capture(settings(4000));
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ReparseSettingsNotice(
                settings: settings(8000),
                parsedWith: Future.value(baseline),
                reloadParsedWith: () async => baseline,
                scanActivity: activity,
                onReparse: (_) {
                  final operation = SessionsRefreshOperation(
                    result: completion.future,
                    cancel: () async {
                      cancels++;
                    },
                  );
                  activity.start(operation, force: true);
                  return operation;
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.textContaining(
            'It reads every session file and can take several minutes; you can cancel it.',
          ),
          findsOneWidget,
        );
        await tester.tap(find.text('Reparse all sessions'));
        await tester.pump();
        expect(FocusManager.instance.primaryFocus?.debugLabel, 'Cancel scan');
        expect(
          tester
              .getSemantics(find.byKey(const Key('reparse-cancel-scan')))
              .flagsCollection
              .isButton,
          isTrue,
        );
        final progress = find.byType(LinearProgressIndicator);
        expect(TickerMode.valuesOf(tester.element(progress)).enabled, isFalse);
        final start = activity.announcement;
        expect(start, startsWith('Reparse started.'));
        for (var i = 0; i < 100; i++) {
          activity.update(
            SessionsRefreshProgress(statusMessage: 'Parsed $i files.'),
          );
        }
        await tester.pump();
        expect(find.text('Parsed 99 files.'), findsOneWidget);
        expect(
          activity.announcement,
          start,
          reason: 'Progress bursts must not rewrite the live announcement.',
        );
        final live = tester.getSemantics(find.bySemanticsLabel(start));
        expect(live.flagsCollection.isLiveRegion, isTrue);
        await tester.tap(find.byKey(const Key('reparse-cancel-scan')));
        await tester.pump();
        await activity.cancel();
        expect(cancels, 1, reason: 'Cancellation is idempotent while pending.');
        const result = SessionsRefreshResult(
          rows: [],
          statusMessage: 'Reparse finished. Scan cancelled.',
          cancelled: true,
        );
        completion.complete(result);
        activity.finish(result.statusMessage);
        await tester.pumpAndSettle();
        expect(activity.announcement, result.statusMessage);
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          'Session scan status',
        );
        expect(find.byKey(const Key('reparse-cancel-scan')), findsNothing);
        expect(find.bySemanticsLabel(result.statusMessage), findsOneWidget);
        final statusBox = tester.widget<Container>(
          find.byKey(const Key('reparse-status-focus')),
        );
        final border =
            (statusBox.decoration! as BoxDecoration).border! as Border;
        expect(border.top.width, 2);
        expect(
          border.top.color,
          Theme.of(
            tester.element(find.byKey(const Key('reparse-status-focus'))),
          ).colorScheme.primary,
        );
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'shared operation remains cancellable after notice disposal and re-entry',
    (tester) async {
      final activity = ScanActivity();
      addTearDown(activity.dispose);
      final completion = Completer<SessionsRefreshResult>();
      var starts = 0;
      var cancels = 0;
      final baseline = ParsedWithSettings.capture(settings(4000));
      Widget notice() => MaterialApp(
        home: Scaffold(
          body: ReparseSettingsNotice(
            settings: settings(8000),
            parsedWith: Future.value(baseline),
            reloadParsedWith: () async => baseline,
            scanActivity: activity,
            onReparse: (_) {
              starts++;
              final operation = SessionsRefreshOperation(
                result: completion.future,
                cancel: () async {
                  cancels++;
                },
              );
              activity.start(operation, force: true);
              return operation;
            },
          ),
        ),
      );
      try {
        await tester.pumpWidget(notice());
        await tester.pumpAndSettle();
        await tester.tap(find.text('Reparse all sessions'));
        await tester.pump();
        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
        await tester.pumpAndSettle();
        await tester.pumpWidget(notice());
        await tester.pump();
        expect(completion.isCompleted, isFalse);
        expect(starts, 1);
        expect(cancels, 0);
        expect(find.byKey(const Key('reparse-cancel-scan')), findsOneWidget);
        await tester.tap(find.byKey(const Key('reparse-cancel-scan')));
        await tester.pump();
        expect(cancels, 1);
      } finally {
        const result = SessionsRefreshResult(
          rows: [],
          statusMessage: 'Scan completed.',
        );
        completion.complete(result);
        activity.finish(result.statusMessage);
        await tester.pumpAndSettle();
      }
    },
  );
}
