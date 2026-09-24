import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../tool/semantic_search_evaluation.dart';

void main() {
  test(
    'message citations survive appends, long text is bounded, tools excluded',
    () {
      final messages = <Map<String, Object>>[
        {'id': 'm1', 'role': 'user', 'text': 'abcde' * 200},
        {'id': 'm2', 'role': 'tool', 'text': 'noise' * 10000},
      ];
      final sessions = [
        {'id': 's1', 'source': 'codex', 'messages': messages},
      ];
      final before = chunkSessions(sessions);
      expect(before.length, 3);
      expect(before.every((c) => c.text.length <= 400), isTrue);
      messages.add({'id': 'm3', 'role': 'assistant', 'text': 'new message'});
      final after = chunkSessions(sessions);
      expect(
        after.take(3).map((c) => c.citation),
        before.map((c) => c.citation),
      );
      expect(after.take(3).map((c) => c.hash), before.map((c) => c.hash));
    },
  );

  test(
    'unchanged content is cached; content, model and dimensions invalidate',
    () async {
      final db = sqlite3.openInMemory();
      addTearDown(db.close);
      var calls = 0;
      Future<List<List<double>>> embed(List<String> values) async {
        calls += values.length;
        return values.map((_) => [1.0, 0.0]).toList();
      }

      final cancel = EvaluationCancellation();
      final index = EvaluationIndex(db, 'a@revision', 2, embed);
      await index.vectors(['old'], cancel);
      await index.vectors(['old', 'new'], cancel);
      expect(calls, 2);
      await EvaluationIndex(
        db,
        'b@revision',
        2,
        embed,
      ).vectors(['old'], cancel);
      expect(calls, 3);
      final changedDimension = EvaluationIndex(
        db,
        'a@revision',
        3,
        (texts) async => texts.map((_) => [1.0, 0.0, 0.0]).toList(),
      );
      expect(
        (await changedDimension.vectors(['old'], cancel)).single.length,
        3,
      );
      expect(db.select('SELECT COUNT(*) AS n FROM vectors').single['n'], 4);
    },
  );

  test(
    'semantic retrieval sees zero lexical candidates and enforces source',
    () {
      final chunks = [
        SearchChunk('one', 'm1', 0, 'codex', 'automobile repair'),
        SearchChunk('two', 'm2', 0, 'claude', 'engine maintenance'),
      ];
      expect(rank(chunks, 'vehicle fixing', 'lexical'), isEmpty);
      expect(
        rank(
          chunks,
          'vehicle fixing',
          'hybrid',
          vectors: [
            [1, 0],
            [0, 1],
          ],
          queryVector: [1, 0],
        ),
        isEmpty,
      );
      expect(
        rank(
          chunks,
          'vehicle fixing',
          'semantic',
          vectors: [
            [1, 0],
            [0, 1],
          ],
          queryVector: [1, 0],
        ).first.chunk.session,
        'one',
      );
      expect(
        rank(
          chunks,
          'vehicle fixing',
          'semantic',
          vectors: [
            [1, 0],
            [0, 1],
          ],
          queryVector: [1, 0],
          source: 'claude',
        ).single.chunk.session,
        'two',
      );
    },
  );

  test(
    'cancellation before and after embedding never commits partial vectors',
    () async {
      final db = sqlite3.openInMemory();
      addTearDown(db.close);
      final cancel = EvaluationCancellation()..cancelled = true;
      var called = false;
      final index = EvaluationIndex(db, 'model', 2, (texts) async {
        called = true;
        cancel.cancelled = true;
        return [
          [1, 0],
        ];
      });
      await expectLater(
        index.vectors(['x'], cancel),
        throwsA(isA<EvaluationCancelled>()),
      );
      expect(called, isFalse);
      cancel.cancelled = false;
      await expectLater(
        index.vectors(['x'], cancel),
        throwsA(isA<EvaluationCancelled>()),
      );
      expect(db.select('SELECT * FROM vectors'), isEmpty);
    },
  );

  test(
    'unavailable embedding preserves lexical results and bad vectors fail',
    () async {
      final db = sqlite3.openInMemory();
      addTearDown(db.close);
      final index = EvaluationIndex(
        db,
        'unavailable',
        2,
        (_) async => throw StateError('unavailable'),
      );
      await expectLater(
        index.vectors(['x'], EvaluationCancellation()),
        throwsStateError,
      );
      final chunks = [SearchChunk('s', 'm', 0, 'codex', 'sqlite transaction')];
      expect(rank(chunks, 'sqlite', 'semantic').single.chunk.session, 's');
      final bad = EvaluationIndex(
        db,
        'bad',
        2,
        (_) async => [
          [1],
        ],
      );
      await expectLater(
        bad.vectors(['x'], EvaluationCancellation()),
        throwsStateError,
      );
      expect(db.select('SELECT * FROM vectors'), isEmpty);
    },
  );
}
