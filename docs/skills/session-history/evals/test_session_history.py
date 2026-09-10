"""Retained native-Windows CLI regressions, using only owned temporary databases."""
import hashlib
import importlib.util
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest

SKILL = Path(__file__).resolve().parents[1]
ROOT = SKILL.parents[2]
SCRIPT = SKILL / 'scripts' / 'session_history.py'


def fixture(path):
    db = sqlite3.connect(path)
    db.executescript((ROOT / 'sql/init/001_initial_schema.sql').read_text())
    db.executescript((ROOT / 'sql/migration/012_external_content_search.sql').read_text())
    db.execute("INSERT INTO projects(id,name,created_at_utc,updated_at_utc) VALUES(1,'Atlas','2026-09-01','2026-09-01')")
    for sid, directory in [('s-a', 'F:/projects/Atlas'), ('s-b', 'F:/projects/Atlas-old')]:
        db.execute("""INSERT INTO sessions(id,session_id,source_type,source_file_path,display_path,platform_path,
            working_directory_platform,project_id,title,last_parsed_utc,created_at_utc,updated_at_utc)
            VALUES(?,?,'windows','fixture.jsonl','fixture.jsonl','fixture.jsonl',?,1,'Queue investigation',
            '2026-09-10T08:00:00Z','2026-09-01','2026-09-10')""", (sid, sid, directory))
    messages = [
        ('s-a', 0, 'user', '2026-09-09T08:00:00Z', 'Investigate shutdown queue race.'),
        ('s-a', 1, 'assistant', '2026-09-09T08:01:00Z', 'Proposed closing the queue under one lock. Not implemented yet.'),
        ('s-a', 2, 'tool', '2026-09-09T08:02:00Z', 'shutdown queue test failed'),
        ('s-a', 3, 'assistant', '2026-09-09T10:03:00+02:00', 'shutdown queue: claimed fixed, no commit or test evidence. ' + 'x' * 9000),
        ('s-a', 4, 'user', None, 'shutdown queue with no timestamp'),
        ('s-b', 0, 'assistant', '2026-09-09T08:04:00Z', 'shutdown queue unrelated sibling project'),
    ]
    for sid, index, role, at, content in messages:
        db.execute("""INSERT INTO messages(session_id,message_index,author_type,created_at_utc,
          content_plain,created_at_db_utc,updated_at_db_utc) VALUES(?,?,?,?,?,'2026-09-10','2026-09-10')""",
          (sid, index, role, at, content))
    db.execute("INSERT INTO message_search(message_search) VALUES('rebuild')")
    db.commit()
    db.close()


class HistoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='session-history-test-')
        self.addCleanup(self.temp.cleanup)
        self.db = Path(self.temp.name) / 'history space.sqlite'
        fixture(self.db)

    def invoke(self, *args, expected=0):
        result = subprocess.run([sys.executable, str(SCRIPT), '--db', str(self.db), *args],
                                capture_output=True, text=True, encoding='utf-8')
        self.assertEqual(result.returncode, expected, result.stderr)
        return json.loads(result.stdout if expected == 0 else result.stderr)

    def test_scope_and_readonly(self):
        before = hashlib.sha256(self.db.read_bytes()).hexdigest()
        result = self.invoke('search', '--query', 'shutdown queue', '--path', 'f:\\projects\\Atlas')
        self.assertEqual({r['session_id'] for r in result['results']}, {'s-a'})
        self.assertNotIn('tool', {r['author_type'] for r in result['results']})
        self.assertEqual(before, hashlib.sha256(self.db.read_bytes()).hexdigest())

    def test_tool_opt_in_and_date_offsets(self):
        result = self.invoke('search', '--query', 'shutdown queue', '--include-tools',
                             '--since', '2026-09-09T08:02:00Z', '--until', '2026-09-09T08:04:00Z')
        self.assertEqual({r['message_index'] for r in result['results']}, {2, 3})

    def test_message_pagination_and_long_text(self):
        result = self.invoke('messages', '--session', 's-a', '--limit', '2')
        self.assertTrue(result['has_more'])
        self.assertEqual(result['next_after_index'], 1)
        second = self.invoke('messages', '--session', 's-a', '--after-index', '1', '--limit', '2')
        self.assertEqual([r['message_index'] for r in second['results']], [3, 4])
        page = self.invoke('message', '--session', 's-a', '--index', '3', '--chars', '100')['results'][0]
        self.assertEqual(page['next_text_offset'], 100)
        self.assertEqual(page['reference'], 's-a#message-3')
        self.assertEqual(page['last_parsed_utc'], '2026-09-10T08:00:00Z')
        tail = self.invoke('message', '--session', 's-a', '--index', '3', '--text-offset', '9000')['results'][0]
        self.assertIsNone(tail['next_text_offset'])

    def test_search_pages_and_bounds(self):
        first = self.invoke('search', '--query', 'shutdown', '--limit', '1')
        second = self.invoke('search', '--query', 'shutdown', '--limit', '1', '--offset', '1')
        self.assertNotEqual(first['results'][0]['reference'], second['results'][0]['reference'])
        self.assertEqual(first['next_offset'], 1)
        result = subprocess.run([sys.executable, str(SCRIPT), '--db', str(self.db), 'search', '--query', 'queue', '--limit', '999'], capture_output=True)
        self.assertEqual(result.returncode, 2)

    def test_missing_and_wrong_schema(self):
        self.db.unlink()
        self.assertIn('does not exist', self.invoke('status', expected=2)['error'])
        self.assertFalse(self.db.exists())
        db = sqlite3.connect(self.db)
        try:
            db.execute('CREATE TABLE unrelated(id)')
            db.commit()
        finally:
            db.close()
        self.assertIn('Unsupported schema', self.invoke('status', expected=2)['error'])

    def test_bad_queries_and_empty_results(self):
        self.assertEqual(self.invoke('search', '--query', 'unfindable')['results'], [])
        self.invoke('search', '--query', '***', expected=2)
        self.invoke('search', '--query', 'queue', '--since', '2026-09-09T09:00:00', expected=2)
        self.invoke('search', '--query', 'queue', '--since', '2026-09-10', '--until', '2026-09-09', expected=2)
        self.assertEqual(self.invoke('search', '--query', 'queue', '--project', "Atlas' OR 1=1 --")['results'], [])

    def test_projects_and_index_status(self):
        self.assertEqual(self.invoke('projects')['results'][0]['name'], 'Atlas')
        status = self.invoke('status')
        self.assertTrue(status['fts_available'])
        self.assertEqual(status['backfill']['message_search.backfill.last_message_rowid'], '0')

    def test_native_readonly_wal_sees_committed_updates(self):
        db = sqlite3.connect(self.db)
        self.addCleanup(db.close)
        db.execute('PRAGMA journal_mode=WAL')
        db.execute("UPDATE projects SET name='Atlas renamed' WHERE id=1")
        db.commit()
        self.assertEqual(self.invoke('projects')['results'][0]['name'], 'Atlas renamed')

    def test_connection_rejects_writes(self):
        spec = importlib.util.spec_from_file_location('history_helper', SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        db = module.connect(self.db)
        self.addCleanup(db.close)
        with self.assertRaises(sqlite3.OperationalError):
            db.execute("DELETE FROM sessions")


if __name__ == '__main__':
    unittest.main()
