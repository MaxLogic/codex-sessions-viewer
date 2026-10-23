import 'dart:io';

import 'package:codex_sessions_viewer/src/scanner/resident_collector_client.dart';
import 'package:codex_sessions_viewer/src/scanner/collector_process.dart';
import 'package:codex_sessions_viewer/src/ui/widgets/collector_status.dart';
import 'package:codex_sessions_viewer/src/ui/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_collector_bridge.dart';

void main() {
  testWidgets('missing installation guidance has a visible high contrast edge', (
    tester,
  ) async {
    final client = ResidentCollectorClient(
      databaseFile: File('fixture.sqlite'),
      settingsFile: File('fixture.toml'),
      start: (exe, args) async =>
          throw ProcessException(exe, args, 'missing executable'),
    );
    final semantics = tester.ensureSemantics();
    const message =
        'Session collection could not start. Saved sessions are still shown. Reinstall Codex Sessions Viewer to restore session collection.';
    try {
      await tester.runAsync(
        () => expectLater(
          client.connect(),
          throwsA(isA<CollectorUnavailableException>()),
        ),
      );
      final theme = CodexAppTheme.themeData(CodexThemeMode.highContrastDark);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(body: CollectorStatus(client: client)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(message), findsOneWidget);
      expect(
        tester
            .getSemantics(find.bySemanticsLabel(message))
            .getSemanticsData()
            .flagsCollection
            .isLiveRegion,
        isTrue,
      );
      final band = tester.widget<Material>(find.byType(Material).last);
      expect(band.shape, isA<Border>());
      expect(
        (band.shape! as Border).top.color,
        theme.colorScheme.outlineVariant,
      );
      expect((band.shape! as Border).top.width, greaterThanOrEqualTo(1));
      // ignore: avoid_print
      print(
        'missing_installation_label="$message" live_region=true status_top_border=outlineVariant',
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(client.dispose);
      semantics.dispose();
    }
  });
  testWidgets(
    'quick connect is silent; recovery announces once without persistent text',
    (tester) async {
      final announcements = <Object?>[];
      tester.binding.defaultBinaryMessenger
          .setMockDecodedMessageHandler<Object?>(SystemChannels.accessibility, (
            message,
          ) async {
            announcements.add(message);
            return null;
          });
      late ScriptedBridge bridge;
      late ResidentCollectorClient client;
      await tester.runAsync(() async {
        bridge = ScriptedBridge();
        client = ResidentCollectorClient(
          databaseFile: File('fixture.sqlite'),
          settingsFile: File('fixture.toml'),
          start: (_, _) async {
            bridge.emit({'event': 'bridge', 'state': 'starting'});
            bridge.emit({'event': 'bridge', 'state': 'connected'});
            return bridge;
          },
        );
      });
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: CollectorStatus(client: client)),
          ),
        );
        await tester.runAsync(client.connect);
        await tester.pumpAndSettle();
        expect(find.text('Starting session collection…'), findsNothing);
        expect(announcements.toString(), isNot(contains('Starting')));
        await tester.runAsync(() async {
          bridge.emit({'event': 'bridge', 'state': 'reconnecting'});
          await Future<void>.delayed(Duration.zero);
        });
        await tester.pumpAndSettle();
        final reconnect = tester.getSemantics(
          find.bySemanticsLabel('Reconnecting to session collection…'),
        );
        expect(
          reconnect.getSemanticsData().flagsCollection.isLiveRegion,
          isTrue,
        );
        expect(
          tester.getSize(find.byType(Material).last).width,
          tester.view.physicalSize.width / tester.view.devicePixelRatio,
        );
        await tester.runAsync(() async {
          bridge.emit({'event': 'bridge', 'state': 'connected'});
          bridge.emit({'event': 'bridge', 'state': 'connected'});
          await Future<void>.delayed(Duration.zero);
        });
        await tester.pumpAndSettle();
        expect(find.text('Session collection reconnected.'), findsNothing);
        expect(
          announcements.where(
            (a) => a.toString().contains('Session collection reconnected.'),
          ),
          hasLength(1),
        );
        // ignore: avoid_print
        print(
          'recovery_announcement=$announcements reconnect_live_region=true persistent_recovery_text=false',
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(client.dispose);
        semantics.dispose();
        tester.binding.defaultBinaryMessenger
            .setMockDecodedMessageHandler<Object?>(
              SystemChannels.accessibility,
              null,
            );
      }
    },
  );

  testWidgets('slow connection exposes a single polite starting status', (
    tester,
  ) async {
    late ScriptedBridge bridge;
    late ResidentCollectorClient client;
    late Future<void> opening;
    await tester.runAsync(() async {
      bridge = ScriptedBridge();
      client = ResidentCollectorClient(
        databaseFile: File('fixture.sqlite'),
        settingsFile: File('fixture.toml'),
        start: (_, _) async => bridge,
      );
      opening = client.connect();
    });
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: CollectorStatus(client: client)),
        ),
      );
      expect(find.text('Starting session collection…'), findsNothing);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1100)),
      );
      await tester.pumpAndSettle();
      final node = tester.getSemantics(
        find.bySemanticsLabel('Starting session collection…'),
      );
      expect(node.getSemanticsData().flagsCollection.isLiveRegion, isTrue);
      // ignore: avoid_print
      print(
        'starting_label="${node.label}" live_region=true delayed_over_1s=true',
      );
      await tester.runAsync(() async {
        bridge.emit({'event': 'bridge', 'state': 'connected'});
        await opening;
      });
      await tester.pumpAndSettle();
      expect(find.text('Starting session collection…'), findsNothing);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(client.dispose);
      semantics.dispose();
    }
  });
}
