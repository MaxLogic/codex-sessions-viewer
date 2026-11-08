-- A rowid conflict can implicitly delete a different key without firing DELETE
-- triggers on foreign connections. With only the key primary index, REPLACE
-- can only replace that same key, which the INSERT trigger dirties.
CREATE TABLE collector_hub_record_state_rebuilt (
    record_key TEXT PRIMARY KEY,
    record_hash TEXT NOT NULL
) WITHOUT ROWID;
INSERT INTO collector_hub_record_state_rebuilt(record_key, record_hash)
SELECT record_key, record_hash FROM collector_hub_record_state;
DROP TABLE collector_hub_record_state;
ALTER TABLE collector_hub_record_state_rebuilt RENAME TO collector_hub_record_state;

CREATE TABLE hub_status_plan (
    harness TEXT NOT NULL,
    bucket INTEGER NOT NULL CHECK (bucket BETWEEN 0 AND 1023),
    digest BLOB NOT NULL,
    PRIMARY KEY (harness, bucket)
) WITHOUT ROWID;

CREATE TABLE hub_status_plan_dirty (record_key TEXT PRIMARY KEY) WITHOUT ROWID;

CREATE TRIGGER hub_status_plan_dirty_insert AFTER INSERT ON collector_hub_record_state
WHEN substr(new.record_key, 1, 7) = 'status:'
BEGIN
    -- An outer UPSERT can override a trigger's OR IGNORE conflict policy.
    INSERT INTO hub_status_plan_dirty SELECT new.record_key
    WHERE NOT EXISTS (SELECT 1 FROM hub_status_plan_dirty WHERE record_key = new.record_key);
END;

CREATE TRIGGER hub_status_plan_dirty_update AFTER UPDATE ON collector_hub_record_state
WHEN substr(old.record_key, 1, 7) = 'status:' OR substr(new.record_key, 1, 7) = 'status:'
BEGIN
    INSERT INTO hub_status_plan_dirty SELECT old.record_key WHERE substr(old.record_key, 1, 7) = 'status:'
    AND NOT EXISTS (SELECT 1 FROM hub_status_plan_dirty WHERE record_key = old.record_key);
    INSERT INTO hub_status_plan_dirty SELECT new.record_key WHERE substr(new.record_key, 1, 7) = 'status:'
    AND NOT EXISTS (SELECT 1 FROM hub_status_plan_dirty WHERE record_key = new.record_key);
END;

CREATE TRIGGER hub_status_plan_dirty_delete AFTER DELETE ON collector_hub_record_state
WHEN substr(old.record_key, 1, 7) = 'status:'
BEGIN
    INSERT INTO hub_status_plan_dirty SELECT old.record_key
    WHERE NOT EXISTS (SELECT 1 FROM hub_status_plan_dirty WHERE record_key = old.record_key);
END;
