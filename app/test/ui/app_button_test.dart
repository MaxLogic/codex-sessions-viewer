import 'package:codex_sessions_viewer/src/ui/widgets/app_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<List<String>> pump(
    WidgetTester tester, {
    required bool showIcons,
    required bool showText,
  }) async {
    final taps = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: ButtonAppearance(
          showIcons: showIcons,
          showText: showText,
          child: Scaffold(
            body: Center(
              child: AppButton.outlined(
                onPressed: () => taps.add('refresh'),
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh'),
              ),
            ),
          ),
        ),
      ),
    );
    return taps;
  }

  testWidgets('shows icon and text by default', (tester) async {
    await pump(tester, showIcons: true, showText: true);
    expect(find.byIcon(Icons.refresh), findsOneWidget);
    expect(find.text('Refresh'), findsOneWidget);
  });

  testWidgets('hides icons when icons are off', (tester) async {
    await pump(tester, showIcons: false, showText: true);
    expect(find.byIcon(Icons.refresh), findsNothing);
    expect(find.text('Refresh'), findsOneWidget);
  });

  testWidgets('an icon-only button keeps its label as tooltip and name', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final taps = await pump(tester, showIcons: true, showText: false);
    expect(find.text('Refresh'), findsNothing);
    expect(find.byIcon(Icons.refresh), findsOneWidget);
    expect(find.byTooltip('Refresh'), findsOneWidget);
    expect(
      tester.getSemantics(find.byType(OutlinedButton)),
      matchesSemantics(
        label: 'Refresh',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
        isFocusable: true,
        hasFocusAction: true,
      ),
    );
    await tester.tap(find.byIcon(Icons.refresh));
    expect(taps, ['refresh']);
    handle.dispose();
  });

  testWidgets('turning both off still shows the text', (tester) async {
    await pump(tester, showIcons: false, showText: false);
    expect(find.text('Refresh'), findsOneWidget);
    expect(find.byIcon(Icons.refresh), findsNothing);
  });
}
