import 'dart:async';

import '../test/support/test_environment.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  await TestEnvironment.testMain(testMain);
}
