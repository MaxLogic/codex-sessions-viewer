import 'dart:io';

import 'package:codex_sessions_viewer/src/platform/application_working_directory.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('uses the executable directory as the process working directory', () {
    final originalWorkingDirectory = Directory.current;
    final tempDir = Directory.systemTemp.createTempSync(
      'codex-viewer-working-directory-',
    );
    addTearDown(() {
      Directory.current = originalWorkingDirectory;
      tempDir.deleteSync(recursive: true);
    });
    final executableDirectory = Directory(
      p.join(tempDir.path, 'portable-release'),
    )..createSync();
    final unrelatedDirectory = Directory(
      p.join(tempDir.path, 'unrelated-working-directory'),
    )..createSync();
    Directory.current = unrelatedDirectory;

    useExecutableDirectoryAsWorkingDirectory(
      executablePath: p.join(
        executableDirectory.path,
        'codex_session_viewer.exe',
      ),
    );

    expect(p.equals(Directory.current.path, executableDirectory.path), isTrue);
  });

  test('finds the repository root above a development executable', () {
    final tempDir = Directory.systemTemp.createTempSync(
      'codex-viewer-repository-root-',
    );
    addTearDown(() => tempDir.deleteSync(recursive: true));
    File(
      p.join(tempDir.path, 'app', 'pubspec.yaml'),
    ).createSync(recursive: true);
    Directory(p.join(tempDir.path, 'sql')).createSync();
    final executablePath = p.join(
      tempDir.path,
      'app',
      'build',
      'windows',
      'x64',
      'runner',
      'Debug',
      'codex_sessions_viewer.exe',
    );

    final repositoryRoot = findDevelopmentRepositoryRoot(
      executablePath: executablePath,
    );

    expect(repositoryRoot, isNotNull);
    expect(p.equals(repositoryRoot!.path, tempDir.path), isTrue);
  });
}
