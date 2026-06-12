enum SessionSourceType { windows, wsl }

class CodexPathMapper {
  const CodexPathMapper({
    required this.wslDistro,
    required this.wslLinuxHome,
    required this.wslUncRoot,
  });

  final String wslDistro;
  final String wslLinuxHome;
  final String wslUncRoot;

  MappedSessionPath mapWindowsPath(String path) {
    return MappedSessionPath(
      sourceType: SessionSourceType.windows,
      displayPath: path,
      sourceFilePath: path,
      sourceFileUncPath: null,
      platformPath: path,
      normalizedPathKeys: {normalizePathKey(path)},
    );
  }

  MappedSessionPath mapWslLinuxPath(String linuxPath) {
    final normalizedLinuxPath = _normalizeLinuxPath(linuxPath);
    final uncPath = _linuxToUnc(normalizedLinuxPath);
    final windowsAlias = _mntToWindowsPath(normalizedLinuxPath);
    return MappedSessionPath(
      sourceType: SessionSourceType.wsl,
      displayPath: normalizedLinuxPath,
      sourceFilePath: windowsAlias ?? uncPath,
      sourceFileUncPath: uncPath,
      platformPath: normalizedLinuxPath,
      normalizedPathKeys: {
        normalizePathKey(normalizedLinuxPath),
        normalizePathKey(uncPath),
        if (windowsAlias != null) normalizePathKey(windowsAlias),
      },
    );
  }

  MappedSessionPath mapWslUncPath(String uncPath) {
    final linuxPath = _uncToLinux(uncPath);
    final windowsAlias = _mntToWindowsPath(linuxPath);
    return MappedSessionPath(
      sourceType: SessionSourceType.wsl,
      displayPath: linuxPath,
      sourceFilePath: windowsAlias ?? uncPath,
      sourceFileUncPath: uncPath,
      platformPath: linuxPath,
      normalizedPathKeys: {
        normalizePathKey(linuxPath),
        normalizePathKey(uncPath),
        if (windowsAlias != null) normalizePathKey(windowsAlias),
      },
    );
  }

  String toWindowsExplorerPath(String linuxPath) {
    final normalized = _normalizeLinuxPath(linuxPath);
    final windowsAlias = _mntToWindowsPath(normalized);
    if (windowsAlias != null) {
      return windowsAlias;
    }
    return _linuxToUnc(normalized);
  }

  String _linuxToUnc(String linuxPath) {
    final root = _trimTrailingSlash(wslUncRoot.replaceAll('/', r'\'));
    final withoutLeadingSlash = _normalizeLinuxPath(
      linuxPath,
    ).replaceFirst(RegExp(r'^/+'), '');
    return '$root\\${withoutLeadingSlash.replaceAll('/', r'\')}';
  }

  String _uncToLinux(String uncPath) {
    final normalizedRoot = _trimTrailingSlash(
      wslUncRoot.replaceAll('/', r'\').toLowerCase(),
    );
    final normalizedUnc = uncPath.replaceAll('/', r'\');
    final lowerUnc = _trimTrailingSlash(normalizedUnc.toLowerCase());
    if (lowerUnc == normalizedRoot) {
      return '/';
    }
    if (lowerUnc.startsWith('$normalizedRoot\\')) {
      final relative = normalizedUnc.substring(normalizedRoot.length + 1);
      return '/${relative.replaceAll(r'\', '/')}';
    }
    final uncPrefix = RegExp(
      r'^\\\\wsl(?:\.localhost)?\\[^\\]+\\',
      caseSensitive: false,
    );
    return '/${normalizedUnc.replaceFirst(uncPrefix, '').replaceAll(r'\', '/')}';
  }
}

class MappedSessionPath {
  const MappedSessionPath({
    required this.sourceType,
    required this.displayPath,
    required this.sourceFilePath,
    required this.sourceFileUncPath,
    required this.platformPath,
    required this.normalizedPathKeys,
  });

  final SessionSourceType sourceType;
  final String displayPath;
  final String sourceFilePath;
  final String? sourceFileUncPath;
  final String platformPath;
  final Set<String> normalizedPathKeys;
}

String normalizePathKey(String path) {
  var value = path.trim().replaceAll(r'\', '/').toLowerCase();
  value = value.replaceAll(RegExp('/+'), '/');
  final wslMatch = RegExp(
    r'^/wsl(?:\.localhost)?/[^/]+(/.*)?$',
    caseSensitive: false,
  ).firstMatch(value);
  if (wslMatch != null) {
    value = wslMatch.group(1) ?? '/';
  }
  value = value.replaceFirstMapped(RegExp(r'^([a-z]):'), (match) {
    return '${match.group(1)}:';
  });
  if (value.length > 1 && value.endsWith('/')) {
    value = value.substring(0, value.length - 1);
  }
  return value;
}

bool matchesAnyPathPattern(
  Iterable<String> normalizedKeys,
  Iterable<String> patterns,
) {
  final keys = normalizedKeys.toSet();
  for (final pattern in patterns) {
    final normalizedPattern = normalizePathKey(
      _expandTrailingSlashPattern(pattern),
    );
    final regex = _wildcardRegex(normalizedPattern);
    if (keys.any(regex.hasMatch)) {
      return true;
    }
  }
  return false;
}

String _expandTrailingSlashPattern(String pattern) {
  final trimmed = pattern.trim();
  if (trimmed.endsWith(r'\') || trimmed.endsWith('/')) {
    return '$trimmed*';
  }
  return trimmed;
}

String? _mntToWindowsPath(String linuxPath) {
  final mntMatch = RegExp(r'^/mnt/([a-zA-Z])(?:/(.*))?$').firstMatch(linuxPath);
  if (mntMatch == null) {
    return null;
  }
  final drive = mntMatch.group(1)!.toUpperCase();
  final rest = mntMatch.group(2);
  if (rest == null || rest.isEmpty) {
    return '$drive:\\';
  }
  return '$drive:\\${rest.replaceAll('/', r'\')}';
}

RegExp _wildcardRegex(String pattern) {
  final buffer = StringBuffer('^');
  for (final codeUnit in pattern.codeUnits) {
    final char = String.fromCharCode(codeUnit);
    if (char == '*') {
      buffer.write('.*');
    } else {
      buffer.write(RegExp.escape(char));
    }
  }
  buffer.write(r'$');
  return RegExp(buffer.toString());
}

String _normalizeLinuxPath(String path) {
  var value = path.trim().replaceAll(r'\', '/');
  value = value.replaceAll(RegExp('/+'), '/');
  if (!value.startsWith('/')) {
    value = '/$value';
  }
  if (value.length > 1 && value.endsWith('/')) {
    value = value.substring(0, value.length - 1);
  }
  return value;
}

String _trimTrailingSlash(String value) {
  var result = value;
  while (result.length > 1 && (result.endsWith(r'\') || result.endsWith('/'))) {
    result = result.substring(0, result.length - 1);
  }
  return result;
}
