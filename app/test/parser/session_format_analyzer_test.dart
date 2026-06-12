import 'dart:io';

import 'package:codex_sessions_viewer/src/parser/session_format_analyzer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'summarizes JSON and JSONL schema keys without content values',
    () async {
      final analyzer = SessionFormatAnalyzer();

      final summary = await analyzer.analyzeRoot(
        Directory('../samples/sessions'),
      );

      expect(summary.filesScanned, greaterThanOrEqualTo(5));
      expect(summary.filesMalformed, 2);
      expect(summary.malformedLines, 1);
      expect(summary.recordTypes.countFor('session_meta'), greaterThan(0));
      expect(summary.recordTypes.countFor('response_item'), greaterThan(0));
      expect(summary.recordTypes.countFor('future_record'), greaterThan(0));
      expect(
        summary.recordTypes.countFor('json_object_session'),
        greaterThan(0),
      );
      expect(summary.payloadKeys.countFor('id'), greaterThan(0));
      expect(summary.payloadKeys.countFor('cwd'), greaterThan(0));
      expect(summary.responseItemTypes.countFor('message'), greaterThan(0));
      expect(
        summary.responseItemTypes.countFor('function_call'),
        greaterThan(0),
      );
      expect(
        summary.responseItemTypes.countFor('future_payload'),
        greaterThan(0),
      );
      expect(summary.jsonObjectMessageTypes.countFor('user'), greaterThan(0));
      expect(summary.eventMessageTypes.countFor('token_count'), greaterThan(0));
      expect(summary.tokenUsageKeys.countFor('input_tokens'), greaterThan(0));
      expect(summary.tokenUsageKeys.countFor('output_tokens'), greaterThan(0));
      expect(
        summary.tokenUsageShapes
            .toJson()['event_msg.token_count.info.total_token_usage'],
        containsPair('input_tokens', 1),
      );
      expect(
        summary.tokenUsageShapes.toJson()['json_object.messages.usage'],
        containsPair('output_tokens', greaterThan(0)),
      );

      final json = summary.toContentSafeJson();
      final encoded = json.toString();
      expect(encoded, contains('record_types'));
      expect(encoded, isNot(contains('Open the viewer task list')));
      expect(encoded, isNot(contains('TASKS.md')));
      expect(encoded, isNot(contains(r'F:\projects')));
      expect(encoded, isNot(contains('42')));
    },
  );

  test(
    'counts malformed JSONL files once and malformed lines individually',
    () async {
      final temp = await Directory.systemTemp.createTemp('csv_format_test_');
      addTearDown(() => temp.delete(recursive: true));
      await File(
        '${temp.path}${Platform.pathSeparator}many_bad_lines.jsonl',
      ).writeAsString('''
{"type":"session_meta","payload":{"id":"ok"}}
[]
{"type":"response_item","payload":
''');

      final summary = await SessionFormatAnalyzer().analyzeRoot(temp);

      expect(summary.filesScanned, 1);
      expect(summary.filesMalformed, 1);
      expect(summary.malformedLines, 2);
      expect(summary.recordTypes.countFor('session_meta'), 1);
    },
  );

  test('renders a deterministic content-safe report', () async {
    final analyzer = SessionFormatAnalyzer();
    final summary = await analyzer.analyzeRoot(
      Directory('../samples/sessions'),
    );

    final report = summary.renderContentSafeReport();

    expect(report, contains('record_types'));
    expect(report, contains('payload_keys'));
    expect(report, contains('malformed_files'));
    expect(report, isNot(contains('Scan my Windows Codex sessions')));
    expect(report, isNot(contains('/home/pawel/projects')));
  });
}
