import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:codex_sessions_viewer/src/accessibility/announcement_service.dart';
import 'package:codex_sessions_viewer/src/background_collection/background_collection.dart';
import 'package:codex_sessions_viewer/src/background_collection/scan_scheduler.dart';
import 'package:codex_sessions_viewer/src/ui/screens/settings_screen.dart';
import 'package:codex_sessions_viewer/src/ui/widgets/app_button.dart';
import 'package:codex_sessions_viewer/src/ui/widgets/background_collection_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeCollection implements BackgroundCollection {
  _FakeCollection({
    HookInstallState codex = HookInstallState.notInstalled,
    HookInstallState claude = HookInstallState.notInstalled,
    this.schedule = const ScheduledScanState(installed: false),
    this.supported = true,
    this.claudeDetail,
    this.scan,
  }) : hooks = {
         CollectionHarness.codex: codex,
         CollectionHarness.claude: claude,
       };

  final Map<CollectionHarness, HookInstallState> hooks;
  ScheduledScanState schedule;
  final bool supported;
  final String? claudeDetail;
  final String? scan;
  final calls = <String>[];
  String? failWith;
  Object? statusFailure;
  bool restores = true;
  Completer<void>? gate;
  Completer<void>? statusGate;

  @override
  bool get scheduleSupported => supported;

  @override
  Future<BackgroundCollectionStatus> status() async {
    await statusGate?.future;
    if (statusFailure != null) throw statusFailure!;
    return BackgroundCollectionStatus(
      hooks: {
        CollectionHarness.codex: HookStatus(
          hooks[CollectionHarness.codex]!,
          configPath: r'C:\Users\a\.codex\config.toml',
        ),
        CollectionHarness.claude: HookStatus(
          hooks[CollectionHarness.claude]!,
          detail: claudeDetail,
          configPath: r'C:\Users\a\.claude\settings.json',
        ),
      },
      schedule: schedule,
      scheduleSupported: supported,
      lastScanFinishedUtc: scan,
      lastCollectionUtc: scan,
    );
  }

  Future<void> _work() async {
    await gate?.future;
    if (failWith != null) throw BackgroundCollectionException(failWith!);
  }

  @override
  Future<void> installHook(CollectionHarness harness) async {
    calls.add('install ${harness.id}');
    await _work();
    hooks[harness] = HookInstallState.installed;
  }

  @override
  Future<bool> removeHook(CollectionHarness harness) async {
    calls.add('remove ${harness.id}');
    await _work();
    hooks[harness] = HookInstallState.notInstalled;
    return restores;
  }

  @override
  Future<void> installSchedule(int intervalMinutes) async {
    calls.add('schedule $intervalMinutes');
    await _work();
    schedule = ScheduledScanState(
      installed: true,
      intervalMinutes: intervalMinutes,
    );
  }

  @override
  Future<void> removeSchedule() async {
    calls.add('unschedule');
    await _work();
    schedule = const ScheduledScanState(installed: false);
  }
}

Future<RecordingScreenReaderAnnouncer> _show(
  WidgetTester tester,
  BackgroundCollection collection, {
  Future<void> Function(String)? onOpenFolder,
  double width = 1000,
}) async {
  final announcer = RecordingScreenReaderAnnouncer();
  tester.view.physicalSize = Size(width, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: BackgroundCollectionPanel(
              collection: collection,
              announcer: announcer,
              onOpenFolder: onOpenFolder,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return announcer;
}

String _text(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(Key(key))).data!;

/// The key of the [AppButton] that owns keyboard focus, if any.
Key? _focusedButton() {
  final context = FocusManager.instance.primaryFocus?.context;
  return context?.findAncestorWidgetOfExactType<AppButton>()?.key;
}

ButtonStyleButton _button(WidgetTester tester, String key) =>
    tester.widget<ButtonStyleButton>(
      find.descendant(
        of: find.byKey(Key(key)),
        matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
      ),
    );

void main() {
  testWidgets('off: explains what changes, offers 5-minute default', (
    tester,
  ) async {
    await _show(tester, _FakeCollection());
    expect(find.text('Background collection is off.'), findsOneWidget);
    final explanation = _text(tester, 'background-explanation');
    expect(explanation, contains('apply immediately'));
    expect(explanation, contains('not part of Save settings'));
    expect(explanation, contains('Codex config.toml'));
    expect(explanation, contains('Claude Code settings.json'));
    expect(explanation, contains('backup is kept'));
    expect(explanation, contains('chained'));
    expect(explanation, contains('restored'));
    expect(explanation, contains('scheduled task'));
    expect(_text(tester, 'background-codex-state'), 'Not installed');
    expect(_text(tester, 'background-schedule-state'), 'Not scheduled');
    expect(find.text('Every 5 minutes'), findsOneWidget);
    await tester.tap(find.byKey(const Key('background-interval')));
    await tester.pumpAndSettle();
    for (final minutes in [5, 15, 30, 60]) {
      expect(find.text('Every $minutes minutes'), findsWidgets);
    }
    expect(find.text('Every 120 minutes'), findsNothing);
  });

  testWidgets('installing shows progress, announces it and keeps focus', (
    tester,
  ) async {
    final collection = _FakeCollection()..gate = Completer<void>();
    final announcer = await _show(tester, collection);
    await tester.tap(find.byKey(const Key('background-codex-install')));
    await tester.pump();
    expect(
      _text(tester, 'background-message'),
      'Installing Codex notify hook…',
    );
    expect(announcer.messages.last, 'Installing Codex notify hook…');
    collection.gate!.complete();
    await tester.pumpAndSettle();
    expect(announcer.messages, [
      'Installing Codex notify hook…',
      'Codex notify hook installed.',
    ]);
    expect(_text(tester, 'background-codex-state'), 'Installed');
    expect(
      find.text(
        'Background collection is partly on: '
        'Claude Code hooks not installed; the periodic scan is not scheduled.',
      ),
      findsOneWidget,
    );
    // The Install button is gone; focus moves to the row's Remove button.
    expect(_focusedButton(), const Key('background-codex-remove'));
  });

  testWidgets('removing restores focus to Install and says what happened', (
    tester,
  ) async {
    final collection = _FakeCollection(codex: HookInstallState.installed);
    final announcer = await _show(tester, collection);
    await tester.tap(find.byKey(const Key('background-codex-remove')));
    await tester.pumpAndSettle();
    expect(collection.calls, ['remove codex']);
    expect(_text(tester, 'background-codex-state'), 'Not installed');
    expect(
      announcer.messages.last,
      'Codex notify hook removed. The previous hook configuration was restored.',
    );
    expect(_focusedButton(), const Key('background-codex-install'));
    collection.restores = false;
    await tester.tap(find.byKey(const Key('background-codex-install')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('background-codex-remove')));
    await tester.pumpAndSettle();
    expect(announcer.messages.last, 'Codex notify hook removed.');
  });

  testWidgets('focus survives the schedule row and refresh', (tester) async {
    final collection = _FakeCollection();
    await _show(tester, collection);
    await tester.tap(find.byKey(const Key('background-schedule-install')));
    await tester.pumpAndSettle();
    expect(_focusedButton(), const Key('background-schedule-install'));
    await tester.tap(find.byKey(const Key('background-schedule-remove')));
    await tester.pumpAndSettle();
    expect(_focusedButton(), const Key('background-schedule-install'));
    await tester.tap(find.byKey(const Key('background-refresh')));
    await tester.pumpAndSettle();
    expect(_focusedButton(), const Key('background-refresh'));
  });

  testWidgets('a failure names the action and returns focus to its button', (
    tester,
  ) async {
    final collection = _FakeCollection()..failWith = 'Access is denied.';
    final announcer = await _show(tester, collection);
    await tester.tap(find.byKey(const Key('background-schedule-install')));
    await tester.pumpAndSettle();
    expect(
      announcer.messages.last,
      'Could not set the periodic scan. Access is denied.',
    );
    expect(_text(tester, 'background-message'), announcer.messages.last);
    expect(_text(tester, 'background-schedule-state'), 'Not scheduled');
    expect(_focusedButton(), const Key('background-schedule-install'));
    await tester.tap(find.byKey(const Key('background-claude-install')));
    await tester.pumpAndSettle();
    expect(
      announcer.messages.last,
      'Could not install Claude Code hooks. Access is denied.',
    );
  });

  testWidgets(
    'the interval choice is pending until applied and survives refresh',
    (tester) async {
      final collection = _FakeCollection(
        schedule: const ScheduledScanState(installed: true, intervalMinutes: 5),
      );
      await _show(tester, collection);
      expect(
        find.byKey(const Key('background-interval-pending')),
        findsNothing,
      );
      await tester.tap(find.byKey(const Key('background-interval')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Every 30 minutes').last);
      await tester.pumpAndSettle();
      expect(
        find.text('Not applied yet. Press Update schedule.'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('background-refresh')));
      await tester.pumpAndSettle();
      expect(
        find.text('Not applied yet. Press Update schedule.'),
        findsOneWidget,
      );
      expect(find.text('Every 30 minutes'), findsOneWidget);
      await tester.tap(find.byKey(const Key('background-schedule-install')));
      await tester.pumpAndSettle();
      expect(collection.calls, ['schedule 30']);
      expect(
        find.byKey(const Key('background-interval-pending')),
        findsNothing,
      );
      expect(
        _text(tester, 'background-schedule-state'),
        'Scheduled every 30 minutes; has not run yet',
      );
    },
  );

  testWidgets('a failed last run needs attention, a running one does not', (
    tester,
  ) async {
    final collection = _FakeCollection(
      codex: HookInstallState.installed,
      claude: HookInstallState.installed,
      schedule: ScheduledScanState(
        installed: true,
        intervalMinutes: 5,
        lastRun: DateTime(2026, 9, 30, 20, 14, 44),
        lastResult: 3,
      ),
      scan: '2026-09-30T18:14:44.000Z',
    );
    await _show(tester, collection);
    expect(
      _text(tester, 'background-summary'),
      'Background collection needs attention: '
      'the last scheduled scan failed (code 3).',
    );
    expect(
      _text(tester, 'background-schedule-state'),
      'Scheduled every 5 minutes; last ran 2026-09-30 20:14, '
      'failed with code 3',
    );
    collection.schedule = ScheduledScanState(
      installed: true,
      intervalMinutes: 5,
      lastRun: DateTime(2026, 9, 30, 20, 14, 44),
      lastResult: 267009,
    );
    await tester.tap(find.byKey(const Key('background-refresh')));
    await tester.pumpAndSettle();
    expect(_text(tester, 'background-summary'), 'Background collection is on.');
    expect(
      _text(tester, 'background-schedule-state'),
      'Scheduled every 5 minutes; running now',
    );
  });

  testWidgets('every timestamp is one local format', (tester) async {
    final collection = _FakeCollection(scan: '2026-09-30T18:14:44.000Z');
    await _show(tester, collection);
    final expected = BackgroundCollectionPanel.formatLocal(
      DateTime.parse('2026-09-30T18:14:44Z'),
    );
    expect(find.text('Last scan finished: $expected'), findsOneWidget);
    expect(find.text('Last session collected: $expected'), findsOneWidget);
    expect(expected, matches(RegExp(r'^\d{4}-\d\d-\d\d \d\d:\d\d$')));
    expect(BackgroundCollectionPanel.formatStored(null), 'Never');
    expect(BackgroundCollectionPanel.formatStored('not a date'), 'Never');
  });

  testWidgets('a broken configuration shows its path with copy and open', (
    tester,
  ) async {
    final collection = _FakeCollection(
      claude: HookInstallState.error,
      claudeDetail: 'invalid Claude JSON; repair configuration before setup',
      codex: HookInstallState.outdated,
    );
    final opened = <String>[];
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final announcer = await _show(
      tester,
      collection,
      onOpenFolder: (folder) async => opened.add(folder),
    );
    expect(
      _text(tester, 'background-summary'),
      startsWith('Background collection needs attention: '),
    );
    expect(
      _text(tester, 'background-claude-state'),
      'Needs attention: invalid Claude JSON; repair configuration before setup',
    );
    expect(
      _text(tester, 'background-claude-path'),
      r'Configuration file: C:\Users\a\.claude\settings.json',
    );
    expect(find.byKey(const Key('background-claude-install')), findsNothing);
    expect(find.byKey(const Key('background-claude-remove')), findsNothing);
    expect(
      _text(tester, 'background-codex-state'),
      'Out of date. Update to fix.',
    );
    expect(find.text('Update Codex notify hook'), findsOneWidget);
    await tester.tap(find.byKey(const Key('background-claude-copy-path')));
    await tester.pumpAndSettle();
    expect(copied, [r'C:\Users\a\.claude\settings.json']);
    expect(announcer.messages.last, 'Path copied.');
    await tester.tap(find.byKey(const Key('background-claude-open-folder')));
    await tester.pumpAndSettle();
    expect(opened, [r'C:\Users\a\.claude']);
  });

  testWidgets('an unsupported scheduler shows a plain statement', (
    tester,
  ) async {
    await _show(tester, _FakeCollection(supported: false));
    expect(
      _text(tester, 'background-schedule-state'),
      'Not available on this operating system yet.',
    );
    expect(find.byKey(const Key('background-schedule-install')), findsNothing);
    expect(find.byKey(const Key('background-interval')), findsNothing);
  });

  testWidgets('a status failure clears stale rows and retry recovers', (
    tester,
  ) async {
    final collection = _FakeCollection(codex: HookInstallState.installed);
    await _show(tester, collection);
    expect(find.byKey(const Key('background-codex-state')), findsOneWidget);
    collection.statusFailure = const BackgroundCollectionException(
      'The session collector could not be started.',
    );
    await tester.tap(find.byKey(const Key('background-refresh')));
    await tester.pumpAndSettle();
    expect(
      _text(tester, 'background-summary'),
      'Status unavailable: The session collector could not be started.',
    );
    expect(find.byKey(const Key('background-codex-state')), findsNothing);
    expect(find.byKey(const Key('background-codex-remove')), findsNothing);
    collection.statusFailure = null;
    await tester.tap(find.byKey(const Key('background-refresh')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('background-codex-state')), findsOneWidget);
  });

  testWidgets('buttons are disabled while a change runs', (tester) async {
    final collection = _FakeCollection()..gate = Completer<void>();
    await _show(tester, collection);
    await tester.tap(find.byKey(const Key('background-codex-install')));
    await tester.pump();
    expect(_button(tester, 'background-claude-install').onPressed, isNull);
    collection.gate!.complete();
    await tester.pumpAndSettle();
    expect(_button(tester, 'background-claude-install').onPressed, isNotNull);
  });

  testWidgets(
    'buttons stay disabled through the whole change, refresh included',
    (tester) async {
      final collection = _FakeCollection();
      await _show(tester, collection);
      collection.statusGate = Completer<void>();
      await tester.tap(find.byKey(const Key('background-codex-install')));
      await tester.pump();
      await tester.pump();
      // The change itself is done and the status is being re-read.
      expect(collection.calls, ['install codex']);
      expect(_button(tester, 'background-claude-install').onPressed, isNull);
      expect(_button(tester, 'background-refresh').onPressed, isNull);
      collection.statusGate!.complete();
      await tester.pumpAndSettle();
      expect(_button(tester, 'background-claude-install').onPressed, isNotNull);
    },
  );

  testWidgets('focus falls back to Refresh when the target button is gone', (
    tester,
  ) async {
    final collection = _FakeCollection()..failWith = 'Access is denied.';
    await _show(tester, collection);
    collection.statusFailure = const BackgroundCollectionException('Down.');
    await tester.tap(find.byKey(const Key('background-schedule-install')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('background-schedule-install')), findsNothing);
    expect(_focusedButton(), const Key('background-refresh'));
  });

  testWidgets('the pending-interval line is announced as a live region', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final collection = _FakeCollection(
      schedule: const ScheduledScanState(installed: true, intervalMinutes: 5),
    );
    await _show(tester, collection);
    await tester.tap(find.byKey(const Key('background-interval')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Every 15 minutes').last);
    await tester.pumpAndSettle();
    final pending = tester.getSemantics(
      find.byKey(const Key('background-interval-pending')),
    );
    expect(pending.flagsCollection.isLiveRegion, isTrue);
    expect(pending.label, 'Not applied yet. Press Update schedule.');
    semantics.dispose();
  });

  testWidgets('a folder that cannot be opened is announced', (tester) async {
    final collection = _FakeCollection(
      claude: HookInstallState.error,
      claudeDetail: 'invalid Claude JSON',
    );
    final announcer = await _show(
      tester,
      collection,
      onOpenFolder: (_) async => throw const FileSystemException('nope'),
    );
    await tester.tap(find.byKey(const Key('background-claude-open-folder')));
    await tester.pumpAndSettle();
    expect(announcer.messages.last, 'Could not open the folder.');
    expect(_text(tester, 'background-message'), 'Could not open the folder.');
  });

  testWidgets('a stopped run reads as stopped, not failed', (tester) async {
    final collection = _FakeCollection(
      codex: HookInstallState.installed,
      claude: HookInstallState.installed,
      schedule: ScheduledScanState(
        installed: true,
        intervalMinutes: 5,
        lastRun: DateTime(2026, 9, 30, 20, 14),
        lastResult: 267014,
      ),
    );
    await _show(tester, collection);
    expect(_text(tester, 'background-summary'), 'Background collection is on.');
    expect(
      _text(tester, 'background-schedule-state'),
      'Scheduled every 5 minutes; last ran 2026-09-30 20:14, stopped',
    );
  });

  testWidgets('keyboard: tab reaches a button and Enter activates it', (
    tester,
  ) async {
    final collection = _FakeCollection();
    await _show(tester, collection);
    var reached = false;
    for (var i = 0; i < 10 && !reached; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      reached = _focusedButton() == const Key('background-codex-install');
    }
    expect(reached, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(collection.calls, ['install codex']);
    // Keyboard users keep their place: focus is on Remove, so Enter or Space
    // would act on the button they are looking at.
    expect(_focusedButton(), const Key('background-codex-remove'));
  });

  testWidgets('semantics: live summary, named buttons and interval control', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final collection = _FakeCollection(codex: HookInstallState.installed);
    await _show(tester, collection);
    final summary = tester.getSemantics(
      find.byKey(const Key('background-summary')),
    );
    expect(
      summary.label,
      'Background collection is partly on: Claude Code hooks not installed; '
      'the periodic scan is not scheduled.',
    );
    expect(summary.flagsCollection.isLiveRegion, isTrue);
    final remove = tester.getSemantics(
      find.byKey(const Key('background-codex-remove')),
    );
    expect(remove.label, contains('Remove Codex notify hook'));
    expect(remove.flagsCollection.isButton, isTrue);
    expect(remove.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    final install = tester.getSemantics(
      find.byKey(const Key('background-claude-install')),
    );
    expect(install.label, contains('Install Claude Code hooks'));
    final interval = tester.getSemantics(
      find.bySemanticsLabel(RegExp('Periodic scan interval')),
    );
    expect(interval.label, contains('Periodic scan interval'));
    expect(interval.label, contains('Every 5 minutes'));
    expect(interval.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    final message = tester.getSemantics(
      find.byKey(const Key('background-message')),
    );
    expect(message.flagsCollection.isLiveRegion, isTrue);
    semantics.dispose();
  });

  testWidgets('a narrow window stacks each row instead of overflowing', (
    tester,
  ) async {
    await _show(tester, _FakeCollection(), width: 560);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('background-codex-install')), findsOneWidget);
  });

  testWidgets('the settings screen hides the section without a collector', (
    tester,
  ) async {
    await tester.pumpWidget(MaterialApp(home: SettingsScreen()));
    expect(find.text('Background collection'), findsNothing);
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(backgroundCollection: _FakeCollection()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Background collection'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Background collection'), findsOneWidget);
    expect(find.text('Background collection is off.'), findsOneWidget);
  });

  // Headless screenshots for the UX review. Set CXV_EVIDENCE_DIR to write them.
  final evidenceDir = Platform.environment['CXV_EVIDENCE_DIR'];
  testWidgets(
    'evidence: panel screenshots per state',
    skip: evidenceDir == null,
    (tester) async {
      await tester.runAsync(() async {
        final loader = FontLoader('Segoe UI');
        loader.addFont(
          File(
            r'C:\Windows\Fonts\segoeui.ttf',
          ).readAsBytes().then((b) => ByteData.view(b.buffer)),
        );
        await loader.load();
      });
      Future<void> shoot(
        String name,
        _FakeCollection collection, {
        Brightness brightness = Brightness.light,
        double width = 1100,
        Future<void> Function()? act,
      }) async {
        final key = GlobalKey();
        tester.view.physicalSize = Size(width, 760);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: MaterialApp(
              theme: ThemeData(
                brightness: brightness,
                fontFamily: 'Segoe UI',
                colorSchemeSeed: Colors.blueGrey,
              ),
              home: Scaffold(
                body: Padding(
                  padding: const EdgeInsets.all(24),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Settings / Background collection',
                          style: TextStyle(fontSize: 20),
                        ),
                        const SizedBox(height: 12),
                        BackgroundCollectionPanel(
                          collection: collection,
                          onOpenFolder: (_) async {},
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await act?.call();
        await tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject() as RenderRepaintBoundary;
          final image = await boundary.toImage();
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '$evidenceDir/$name.png',
          ).writeAsBytes(data!.buffer.asUint8List());
        });
      }

      final ran = DateTime(2026, 9, 30, 20, 14, 44);
      const scan = '2026-09-30T18:14:44.000Z';
      await shoot('background-off', _FakeCollection());
      await shoot(
        'background-installed',
        _FakeCollection(
          codex: HookInstallState.installed,
          claude: HookInstallState.installed,
          schedule: ScheduledScanState(
            installed: true,
            intervalMinutes: 5,
            lastRun: ran,
            lastResult: 0,
          ),
          scan: scan,
        ),
      );
      await shoot(
        'background-partial',
        _FakeCollection(
          codex: HookInstallState.installed,
          claude: HookInstallState.outdated,
          schedule: ScheduledScanState(
            installed: true,
            intervalMinutes: 15,
            lastRun: ran,
            lastResult: 0,
          ),
          scan: scan,
        ),
        act: () async {
          await tester.tap(find.byKey(const Key('background-interval')));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Every 30 minutes').last);
          await tester.pumpAndSettle();
        },
      );
      await shoot(
        'background-attention-failed-run',
        _FakeCollection(
          codex: HookInstallState.installed,
          claude: HookInstallState.installed,
          schedule: ScheduledScanState(
            installed: true,
            intervalMinutes: 5,
            lastRun: ran,
            lastResult: 3,
          ),
          scan: scan,
        ),
      );
      await shoot(
        'background-error-config-path',
        _FakeCollection(
          codex: HookInstallState.installed,
          claude: HookInstallState.error,
          claudeDetail:
              'invalid Claude JSON; repair configuration before setup',
        ),
      );
      await shoot(
        'background-focus-after-install',
        _FakeCollection(),
        act: () async {
          await tester.tap(find.byKey(const Key('background-codex-install')));
          await tester.pumpAndSettle();
        },
      );
      await shoot(
        'background-keyboard-focus-ring',
        _FakeCollection(),
        act: () async {
          // Keyboard highlight mode: the ring shows on the surviving button.
          FocusManager.instance.highlightStrategy =
              FocusHighlightStrategy.alwaysTraditional;
          addTearDown(
            () => FocusManager.instance.highlightStrategy =
                FocusHighlightStrategy.automatic,
          );
          await tester.tap(find.byKey(const Key('background-codex-install')));
          await tester.pumpAndSettle();
          expect(_focusedButton(), const Key('background-codex-remove'));
        },
      );
      await shoot(
        'background-narrow',
        _FakeCollection(
          codex: HookInstallState.installed,
          claude: HookInstallState.notInstalled,
        ),
        width: 560,
      );
      await shoot(
        'background-unsupported-dark',
        _FakeCollection(codex: HookInstallState.installed, supported: false),
        brightness: Brightness.dark,
      );
    },
  );
}
