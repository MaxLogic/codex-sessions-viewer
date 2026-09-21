import 'dart:convert';

import 'package:codex_sessions_viewer/src/benchmark/usage_projection_benchmark.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('benchmark rejects invalid arguments instead of succeeding', () async {
    for (final arguments in [
      ['--events', '0'],
      ['--contexts', '-1'],
      ['--samples', '0'],
      ['--unknown'],
      ['--events'],
      ['--expected-hash', 'bad'],
    ]) {
      final output = StringBuffer();
      final errors = StringBuffer();
      expect(
        await runUsageProjectionBenchmarkCli(
          arguments,
          output: output,
          errors: errors,
        ),
        64,
        reason: arguments.toString(),
      );
      expect(errors.toString(), isNotEmpty);
    }
  });

  test(
    'synthetic benchmark measures production paths and rejects wrong hash',
    () async {
      final output = StringBuffer();
      final errors = StringBuffer();
      final arguments = ['--events', '48', '--contexts', '4', '--samples', '2'];
      expect(
        await runUsageProjectionBenchmarkCli(
          arguments,
          output: output,
          errors: errors,
        ),
        0,
        reason: errors.toString(),
      );
      final report = jsonDecode(output.toString()) as Map<String, dynamic>;
      final scale = (report['scales'] as List).single as Map<String, dynamic>;
      expect(scale['events'], 48);
      expect(scale['usedContexts'], 4);
      expect(scale['hashesMatch'], isTrue);
      expect(
        scale['enabledProjectBranchHash'],
        isNot(scale['projectBranchHash']),
      );
      for (final key in [
        'legacySummary',
        'projectedSummary',
        'legacyRemap',
        'contextRemap',
      ]) {
        final measurement = scale[key] as Map<String, dynamic>;
        expect(measurement['samplesMs'], hasLength(2));
        expect(measurement['statementCounts'], everyElement(greaterThan(0)));
      }
      expect(scale['contextRemap']['rawEventSqlExecutions'], 0);
      expect(scale['projectedSummary']['rawEventSqlExecutions'], 0);
      expect(scale['legacyRemap']['rawEventSqlExecutions'], greaterThan(0));
      // 12 of 48 events use the empty context; exactly 36 others change project
      // on each real mask enable/disable, through prepared statement execution.
      expect(scale['legacyRemap']['preparedStatementCounts'], [36, 36]);
      expect(scale['contextRemap']['preparedStatementCounts'], [0, 0]);
      expect(scale['projectedStorage']['objects'], isNotEmpty);
      expect(scale['projectedPlan'], isNotEmpty);
      final mismatchErrors = StringBuffer();
      expect(
        await runUsageProjectionBenchmarkCli(
          [...arguments, '--expected-hash', '0' * 64],
          output: StringBuffer(),
          errors: mismatchErrors,
        ),
        1,
      );
      expect(mismatchErrors.toString(), contains('hash mismatch'));
    },
  );
}
