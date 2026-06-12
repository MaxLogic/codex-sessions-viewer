import 'dart:io';

import 'package:codex_sessions_viewer/src/parser/session_format_analyzer.dart';

Future<void> main(List<String> args) async {
  final rootPath = _option(args, '--root') ?? '../samples/sessions';
  final noContent = args.contains('--no-content');
  if (!noContent) {
    stderr.writeln(
      'Refusing to run without --no-content; analysis output is schema-only.',
    );
    exitCode = 64;
    return;
  }

  final root = Directory(rootPath);
  final summary = await SessionFormatAnalyzer().analyzeRoot(root);
  stdout.writeln(summary.renderContentSafeReport());
}

String? _option(List<String> args, String name) {
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == name && i + 1 < args.length) {
      return args[i + 1];
    }
    if (arg.startsWith('$name=')) {
      return arg.substring(name.length + 1);
    }
  }
  return null;
}
