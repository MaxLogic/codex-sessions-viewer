import '../utils/injected_context_filter.dart';

/// Interpret Claude's whole-record local-command envelope only. Quoted tags
/// and ordinary slash commands are user text, not protocol envelopes.
String? firstInstruction(String body) {
  final text = body.trim();
  if (text.isEmpty || isInjectedEnvironmentContextMessage(text)) return null;
  if (RegExp(
    r'^<(local-command-caveat|local-command-stdout)>[\s\S]*</\1>$',
  ).hasMatch(text)) {
    return null;
  }
  final command = RegExp(
    r'^<command-name>([^<]*)</command-name>\s*'
    r'<command-message>[^<]*</command-message>\s*'
    r'<command-args>([\s\S]*)</command-args>$',
  ).firstMatch(text);
  if (command == null) return text;
  if (command.group(1)?.trim() != '/goal') return null;
  final instruction = command.group(2)!.trim();
  return instruction.isEmpty ? null : instruction;
}
