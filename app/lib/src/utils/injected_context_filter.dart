bool isInjectedEnvironmentContextMessage(String content) {
  final trimmed = content.trim();
  if (_isInjectedAgentsInstructionsMessage(trimmed)) {
    return true;
  }
  if (!trimmed.startsWith('<environment_context>') ||
      !trimmed.endsWith('</environment_context>')) {
    return false;
  }
  final inner = trimmed.substring(
    '<environment_context>'.length,
    trimmed.length - '</environment_context>'.length,
  );
  return RegExp(
    r'<(current_date|timezone|filesystem|cwd|workspace_roots|permission_profile)\b',
  ).hasMatch(inner);
}

bool _isInjectedAgentsInstructionsMessage(String trimmed) {
  final lower = trimmed.toLowerCase();
  return lower.startsWith('# agents.md instructions') &&
      lower.contains('<instructions>') &&
      lower.contains('</instructions>');
}
