class SessionLabelFormatter {
  const SessionLabelFormatter._();

  static const unknown = 'Unknown';

  static String platform(String platformName) {
    return switch (platformName.trim().toLowerCase()) {
      'windows' => 'Windows',
      'wsl' => 'WSL',
      _ => unknown,
    };
  }

  static String sourceType(String? sourceType) {
    return switch (sourceType?.trim().toLowerCase()) {
      'windows' => 'Windows',
      'wsl' => 'WSL',
      _ => unknown,
    };
  }

  static String origin({
    required String? threadSource,
    required String? agentNickname,
  }) {
    final source = threadSource?.trim().toLowerCase();
    if (source == 'subagent') {
      final nickname = agentNickname?.trim() ?? '';
      return nickname.isEmpty ? 'Subagent' : 'Subagent: $nickname';
    }
    if (source == null || source.isEmpty || source == 'user') {
      return 'User';
    }
    return unknown;
  }

  static String provider(String? modelId) {
    final trimmed = modelId?.trim() ?? '';
    final slash = trimmed.indexOf('/');
    if (slash <= 0) {
      return unknown;
    }
    return _titleize(trimmed.substring(0, slash));
  }

  static String model(String? modelId) {
    final trimmed = modelId?.trim() ?? '';
    if (trimmed.isEmpty || trimmed.toLowerCase() == 'unknown') {
      return unknown;
    }
    final slash = trimmed.indexOf('/');
    final modelPart = slash >= 0 && slash + 1 < trimmed.length
        ? trimmed.substring(slash + 1)
        : trimmed;
    return _titleize(modelPart);
  }

  static String modelWithProvider(String? modelId) {
    final modelLabel = model(modelId);
    final providerLabel = provider(modelId);
    if (providerLabel == unknown || modelLabel == unknown) {
      return modelLabel;
    }
    return '$providerLabel / $modelLabel';
  }

  static List<String> modelLabels(Iterable<String> modelIds) {
    final labels = <String>{};
    for (final modelId in modelIds) {
      final label = modelWithProvider(modelId);
      if (label != unknown) {
        labels.add(label);
      }
    }
    return labels.toList(growable: false)..sort();
  }

  static List<String> providerLabels(Iterable<String> modelIds) {
    final labels = <String>{};
    for (final modelId in modelIds) {
      final label = provider(modelId);
      if (label != unknown) {
        labels.add(label);
      }
    }
    return labels.toList(growable: false)..sort();
  }

  static String _titleize(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return unknown;
    }
    return trimmed
        .split(RegExp(r'[-_\s]+'))
        .where((part) => part.isNotEmpty)
        .map(_titlePart)
        .join(' ');
  }

  static String _titlePart(String value) {
    final lower = value.toLowerCase();
    if (lower == 'openai') {
      return 'OpenAI';
    }
    if (lower == 'gpt') {
      return 'GPT';
    }
    if (lower == 'wsl') {
      return 'WSL';
    }
    if (value.length == 1) {
      return value.toUpperCase();
    }
    return '${value[0].toUpperCase()}${value.substring(1)}';
  }
}
