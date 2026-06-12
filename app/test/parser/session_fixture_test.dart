import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'valid Windows and WSL session fixtures are loadable JSON objects',
    () async {
      for (final fixture in [
        _fixture('sample_windows_session.json'),
        _fixture('sample_wsl_session.json'),
      ]) {
        final decoded = jsonDecode(await fixture.readAsString());

        expect(decoded, isA<Map<String, Object?>>());
        expect(decoded['session_id'], isA<String>());
        expect(decoded['source_type'], anyOf('windows', 'wsl'));
        expect(decoded['messages'], isA<List<Object?>>());
      }
    },
  );

  test('unknown-message fixture contains an unknown message type', () async {
    final decoded =
        jsonDecode(
              await _fixture('unknown_message_session.json').readAsString(),
            )
            as Map<String, Object?>;

    final messages = decoded['messages'] as List<Object?>;
    expect(
      messages.cast<Map<String, Object?>>().map((message) => message['type']),
      contains('future_codex_event'),
    );
  });

  test('malformed fixture is present but not valid JSON', () async {
    expect(
      () => jsonDecode(_fixture('malformed_session.json').readAsStringSync()),
      throwsA(isA<FormatException>()),
    );
  });
}

File _fixture(String name) {
  return File('../samples/sessions/$name');
}
