import 'database_connection.dart';

enum DatabaseGenerationState {
  legacy,
  building,
  ready,
  active,
  cleanupPending,
  complete,
  failed;

  String get wireName => switch (this) {
    cleanupPending => 'cleanup_pending',
    _ => name,
  };

  static DatabaseGenerationState parse(String value) => switch (value) {
    'cleanup_pending' => cleanupPending,
    _ => values.singleWhere(
      (state) => state.name == value,
      orElse: () =>
          throw StateError('Unknown database generation state: $value'),
    ),
  };
}

final class DatabaseGenerationRecord {
  const DatabaseGenerationRecord({
    required this.id,
    required this.sourceSchemaVersion,
    required this.targetSchemaVersion,
    required this.sourceFingerprint,
    required this.state,
  });

  final int id;
  final int sourceSchemaVersion;
  final int targetSchemaVersion;
  final String? sourceFingerprint;
  final DatabaseGenerationState state;
}

final class DatabaseGenerationRepository {
  DatabaseGenerationRepository(this.db, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final Database db;
  final DateTime Function() _clock;

  DatabaseGenerationRecord activeGeneration() {
    final row = db.select('''
      select generation.*
      from database_state state
      join database_generations generation
        on generation.id = state.active_usage_generation_id
      where state.id = 1
      ''').single;
    return _record(row);
  }

  DatabaseGenerationRecord createBuilding({
    required int sourceSchemaVersion,
    required int targetSchemaVersion,
    required String sourceFingerprint,
  }) {
    if (targetSchemaVersion < sourceSchemaVersion) {
      throw ArgumentError('Target schema version precedes the source version.');
    }
    db.execute(
      '''
      insert into database_generations (
        source_schema_version, target_schema_version, source_fingerprint,
        state, created_at_utc
      ) values (?, ?, ?, 'building', ?)
      ''',
      [
        sourceSchemaVersion,
        targetSchemaVersion,
        sourceFingerprint,
        _timestamp(_clock()),
      ],
    );
    return _read(db.lastInsertRowId);
  }

  void markReady(int generationId, {required String validationReportJson}) {
    db.execute(
      '''
      update database_generations
      set state = 'ready', validation_report_json = ?, error_message = null
      where id = ? and state = 'building'
      ''',
      [validationReportJson, generationId],
    );
    _requireOneChange('Generation is not in the building state.');
  }

  void activate(int generationId, {void Function()? beforeCommit}) {
    var transactionOpen = false;
    try {
      db.execute('begin immediate');
      transactionOpen = true;
      _activateInCurrentTransaction(generationId);
      beforeCommit?.call();
      db.execute('commit');
      transactionOpen = false;
    } on Object {
      if (transactionOpen && !db.autocommit) db.execute('rollback');
      rethrow;
    }
  }

  /// Only the storage/pointer statements run inside the interrupt section.
  /// Its exit must disarm interruption before completing or throwing, allowing
  /// this owner to safely commit or roll back the surrounding transaction.
  Future<void> activateInterruptibly(
    int generationId, {
    required Future<void> Function(void Function()) runAtomic,
  }) async {
    var transactionOpen = false;
    try {
      db.execute('begin immediate');
      transactionOpen = true;
      await runAtomic(() => _activateInCurrentTransaction(generationId));
      db.execute('commit');
      transactionOpen = false;
    } on Object {
      if (transactionOpen && !db.autocommit) db.execute('rollback');
      rethrow;
    }
  }

  void _activateInCurrentTransaction(int generationId) {
    final current = activeGeneration();
    final currentId = current.id;
    final target = _read(generationId);
    if (target.state != DatabaseGenerationState.ready) {
      throw StateError('Database generation is not ready for activation.');
    }
    if (currentId != generationId) {
      _switchUsageStorage(current, target);
      db.execute(
        "update database_generations set state = 'cleanup_pending' where id = ?",
        [currentId],
      );
      db.execute(
        '''
        update database_generations
        set state = 'active', activated_at_utc = ?
        where id = ?
        ''',
        [_timestamp(_clock()), generationId],
      );
      db.execute(
        '''
        update database_state
        set active_usage_generation_id = ?, updated_at_utc = ?
        where id = 1
        ''',
        [generationId, _timestamp(_clock())],
      );
    }
  }

  bool rollbackTo(int generationId) {
    var transactionOpen = false;
    try {
      db.execute('begin immediate');
      transactionOpen = true;
      final state = db
          .select('select * from database_state where id = 1')
          .single;
      if (state['normal_writes_resumed_at_utc'] != null) {
        db.execute('commit');
        transactionOpen = false;
        return false;
      }
      final currentId = state['active_usage_generation_id'] as int;
      final current = _read(currentId);
      final target = _read(generationId);
      if (target.state == DatabaseGenerationState.failed ||
          target.state == DatabaseGenerationState.building) {
        throw StateError('Rollback target is not a validated generation.');
      }
      if (currentId != generationId) {
        _switchUsageStorage(current, target);
        db.execute(
          "update database_generations set state = 'ready' where id = ?",
          [currentId],
        );
        db.execute(
          "update database_generations set state = 'active' where id = ?",
          [generationId],
        );
        db.execute(
          '''
          update database_state
          set active_usage_generation_id = ?, updated_at_utc = ?
          where id = 1
          ''',
          [generationId, _timestamp(_clock())],
        );
      }
      db.execute('commit');
      transactionOpen = false;
      return true;
    } on Object {
      if (transactionOpen && !db.autocommit) db.execute('rollback');
      rethrow;
    }
  }

  void markNormalWritesResumed() {
    final now = _timestamp(_clock());
    db.execute(
      '''
      update database_state
      set normal_writes_resumed_at_utc = coalesce(normal_writes_resumed_at_utc, ?),
          updated_at_utc = ?
      where id = 1
      ''',
      [now, now],
    );
  }

  /// Table/view identities and the active-generation pointer share one commit.
  /// Retain the legacy table until reopen verification, before writers resume.
  void _switchUsageStorage(
    DatabaseGenerationRecord current,
    DatabaseGenerationRecord target,
  ) {
    final fromContexts = current.targetSchemaVersion >= 16;
    final toContexts = target.targetSchemaVersion >= 16;
    if (fromContexts == toContexts) return;
    db.execute('drop view billable_usage_events');
    if (toContexts) {
      db.execute('alter table usage_events rename to usage_events_legacy');
      db.execute('alter table usage_events_next rename to usage_events');
      db.execute('''
        create view billable_usage_events as
        select e.*, c.effective_project_id as project_id
        from usage_events e join usage_path_contexts c on c.id = e.path_context_id
        where e.branch_scope = 'local'
      ''');
    } else {
      db.execute('alter table usage_events rename to usage_events_next');
      db.execute('alter table usage_events_legacy rename to usage_events');
      db.execute('''
        create view billable_usage_events as
        select * from usage_events where branch_scope = 'local'
      ''');
    }
  }

  DatabaseGenerationRecord _read(int id) {
    final rows = db.select('select * from database_generations where id = ?', [
      id,
    ]);
    if (rows.isEmpty) {
      throw StateError('Database generation $id does not exist.');
    }
    return _record(rows.single);
  }

  void _requireOneChange(String message) {
    final changes = db.select('select changes()').single.values.single as int;
    if (changes != 1) throw StateError(message);
  }
}

DatabaseGenerationRecord _record(Row row) => DatabaseGenerationRecord(
  id: row['id'] as int,
  sourceSchemaVersion: row['source_schema_version'] as int,
  targetSchemaVersion: row['target_schema_version'] as int,
  sourceFingerprint: row['source_fingerprint'] as String?,
  state: DatabaseGenerationState.parse(row['state'] as String),
);

String _timestamp(DateTime value) => value.toUtc().toIso8601String();
