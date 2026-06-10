import 'package:flutter/material.dart';

class CodexSessionsViewerApp extends StatelessWidget {
  const CodexSessionsViewerApp({super.key});

  static const appTitle = 'Codex Session Viewer';
  static const nativeTitleBarEnabled = true;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: appTitle,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey),
        useMaterial3: true,
      ),
      home: const Scaffold(body: Center(child: Text(appTitle))),
    );
  }
}
