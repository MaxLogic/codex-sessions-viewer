"""Owned, deny-by-default process boundary for history evaluations."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit
import ipaddress

REPO = Path(__file__).resolve().parents[2]
KEYS = ('LOCALAPPDATA APPDATA USERPROFILE HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME XDG_RUNTIME_DIR XDG_CONFIG_DIRS XDG_DATA_DIRS CODEX_HOME CLAUDE_CONFIG_DIR CLAUDE_HOME CODEX_SESSIONS_COLLECTOR_QUEUE TEMP TMP TMPDIR').split()
ORIGINAL = {k.upper() if os.name == 'nt' else k: v for k,v in os.environ.items()}
SYSTEM_KEYS = ('SYSTEMROOT WINDIR COMSPEC SYSTEMDRIVE PATHEXT PROGRAMFILES PROGRAMFILES(X86) PROGRAMW6432 PROGRAMDATA ALLUSERSPROFILE COMMONPROGRAMFILES COMMONPROGRAMFILES(X86) COMMONPROGRAMW6432').split()

def validate_system(values, original=ORIGINAL):
    for key in SYSTEM_KEYS:
        value = values.get(key)
        if not value:
            continue
        if value != original.get(key):
            raise RuntimeError(f'Test isolation rejected system variable: {key}')
        if key == 'PATHEXT':
            if not all(s.startswith('.') and s[1:].isalnum() for s in value.split(';')):
                raise RuntimeError('Test isolation rejected system PATHEXT')
            continue
        path = Path(value + '\\' if key == 'SYSTEMDRIVE' and len(value) == 2 and value[1] == ':' else value)
        if not path.is_absolute():
            raise RuntimeError('Test isolation rejected relative system location')
        path = path.resolve()
        profiles = [Path(original[k]).resolve() for k in KEYS if original.get(k)]
        if os.name == 'nt' and original.get('USERPROFILE'):
            profiles.append(Path(original['USERPROFILE']).resolve().parent)
        if any(path.is_relative_to(profile) for profile in profiles):
            raise RuntimeError('Test isolation rejected profile system location')

ENDPOINTS = set()
def endpoint_origin(value):
    try:
        uri = urlsplit(value)
        if uri.scheme not in ('http','https') or not ipaddress.ip_address(uri.hostname).is_loopback or not uri.port:
            raise ValueError('not a loopback endpoint')
        return (uri.scheme, uri.hostname, uri.port)
    except (ValueError, TypeError) as error:
        raise RuntimeError('Test isolation rejected network endpoint') from error

def own_endpoint(value):
    """Call only for a server bound by this fixture."""
    ENDPOINTS.add(endpoint_origin(value))

def guard_endpoint(value):
    if endpoint_origin(value) not in ENDPOINTS:
        raise RuntimeError('Test isolation rejected unowned network endpoint')

validate_system(ORIGINAL)
PARENT = Path(ORIGINAL.get('CXV_TEST_SANDBOX_PARENT', REPO/'app/build/test-sandboxes')).resolve()
for key in KEYS:
    if ORIGINAL.get(key) and PARENT.is_relative_to(Path(ORIGINAL[key]).resolve()):
        raise RuntimeError('Test profile isolation rejected inherited sandbox parent')
PARENT.mkdir(parents=True, exist_ok=True)
ROOT = Path(tempfile.mkdtemp(prefix='py-', dir=PARENT)).resolve()
ENV = {k: ORIGINAL[k] for k in ('PATH','SYSTEMROOT','WINDIR','COMSPEC','PATHEXT','CARGO_HOME','RUSTUP_HOME','PROGRAMFILES','PROGRAMFILES(X86)','PROGRAMW6432','PROGRAMDATA','ALLUSERSPROFILE','COMMONPROGRAMFILES','COMMONPROGRAMFILES(X86)','COMMONPROGRAMW6432','INCLUDE','LIB','LIBPATH') if k in ORIGINAL}
for key in KEYS:
    path = ROOT/key
    path.mkdir()
    ENV[key] = str(path)

def guard(path):
    path = Path(path).resolve()
    if not path.is_relative_to(ROOT):
        raise RuntimeError(f'Test profile isolation rejected path: {path}')
    for key in KEYS:
        if ORIGINAL.get(key) and path.is_relative_to(Path(ORIGINAL[key]).resolve()):
            raise RuntimeError('Test profile isolation rejected inherited profile')
    return path

def run(args, **kwargs):
    validate_system(ENV)
    if kwargs.get('shell'):
        raise RuntimeError('Test profile isolation rejects shell execution')
    args = [str(arg) for arg in args]
    executable = Path(shutil.which(str(args[0])) or args[0]).resolve()
    args[0] = str(executable)
    collector = REPO/'collector/target/debug/codex-sessions-collector.exe'
    release = REPO/'collector/target/release/codex-sessions-collector.exe'
    script = REPO/'docs/skills/session-history/scripts/session_history.py'
    example = REPO/'samples/collector-contract/example_collector.py'
    if executable in (collector.resolve(),release.resolve()) and executable.is_relative_to((REPO/'collector/target').resolve()):
        if args[1] not in ('apply','query'):
            raise RuntimeError('Test profile isolation rejected collector command')
    elif executable == Path(sys.executable).resolve():
        if Path(args[1]).resolve() == example:
            source = Path(args[2]).resolve()
            args[1] = str(example)
            args[2] = str(source)
            if not source.is_relative_to((REPO/'samples/collector-contract').resolve()):
                guard(source)
            if len(args) > 3 and (len(args) != 5 or args[3] not in ('--harness','--machine-id')):
                raise RuntimeError('Test profile isolation rejected example arguments')
            return subprocess.run(args, env=ENV, cwd=ROOT, creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0, **kwargs)
        if Path(args[1]).resolve() != script:
            raise RuntimeError('Test profile isolation rejected Python entry point')
        args[1] = str(script)
    elif executable == Path(shutil.which('cargo')).resolve():
        # rustup dispatch depends on the proxy name, not the physical image name.
        args[0] = str(Path(shutil.which('cargo')).absolute().with_name('cargo.exe' if os.name == 'nt' else 'cargo'))
        if args[1:] not in (['build','--quiet','--manifest-path',str(REPO/'collector/Cargo.toml')], ['build','--locked','--manifest-path',str(REPO/'collector/Cargo.toml')]):
            raise RuntimeError('Test profile isolation rejected cargo command')
        return subprocess.run(args, env=ENV, cwd=REPO, creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0, **kwargs)
    else:
        raise RuntimeError('Test profile isolation rejected executable')
    database = None
    explicit_executable = executable != Path(sys.executable).resolve()
    value_flags = {'--exe','--db','--standalone','--input','--query','--limit','--offset','--session','--ref','--chars','--after-index','--text-offset','--cursor','--path','--project','--since','--until','--harness','--format','--index','--machine','--export-format','--max-chars','--max-messages','--hub','--hub-machine'}
    switches = {'--include-tools','--help'}
    for arg in args:
        if arg.startswith('--') and arg.split('=',1)[0] not in value_flags | switches:
            raise RuntimeError('Test profile isolation rejected unlisted query option')
    for i,arg in enumerate(args):
        if arg.split('=',1)[0] in ('--hub','--hub-url'):
            guard_endpoint(arg.split('=',1)[1] if '=' in arg else args[i+1])
        if arg == '--exe' or arg.startswith('--exe='):
            child = Path(arg.split('=',1)[1] if '=' in arg else args[i+1]).resolve()
            if child not in (collector.resolve(), release.resolve()) or not child.is_relative_to((REPO/'collector/target').resolve()):
                raise RuntimeError('Test profile isolation rejected launcher executable')
            explicit_executable = True
        if arg == '--input':
            guard(args[i+1])
        if arg in ('--db','--standalone'):
            database = guard(args[i+1])
        elif str(arg).startswith('--db='):
            database = guard(str(arg)[5:])
    if not explicit_executable:
        raise RuntimeError('Test profile isolation requires an explicit candidate executable')
    if database is None:
        raise RuntimeError('Test profile isolation requires an explicit fixture database')
    return subprocess.run(args, env=ENV, cwd=ROOT, creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0, **kwargs)
