"""Retained native-Windows regressions for the session-history launcher, using
only owned temporary databases built by the collector."""
import hashlib
import io
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import importlib.util
import test_environment

HERE = Path(__file__).resolve().parent
# The schema the collector creates is the newest migration in sql/migration.
LATEST_SCHEMA = max(int(p.name[:3]) for p in (HERE.parents[3] / 'sql' / 'migration').glob('[0-9][0-9][0-9]_*.sql'))
sys.path.insert(0, str(HERE))
import fixture  # noqa: E402

SKILL = HERE.parent
SCRIPT = SKILL / 'scripts' / 'session_history.py'
EXE = fixture.collector_exe()


class HistoryTests(unittest.TestCase):
    def test_system_locations_and_endpoints_fail_before_spawn(self):
        for key in test_environment.SYSTEM_KEYS:
            with self.assertRaisesRegex(RuntimeError, 'system'):
                test_environment.validate_system({**test_environment.ENV, key: str(test_environment.ROOT/'poison-system')})
        for url in ('https://example.invalid','http://127.0.0.1:12345'):
            with mock.patch.object(test_environment.subprocess, 'run') as spawn:
                with self.assertRaisesRegex(RuntimeError, 'endpoint'):
                    test_environment.run([str(EXE), 'query', 'status', '--db', str(test_environment.ROOT/'probe.sqlite'), '--hub', url])
                spawn.assert_not_called()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='history-', dir=test_environment.ROOT)
        self.addCleanup(self.temp.cleanup)
        self.db = fixture.build(Path(self.temp.name) / 'history space.sqlite', EXE)

    def invoke(self, *args, expected=0):
        result = test_environment.run(
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
        result = test_environment.run(
            [sys.executable, str(SCRIPT), '--exe', str(EXE), f'--db={self.db}', '--format', 'text',
             'search', '--query', 'shutdown queue', '--limit', '1'],
            capture_output=True, text=True, encoding='utf-8')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('history://', result.stdout)

    def test_missing_and_old_schema(self):
        missing = Path(self.temp.name) / 'absent.sqlite'
        result = test_environment.run(
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
        result = test_environment.run(
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
        self.assertEqual(status['schema_version'], LATEST_SCHEMA)
        self.assertEqual(status['database_owner'], 'collector')
        self.assertEqual(sum(row['sessions'] for row in status['harnesses']), 3)

    def test_reads_committed_wal_updates(self):
        db = sqlite3.connect(self.db)
        self.addCleanup(db.close)
        db.execute("UPDATE projects SET name='Atlas renamed' WHERE name='Atlas'")
        db.commit()
        names = [row['project'] for row in self.invoke('projects')['results']]
        self.assertIn('Atlas renamed', names)


def to_wsl(path):
    drive, rest = str(path)[0].lower(), str(path)[2:].replace('\\', '/')
    return f'/mnt/{drive}{rest}'


HUB_VARIABLES = ('CODEX_SESSIONS_HUB_URL', 'CODEX_SESSIONS_HUB_OWNER_TOKEN', 'CODEX_SESSIONS_HUB_ENV_FILE')


def load_launcher(test):
    """In-process launcher with no inherited or Windows-side hub configuration."""
    environment = mock.patch.dict('os.environ')
    environment.start()
    test.addCleanup(environment.stop)
    for name in HUB_VARIABLES:
        os.environ.pop(name, None)
    spec = importlib.util.spec_from_file_location('history_launcher', SCRIPT)
    launcher = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(launcher)
    lookup = mock.patch.object(launcher, 'windows_variable', return_value=None)
    lookup.start()
    test.addCleanup(lookup.stop)
    return launcher


class WslLauncherTests(unittest.TestCase):
    """Exercise WSL routing with the default-profile lookup mocked, never WSL."""
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='wsl-', dir=test_environment.ROOT)
        self.addCleanup(self.temp.cleanup)
        self.db = fixture.build(Path(self.temp.name) / 'wsl.sqlite', EXE)
        self.launcher = load_launcher(self)

    def test_wsl_paths_reach_the_windows_database(self):
        with mock.patch.object(self.launcher, 'in_wsl', return_value=True), \
             mock.patch.object(self.launcher, 'find_exe', return_value=str(EXE)), \
             mock.patch.object(self.launcher, 'to_windows', return_value=str(self.db)) as convert, \
             mock.patch.object(self.launcher.subprocess, 'run') as spawn:
            spawn.return_value.returncode = 0
            self.assertEqual(self.launcher.main(['--exe', str(EXE), '--db', to_wsl(self.db), 'status']), 0)
            args = spawn.call_args.args[0]
            convert.assert_called_once_with(to_wsl(self.db))
            self.assertIn(str(self.db), args)
            test_environment.guard(args[args.index('--db')+1])

    def test_default_database_comes_from_windows_appdata(self):
        with mock.patch.object(self.launcher, 'in_wsl', return_value=True), \
             mock.patch.object(self.launcher, 'find_exe', return_value=str(EXE)), \
             mock.patch.object(self.launcher, 'windows_appdata_database', return_value=str(self.db)) as lookup, \
             mock.patch.object(self.launcher.subprocess, 'run') as spawn:
            spawn.return_value.returncode = 0
            self.assertEqual(self.launcher.main(['--exe', str(EXE), 'status']), 0)
            lookup.assert_called_once_with()
            self.assertEqual(spawn.call_args.args[0], [str(EXE), 'query', 'status', '--db', str(self.db)])
            test_environment.guard(spawn.call_args.args[0][-1])

    def test_default_profile_database_is_rejected_by_native_boundary(self):
        with self.assertRaisesRegex(RuntimeError, 'explicit fixture database'):
            test_environment.run([str(EXE), 'query', 'status'])


class HubLauncherTests(unittest.TestCase):
    """Hub routing with the machine list and collector process mocked; no network."""
    URL = 'https://hub.example.test'

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='hub-', dir=test_environment.ROOT)
        self.addCleanup(self.temp.cleanup)
        self.launcher = load_launcher(self)
        self.env_file = Path(self.temp.name) / 'hub.env'
        self.env_file.write_text('# comment\nCODEX_SESSIONS_HUB_OWNER_TOKEN=owner-secret-value\n'
                                 'CODEX_SESSIONS_HUB_MACHINE_ID_ALPHA=machine-a\n'
                                 'CODEX_SESSIONS_HUB_MACHINE_ID_BETA=machine-b\n', encoding='utf-8')
        os.environ['CODEX_SESSIONS_HUB_URL'] = self.URL
        os.environ['CODEX_SESSIONS_HUB_ENV_FILE'] = str(self.env_file)

    def run_main(self, *args, machines=('machine-a', 'machine-b'), outputs=None):
        outputs = outputs or {}
        def spawn(command, **kwargs):
            if '--hub-machine' not in command:
                return subprocess.CompletedProcess(command, 0, '', '')
            machine = command[command.index('--hub-machine') + 1]
            code, stdout, stderr = outputs.get(machine, (0, json.dumps({'machine': machine}), ''))
            return subprocess.CompletedProcess(command, code, stdout, stderr)
        stdout = mock.patch('sys.stdout', new_callable=io.StringIO)
        with mock.patch.object(self.launcher, 'in_wsl', return_value=False), \
             mock.patch.object(self.launcher.os, 'name', 'nt'), \
             mock.patch.object(self.launcher, 'find_exe', return_value=str(EXE)), \
             mock.patch.object(self.launcher, 'hub_machines', return_value=list(machines)) as listed, \
             mock.patch.object(self.launcher.subprocess, 'run', side_effect=spawn) as process, \
             stdout as printed:
            code = self.launcher.main(list(args))
        return code, printed.getvalue(), process, listed

    def test_configured_hub_queries_every_machine_with_token_in_environment(self):
        code, printed, process, listed = self.run_main('search', '--query', 'shutdown queue')
        self.assertEqual(code, 0)
        listed.assert_called_once_with(self.URL, 'owner-secret-value')
        self.assertEqual(process.call_count, 2)
        for call, machine in zip(process.call_args_list, ('machine-a', 'machine-b')):
            command = call.args[0]
            self.assertEqual(command[:5], [str(EXE), 'query', 'search', '--query', 'shutdown queue'])
            self.assertEqual(command[-4:], ['--hub', self.URL, '--hub-machine', machine])
            self.assertNotIn('owner-secret-value', command)
            self.assertEqual(call.kwargs['env']['CODEX_SESSIONS_HUB_OWNER_TOKEN'], 'owner-secret-value')
        merged = json.loads(printed)
        self.assertEqual([(m['machine'], m['name']) for m in merged['machines']],
                         [('machine-a', 'ALPHA'), ('machine-b', 'BETA')])
        self.assertNotIn('owner-secret-value', printed)

    def test_machine_name_selects_one_machine_and_passes_output_through(self):
        code, printed, process, listed = self.run_main('status', '--hub-machine', 'BETA')
        self.assertEqual(code, 0)
        listed.assert_not_called()
        self.assertEqual(process.call_args.args[0][-1], 'machine-b')
        self.assertEqual(json.loads(printed), {'machine': 'machine-b'})

    def test_one_failing_machine_is_reported_and_fails_the_run(self):
        error = json.dumps({'error': 'unknown machine'})
        code, printed, _, _ = self.run_main('status', outputs={'machine-b': (1, '', error)})
        self.assertEqual(code, 1)
        merged = json.loads(printed)['machines']
        self.assertEqual(merged[0]['result'], {'machine': 'machine-a'})
        self.assertEqual(merged[1]['error'], {'error': 'unknown machine'})

    def test_local_and_db_options_bypass_the_hub(self):
        for args in (['--local', 'status'], ['--db', str(Path(self.temp.name) / 'local.sqlite'), 'status']):
            code, _, process, listed = self.run_main(*args)
            self.assertEqual(code, 0)
            listed.assert_not_called()
            self.assertNotIn('--hub', process.call_args.args[0])

    def test_hub_machine_without_a_hub_is_refused_instead_of_reading_local_history(self):
        del os.environ['CODEX_SESSIONS_HUB_URL']
        with mock.patch('sys.stderr', new_callable=io.StringIO) as printed:
            code, _, process, _ = self.run_main('status', '--hub-machine', 'ALPHA')
        self.assertEqual(code, 2)
        self.assertIn('--hub-machine needs a hub', printed.getvalue())
        process.assert_not_called()

    def test_missing_owner_token_is_an_error_before_any_request(self):
        self.env_file.write_text('CODEX_SESSIONS_HUB_MACHINE_ID_ALPHA=machine-a\n', encoding='utf-8')
        stderr = mock.patch('sys.stderr', new_callable=io.StringIO)
        with stderr as printed:
            code, _, process, listed = self.run_main('status')
        self.assertEqual(code, 2)
        self.assertIn('CODEX_SESSIONS_HUB_OWNER_TOKEN', printed.getvalue())
        listed.assert_not_called()
        process.assert_not_called()


class LaunchBoundaryTests(unittest.TestCase):
    def test_unknown_tools_and_inline_executable_escape_are_denied(self):
        with self.assertRaisesRegex(RuntimeError, 'rejected executable'):
            test_environment.run(['wsl.exe', '-e', 'python3', '--version'])
        with self.assertRaisesRegex(RuntimeError, 'launcher executable'):
            test_environment.run([sys.executable, str(SCRIPT), '--exe=C:/synthetic-real-profile/schtasks.exe', '--db', str(test_environment.ROOT/'owned.sqlite'), 'status'])


if __name__ == '__main__':
    unittest.main()
