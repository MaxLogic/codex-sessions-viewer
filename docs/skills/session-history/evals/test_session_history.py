"""Retained native-Windows regressions for the session-history launcher, using
only owned temporary databases built by the collector."""
import hashlib
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import fixture  # noqa: E402

SKILL = HERE.parent
SCRIPT = SKILL / 'scripts' / 'session_history.py'
EXE = fixture.collector_exe()


class HistoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='session-history-test-')
        self.addCleanup(self.temp.cleanup)
        self.db = fixture.build(Path(self.temp.name) / 'history space.sqlite', EXE)

    def invoke(self, *args, expected=0):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), '--exe', str(EXE), '--db', str(self.db), *args],
            capture_output=True, text=True, encoding='utf-8')
        self.assertEqual(result.returncode, expected, result.stderr)
        text = result.stdout if expected == 0 else result.stderr.splitlines()[0]
        return json.loads(text)

    def reference(self, session, index=None):
        status = self.invoke('status')
        machine = status['machine_id']
        harness = 'claude' if session.startswith('c-') else 'codex'
        base = f'history://{machine}/{harness}/{session}'
        return base if index is None else f'{base}#{index}'

    def test_scope_and_readonly(self):
        before = hashlib.sha256(self.db.read_bytes()).hexdigest()
        result = self.invoke('search', '--query', 'shutdown queue', '--path', 'f:\\projects\\Atlas')
        sessions = {r['session_key'] for r in result['results']}
        self.assertEqual(sessions, {'s-a', 'c-1'})
        self.assertNotIn('tool', {r['author_type'] for r in result['results']})
        self.assertEqual(before, hashlib.sha256(self.db.read_bytes()).hexdigest())

    def test_harness_filter(self):
        result = self.invoke('search', '--query', 'shutdown queue', '--harness', 'claude')
        self.assertEqual([r['session_key'] for r in result['results']], ['c-1'])

    def test_tool_opt_in_and_date_offsets(self):
        result = self.invoke('search', '--query', 'shutdown queue', '--include-tools',
                             '--since', '2026-09-09T08:02:00Z', '--until', '2026-09-09T10:04:00+02:00')
        self.assertEqual({r['message_index'] for r in result['results']}, {2, 3})

    def test_message_pagination_and_long_text(self):
        session = self.reference('s-a')
        result = self.invoke('messages', '--session', session, '--limit', '2', '--include-tools')
        self.assertTrue(result['has_more'])
        self.assertEqual(result['next_after_index'], 1)
        second = self.invoke('messages', '--session', session, '--after-index', '1', '--limit', '2')
        self.assertEqual([r['message_index'] for r in second['results']], [3, 4])
        page = self.invoke('message', '--ref', self.reference('s-a', 3), '--chars', '100')['result']
        self.assertEqual(page['next_text_offset'], 100)
        self.assertEqual(page['reference'], self.reference('s-a', 3))
        self.assertIsNotNone(page['last_parsed_utc'])
        tail = self.invoke('message', '--ref', self.reference('s-a', 3), '--text-offset', '9000')['result']
        self.assertIsNone(tail['next_text_offset'])

    def test_search_pages_and_bounds(self):
        expected = [r['reference'] for r in self.invoke(
            'search', '--query', 'shutdown', '--include-tools', '--limit', '50')['results']]
        self.assertGreater(len(expected), 3)
        paged, cursor = [], None
        while True:
            args = ['search', '--query', 'shutdown', '--include-tools', '--limit', '1']
            if cursor:
                args += ['--cursor', cursor]
            page = self.invoke(*args)
            paged += [r['reference'] for r in page['results']]
            cursor = page['next_cursor']
            if not cursor:
                break
        self.assertEqual(paged, expected)
        self.invoke('search', '--query', 'queue', '--limit', '999', expected=2)

    def test_leading_options_in_either_form(self):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), '--exe', str(EXE), f'--db={self.db}', '--format', 'text',
             'search', '--query', 'shutdown queue', '--limit', '1'],
            capture_output=True, text=True, encoding='utf-8')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('history://', result.stdout)

    def test_missing_and_old_schema(self):
        missing = Path(self.temp.name) / 'absent.sqlite'
        result = subprocess.run(
            [sys.executable, str(SCRIPT), '--exe', str(EXE), '--db', str(missing), 'status'],
            capture_output=True, text=True, encoding='utf-8')
        self.assertEqual(result.returncode, 1)
        self.assertIn('No database', result.stderr)
        self.assertFalse(missing.exists())
        unrelated = Path(self.temp.name) / 'unrelated.sqlite'
        db = sqlite3.connect(unrelated)
        try:
            db.execute('CREATE TABLE unrelated(id)')
            db.commit()
        finally:
            db.close()
        result = subprocess.run(
            [sys.executable, str(SCRIPT), '--exe', str(EXE), '--db', str(unrelated), 'status'],
            capture_output=True, text=True, encoding='utf-8')
        self.assertEqual(result.returncode, 3)
        self.assertIn('history queries need schema', result.stderr)

    def test_bad_queries_and_empty_results(self):
        self.assertEqual(self.invoke('search', '--query', 'unfindable')['results'], [])
        self.invoke('search', '--query', '***', expected=2)
        self.invoke('search', '--query', 'queue', '--since', '2026-09-09T09:00:00', expected=2)
        self.invoke('search', '--query', 'queue', '--since', '2026-09-10', '--until', '2026-09-09', expected=2)
        self.assertEqual(self.invoke('search', '--query', 'queue', '--project', "Atlas' OR 1=1 --")['results'], [])

    def test_projects_and_status(self):
        names = [row['project'] for row in self.invoke('projects')['results']]
        self.assertEqual(names, ['Atlas', 'Atlas-old'])
        status = self.invoke('status')
        self.assertEqual(status['schema_version'], 20)
        self.assertEqual(status['database_owner'], 'collector')
        self.assertEqual(sum(row['sessions'] for row in status['harnesses']), 3)

    def test_reads_committed_wal_updates(self):
        db = sqlite3.connect(self.db)
        self.addCleanup(db.close)
        db.execute("UPDATE projects SET name='Atlas renamed' WHERE name='Atlas'")
        db.commit()
        names = [row['project'] for row in self.invoke('projects')['results']]
        self.assertIn('Atlas renamed', names)


def wsl_available():
    try:
        return subprocess.run(['wsl.exe', '-e', 'python3', '--version'], capture_output=True,
                              timeout=60).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def to_wsl(path):
    drive, rest = str(path)[0].lower(), str(path)[2:].replace('\\', '/')
    return f'/mnt/{drive}{rest}'


@unittest.skipUnless(wsl_available(), 'WSL with python3 is not available')
class WslLauncherTests(unittest.TestCase):
    """The launcher inside WSL runs the Windows executable through interop."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='session-history-wsl-')
        self.addCleanup(self.temp.cleanup)
        self.db = fixture.build(Path(self.temp.name) / 'wsl.sqlite', EXE)

    def run_wsl(self, *args):
        return subprocess.run(
            ['wsl.exe', '-e', 'python3', to_wsl(SCRIPT), '--exe', to_wsl(EXE), *args],
            capture_output=True, text=True, encoding='utf-8', timeout=120)

    def test_wsl_paths_reach_the_windows_database(self):
        result = self.run_wsl('--db', to_wsl(self.db), 'search', '--query', 'shutdown queue',
                              '--path', '/mnt/f/projects/Atlas')
        self.assertEqual(result.returncode, 0, result.stderr)
        keys = {row['session_key'] for row in json.loads(result.stdout)['results']}
        self.assertEqual(keys, {'s-a', 'c-1'})

    def test_default_database_comes_from_windows_appdata(self):
        result = self.run_wsl('status')
        # Whatever the local database holds, the launcher must have found
        # the Windows default instead of failing on a missing APPDATA.
        self.assertNotIn('APPDATA is not set', result.stderr)
        self.assertIn('CodexSessionViewer', result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
