import 'package:codex_sessions_viewer/src/path_mapping/path_mapper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const mapper = CodexPathMapper(
    wslDistro: 'Ubuntu',
    wslLinuxHome: '/home/pawel',
    wslUncRoot: r'\\wsl.localhost\Ubuntu\',
  );

  test('keeps Windows display, file-access, and platform paths aligned', () {
    final mapped = mapper.mapWindowsPath(
      r'C:\Users\pawel\.codex\sessions\session.jsonl',
    );

    expect(mapped.sourceType, SessionSourceType.windows);
    expect(mapped.displayPath, r'C:\Users\pawel\.codex\sessions\session.jsonl');
    expect(
      mapped.sourceFilePath,
      r'C:\Users\pawel\.codex\sessions\session.jsonl',
    );
    expect(mapped.sourceFileUncPath, isNull);
    expect(
      mapped.platformPath,
      r'C:\Users\pawel\.codex\sessions\session.jsonl',
    );
  });

  test('maps WSL Linux paths to UNC file access and Linux platform paths', () {
    final mapped = mapper.mapWslLinuxPath(
      '/home/pawel/.codex/sessions/session.jsonl',
    );

    expect(mapped.sourceType, SessionSourceType.wsl);
    expect(mapped.displayPath, '/home/pawel/.codex/sessions/session.jsonl');
    expect(mapped.platformPath, '/home/pawel/.codex/sessions/session.jsonl');
    expect(
      mapped.sourceFileUncPath,
      r'\\wsl.localhost\Ubuntu\home\pawel\.codex\sessions\session.jsonl',
    );
    expect(mapped.sourceFilePath, mapped.sourceFileUncPath);
  });

  test('adds Windows aliases for WSL mnt session paths', () {
    final mapped = mapper.mapWslLinuxPath('/mnt/c/projects/test/session.jsonl');

    expect(mapped.sourceType, SessionSourceType.wsl);
    expect(mapped.displayPath, '/mnt/c/projects/test/session.jsonl');
    expect(mapped.platformPath, '/mnt/c/projects/test/session.jsonl');
    expect(mapped.sourceFilePath, r'C:\projects\test\session.jsonl');
    expect(
      mapped.sourceFileUncPath,
      r'\\wsl.localhost\Ubuntu\mnt\c\projects\test\session.jsonl',
    );
    expect(
      mapped.normalizedPathKeys,
      containsAll({
        '/mnt/c/projects/test/session.jsonl',
        'c:/projects/test/session.jsonl',
      }),
    );
    expect(
      matchesAnyPathPattern(mapped.normalizedPathKeys, [r'C:\projects\*']),
      isTrue,
    );
  });

  test('maps WSL UNC paths back to Linux platform paths', () {
    final mapped = mapper.mapWslUncPath(
      r'\\wsl.localhost\Ubuntu\home\pawel\.codex\sessions\session.jsonl',
    );

    expect(mapped.sourceType, SessionSourceType.wsl);
    expect(mapped.displayPath, '/home/pawel/.codex/sessions/session.jsonl');
    expect(mapped.platformPath, '/home/pawel/.codex/sessions/session.jsonl');
    expect(
      mapped.sourceFileUncPath,
      r'\\wsl.localhost\Ubuntu\home\pawel\.codex\sessions\session.jsonl',
    );
  });

  test('adds Windows aliases for WSL UNC mnt session paths', () {
    final mapped = mapper.mapWslUncPath(
      r'\\wsl.localhost\Ubuntu\mnt\c\projects\test\session.jsonl',
    );

    expect(mapped.sourceType, SessionSourceType.wsl);
    expect(mapped.displayPath, '/mnt/c/projects/test/session.jsonl');
    expect(mapped.platformPath, '/mnt/c/projects/test/session.jsonl');
    expect(mapped.sourceFilePath, r'C:\projects\test\session.jsonl');
    expect(
      mapped.sourceFileUncPath,
      r'\\wsl.localhost\Ubuntu\mnt\c\projects\test\session.jsonl',
    );
    expect(
      mapped.normalizedPathKeys,
      containsAll({
        '/mnt/c/projects/test/session.jsonl',
        'c:/projects/test/session.jsonl',
      }),
    );
  });

  test('maps WSL mnt paths to Windows Explorer drive paths', () {
    expect(
      mapper.toWindowsExplorerPath('/mnt/c/projects/test'),
      r'C:\projects\test',
    );
    expect(
      mapper.toWindowsExplorerPath('/home/pawel/.codex/sessions/foo.json'),
      r'\\wsl.localhost\Ubuntu\home\pawel\.codex\sessions\foo.json',
    );
  });

  test('normalizes path keys across Windows, Linux, and WSL UNC paths', () {
    expect(
      normalizePathKey(r'C:\\Users//pawel\\.codex'),
      'c:/users/pawel/.codex',
    );
    expect(
      normalizePathKey(r'\\wsl.localhost\Ubuntu\home\pawel\.codex'),
      '/home/pawel/.codex',
    );
    expect(normalizePathKey('/home//pawel/.codex'), '/home/pawel/.codex');
  });

  test(
    'matches multiple case-insensitive slash-normalized wildcard patterns',
    () {
      final keys = {
        normalizePathKey(r'C:\Users\pawel\.codex'),
        normalizePathKey('/home/pawel/.codex'),
        normalizePathKey(r'\\wsl.localhost\Ubuntu\home\pawel\.codex'),
      };

      expect(matchesAnyPathPattern(keys, [r'*PAWEL\\']), isTrue);
      expect(matchesAnyPathPattern(keys, ['/HOME/*/.codex']), isTrue);
      expect(
        matchesAnyPathPattern(keys, [r'*missing*', r'c:/users/*']),
        isTrue,
      );
      expect(matchesAnyPathPattern(keys, [r'*missing*']), isFalse);
    },
  );
}
