import 'package:codex_sessions_viewer/src/app/codex_sessions_viewer_app.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('launches a minimal app shell', (tester) async {
    await tester.pumpWidget(const CodexSessionsViewerApp());

    expect(find.text(CodexSessionsViewerApp.appTitle), findsOneWidget);
    expect(CodexSessionsViewerApp.nativeTitleBarEnabled, isTrue);
  });
}
