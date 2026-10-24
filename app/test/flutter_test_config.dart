import 'dart:async';

import 'support/test_environment.dart';

/// Runs before every test file in `test/`.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  await TestEnvironment.testMain(testMain);
}
