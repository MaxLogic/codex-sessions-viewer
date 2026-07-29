import 'dart:io';

import 'package:path/path.dart' as p;

Directory applicationExecutableDirectory({String? executablePath}) {
  final executable = File(executablePath ?? Platform.resolvedExecutable);
  return executable.absolute.parent;
}

void useExecutableDirectoryAsWorkingDirectory({String? executablePath}) {
  Directory.current = applicationExecutableDirectory(
    executablePath: executablePath,
  ).path;
}

Directory? findDevelopmentRepositoryRoot({String? executablePath}) {
  var candidate = applicationExecutableDirectory(
    executablePath: executablePath,
  );
  while (true) {
    final hasFlutterProject = File(
      p.join(candidate.path, 'app', 'pubspec.yaml'),
    ).existsSync();
    final hasSqlMigrations = Directory(
      p.join(candidate.path, 'sql'),
    ).existsSync();
    if (hasFlutterProject && hasSqlMigrations) {
      return candidate;
    }
    final parent = candidate.parent;
    if (p.equals(parent.path, candidate.path)) {
      return null;
    }
    candidate = parent;
  }
}
