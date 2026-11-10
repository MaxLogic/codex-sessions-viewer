import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/config/parsed_with_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

AppSettings settings(int preview) => AppSettings.fromTomlMap({
  'tool_output': {'max_tool_output_preview_chars': preview},
});

void main() {
  test('initializes once, compares parse inputs and persists scan values', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    db.execute(
      'create table app_metadata(key text primary key, value text not null, updated_at_utc text not null)',
    );
    final store = ParsedWithSettingsStore(db);
    final old = ParsedWithSettings.capture(settings(4000));
    final next = ParsedWithSettings.capture(settings(8000));
    expect(old.changesFrom(store.loadOrInitialize(old)), isEmpty);
    expect(next.changesFrom(store.loadOrInitialize(next)), [
      'Tool output preview length (tool_output.max_tool_output_preview_chars): changed from 4000 to 8000 characters.',
    ]);
    expect(old.changesFrom(store.loadOrInitialize(next)), isEmpty);
    store.record(next);
    expect(next.changesFrom(store.loadOrInitialize(old)), isEmpty);
    final nonParseChange = settings(
      8000,
    ).copyWith(ui: settings(8000).ui.copyWith(fontSize: 18));
    expect(
      ParsedWithSettings.capture(nonParseChange).changesFrom(next),
      isEmpty,
    );
  });

  test('metadata read, decode and write failures propagate', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    final store = ParsedWithSettingsStore(db);
    final current = ParsedWithSettings.capture(settings(4000));
    expect(
      () => store.loadOrInitialize(current),
      throwsA(isA<SqliteException>()),
    );
    db.execute(
      'create table app_metadata(key text primary key, value text not null, updated_at_utc text not null)',
    );
    db.execute('insert into app_metadata values (?, ?, ?)', [
      ParsedWithSettingsStore.metadataKey,
      'broken',
      'now',
    ]);
    expect(() => store.loadOrInitialize(current), throwsFormatException);
    db.execute('pragma query_only = on');
    expect(() => store.record(current), throwsA(isA<SqliteException>()));
  });
}
