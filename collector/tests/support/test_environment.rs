//! Fail-closed child-process boundary shared by every integration harness.
use std::collections::BTreeMap;
use std::ffi::{OsStr, OsString};
use std::io;
use std::path::{Component, Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Output, Stdio};
use std::sync::OnceLock;

const SYSTEM_KEYS: &[&str] = &[
    "SYSTEMROOT",
    "WINDIR",
    "COMSPEC",
    "PATHEXT",
    "SYSTEMDRIVE",
    "PROGRAMFILES",
    "PROGRAMFILES(X86)",
    "PROGRAMW6432",
    "PROGRAMDATA",
    "ALLUSERSPROFILE",
    "COMMONPROGRAMFILES",
    "COMMONPROGRAMFILES(X86)",
    "COMMONPROGRAMW6432",
];
static ENDPOINTS: OnceLock<std::sync::Mutex<std::collections::HashSet<String>>> = OnceLock::new();
fn endpoint(value: &str) -> io::Result<String> {
    let (scheme, rest) = value
        .split_once("://")
        .ok_or_else(|| denied("invalid network endpoint"))?;
    if !["http", "https"].contains(&scheme) {
        return Err(denied("invalid network endpoint scheme"));
    }
    let authority = rest.split(['/', '?', '#']).next().unwrap();
    let socket = authority
        .rsplit('@')
        .next()
        .unwrap()
        .parse::<std::net::SocketAddr>()
        .map_err(|_| denied("network endpoint must use a loopback IP and explicit port"))?;
    if !socket.ip().is_loopback() || socket.port() == 0 {
        return Err(denied("non-loopback network endpoint"));
    }
    Ok(format!("{scheme}://{socket}"))
}
/// The caller must bind this endpoint as a fixture before registering it.
pub fn own_endpoint(value: &str) {
    ENDPOINTS
        .get_or_init(Default::default)
        .lock()
        .unwrap()
        .insert(endpoint(value).unwrap());
}
fn guard_endpoint(value: &str) -> io::Result<()> {
    let key = endpoint(value)?;
    if !ENDPOINTS
        .get_or_init(Default::default)
        .lock()
        .unwrap()
        .contains(&key)
    {
        return Err(denied("unowned network endpoint"));
    }
    Ok(())
}

fn guard_system(values: &BTreeMap<OsString, OsString>, profiles: &[PathBuf]) -> io::Result<()> {
    for key in SYSTEM_KEYS {
        let Some(value) = values.get(OsStr::new(key)) else {
            continue;
        };
        if std::env::var_os(key).as_ref() != Some(value) {
            return Err(denied(format!("system variable mismatch: {key}")));
        }
        if *key == "PATHEXT" {
            if !value.to_string_lossy().split(';').all(|s| {
                s.starts_with('.')
                    && s.len() > 1
                    && s[1..].chars().all(|c| c.is_ascii_alphanumeric())
            }) {
                return Err(denied("invalid system PATHEXT"));
            }
            continue;
        }
        let location = if *key == "SYSTEMDRIVE" {
            format!("{}\\", value.to_string_lossy())
        } else {
            value.to_string_lossy().into_owned()
        };
        let path = Path::new(&location);
        if !path.is_absolute() {
            return Err(denied(format!("relative system location: {key}")));
        }
        let path = physical(path)?;
        if profiles.iter().any(|profile| within(profile, &path)) {
            return Err(denied("system location inside a profile"));
        }
        #[cfg(windows)]
        if let Some(home) = std::env::var_os("USERPROFILE") {
            let home = PathBuf::from(home);
            if let Some(parent) = home.parent()
                && within(&physical(parent)?, &path)
            {
                return Err(denied("system location inside user profiles"));
            }
        }
    }
    Ok(())
}

pub const PROFILE_KEYS: &[&str] = &[
    "LOCALAPPDATA",
    "APPDATA",
    "USERPROFILE",
    "HOME",
    "XDG_CONFIG_HOME",
    "XDG_DATA_HOME",
    "XDG_STATE_HOME",
    "XDG_CACHE_HOME",
    "XDG_RUNTIME_DIR",
    "XDG_CONFIG_DIRS",
    "XDG_DATA_DIRS",
    "CODEX_HOME",
    "CLAUDE_CONFIG_DIR",
    "CLAUDE_HOME",
    "CODEX_SESSIONS_COLLECTOR_QUEUE",
    "TEMP",
    "TMP",
    "TMPDIR",
];

struct Environment {
    root: PathBuf,
    variables: BTreeMap<OsString, OsString>,
    real_profiles: Vec<PathBuf>,
}
static ENVIRONMENT: OnceLock<Environment> = OnceLock::new();

fn environment() -> &'static Environment {
    ENVIRONMENT.get_or_init(|| {
        make_environment(
            std::env::vars_os()
                .map(|(key, value)| (env_key(&key), value))
                .collect(),
        )
    })
}
fn make_environment(original: BTreeMap<OsString, OsString>) -> Environment {
    let real_profiles: Vec<PathBuf> = PROFILE_KEYS
        .iter()
        .filter_map(|key| original.get(OsStr::new(key)))
        .filter(|value| !value.is_empty())
        .map(|value| physical(Path::new(value)).expect("inherited profile must resolve physically"))
        .collect();
    guard_system(&original, &real_profiles).expect("test system locations must be safe");
    let parent = original
        .get(OsStr::new("CXV_TEST_SANDBOX_PARENT"))
        .map(PathBuf::from)
        .unwrap_or_else(|| Path::new(env!("CARGO_MANIFEST_DIR")).join("target/test-sandboxes"));
    Environment {
        root: parent.clone(),
        variables: BTreeMap::new(),
        real_profiles: real_profiles.clone(),
    }
    .guard(&parent, &parent)
    .expect("test sandbox parent must be outside inherited profile");
    std::fs::create_dir_all(&parent).unwrap();
    let root = parent.join(format!(
        "r-{:x}-{:x}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    // Native absolute spelling keeps fixture paths consistent with collector
    // output and prevents cmd builtins interpreting mixed '/' separators as
    // switches. Physical ownership/reparse checks remain in guard below.
    let root = std::path::absolute(root).expect("test sandbox root must resolve absolutely");
    std::fs::create_dir(&root).unwrap();
    let mut variables: BTreeMap<OsString, OsString> = original
        .into_iter()
        .filter(|(key, _)| {
            key == OsStr::new("PATH")
                || SYSTEM_KEYS.iter().any(|allowed| key == OsStr::new(allowed))
        })
        .collect();
    for key in PROFILE_KEYS {
        let directory = root.join(key);
        std::fs::create_dir(&directory).unwrap();
        variables.insert((*key).into(), directory.into_os_string());
    }
    variables.insert("HOME".into(), variables[OsStr::new("USERPROFILE")].clone());
    let env = Environment {
        root,
        variables,
        real_profiles,
    };
    env.guard(&env.root, &env.root).unwrap();
    env
}
/// Exercise inherited-default isolation without mutating process-global env.
pub fn command_with_inherited_profile(program: impl AsRef<OsStr>, appdata: &Path) -> TestCommand {
    let mut original: BTreeMap<_, _> = std::env::vars_os()
        .map(|(key, value)| (env_key(&key), value))
        .collect();
    original.insert("APPDATA".into(), appdata.as_os_str().to_owned());
    original.insert(
        "CXV_TEST_SANDBOX_PARENT".into(),
        temp_dir().into_os_string(),
    );
    let isolated = make_environment(original);
    let mut command = Command::new(program);
    command
        .env_clear()
        .envs(isolated.variables)
        .current_dir(isolated.root);
    TestCommand { command, raw: None }
}

pub fn test_root() -> &'static Path {
    &environment().root
}
pub fn temp_dir() -> PathBuf {
    let path = test_root().join("tmp");
    std::fs::create_dir_all(&path).unwrap();
    path
}

fn absolute(path: &Path, cwd: &Path) -> PathBuf {
    let mut result = PathBuf::new();
    for part in (if path.is_absolute() {
        path.to_path_buf()
    } else {
        cwd.join(path)
    })
    .components()
    {
        match part {
            Component::ParentDir => {
                result.pop();
            }
            Component::CurDir => (),
            other => result.push(other.as_os_str()),
        }
    }
    result
}
fn physical(path: &Path) -> io::Result<PathBuf> {
    let mut cursor = path.to_path_buf();
    let mut tail = Vec::new();
    while !cursor.try_exists()? {
        tail.push(
            cursor
                .file_name()
                .ok_or_else(|| io::Error::other("unresolvable test path"))?
                .to_os_string(),
        );
        if !cursor.pop() {
            return Err(io::Error::other("unresolvable test path"));
        }
    }
    let mut resolved = std::fs::canonicalize(cursor)?;
    resolved.extend(tail.into_iter().rev());
    Ok(resolved)
}
fn within(root: &Path, path: &Path) -> bool {
    if cfg!(windows) {
        let root = root.to_string_lossy().to_lowercase();
        let path = path.to_string_lossy().to_lowercase();
        path == root || path.starts_with(&(root.trim_end_matches('\\').to_owned() + "\\"))
    } else {
        path.starts_with(root)
    }
}
impl Environment {
    fn guard(&self, path: &Path, cwd: &Path) -> io::Result<()> {
        if path.as_os_str().is_empty() {
            return Ok(());
        }
        let absolute = absolute(path, cwd);
        let resolved = physical(&absolute)?;
        let inside_real_profile = self
            .real_profiles
            .iter()
            .any(|real| within(real, &resolved));
        if !within(&physical(&self.root)?, &resolved) || inside_real_profile {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                format!(
                    "test profile isolation rejected unowned path: {}",
                    path.display()
                ),
            ));
        }
        Ok(())
    }
}

/// No mutable deref: every spawn/output/status must pass admission after all
/// arguments and environment overrides have been applied.
pub struct TestCommand {
    command: Command,
    raw: Option<String>,
}
pub fn test_command(program: impl AsRef<OsStr>) -> TestCommand {
    let env = environment();
    let mut command = Command::new(program);
    command.env_clear().envs(&env.variables);
    command.current_dir(&env.root);
    TestCommand { command, raw: None }
}
impl std::ops::Deref for TestCommand {
    type Target = Command;
    fn deref(&self) -> &Command {
        &self.command
    }
}
impl TestCommand {
    pub fn profile(&mut self, root: &Path) -> &mut Self {
        for key in PROFILE_KEYS {
            self.command.env(key, root);
        }
        self.command.env("CODEX_HOME", root.join("codex"));
        self.command
            .env("CODEX_SESSIONS_COLLECTOR_QUEUE", root.join("queue"));
        // Unix socket paths are limited to 104 bytes, which nested fixture roots
        // exceed. Every command for the same root gets the same short directory.
        #[cfg(unix)]
        {
            use std::hash::{DefaultHasher, Hash, Hasher};
            let mut hasher = DefaultHasher::new();
            root.hash(&mut hasher);
            let runtime = test_root()
                .join("u")
                .join(format!("{:08x}", hasher.finish() as u32));
            self.command.env("XDG_RUNTIME_DIR", runtime);
        }
        self
    }
    pub fn arg(&mut self, arg: impl AsRef<OsStr>) -> &mut Self {
        self.command.arg(arg);
        self
    }
    pub fn args<I, S>(&mut self, args: I) -> &mut Self
    where
        I: IntoIterator<Item = S>,
        S: AsRef<OsStr>,
    {
        self.command.args(args);
        self
    }
    pub fn env(&mut self, key: impl AsRef<OsStr>, value: impl AsRef<OsStr>) -> &mut Self {
        self.command.env(env_key(key.as_ref()), value);
        self
    }
    pub fn envs<I, K, V>(&mut self, vars: I) -> &mut Self
    where
        I: IntoIterator<Item = (K, V)>,
        K: AsRef<OsStr>,
        V: AsRef<OsStr>,
    {
        for (key, value) in vars {
            self.command.env(env_key(key.as_ref()), value);
        }
        self
    }
    pub fn env_remove(&mut self, key: impl AsRef<OsStr>) -> &mut Self {
        self.command.env_remove(env_key(key.as_ref()));
        self
    }
    pub fn current_dir(&mut self, path: impl AsRef<Path>) -> &mut Self {
        self.command.current_dir(path);
        self
    }
    pub fn stdin(&mut self, value: impl Into<Stdio>) -> &mut Self {
        self.command.stdin(value);
        self
    }
    pub fn stdout(&mut self, value: impl Into<Stdio>) -> &mut Self {
        self.command.stdout(value);
        self
    }
    pub fn stderr(&mut self, value: impl Into<Stdio>) -> &mut Self {
        self.command.stderr(value);
        self
    }
    #[cfg(windows)]
    pub fn creation_flags(&mut self, flags: u32) -> &mut Self {
        use std::os::windows::process::CommandExt;
        self.command.creation_flags(flags);
        self
    }
    #[cfg(windows)]
    pub fn raw_arg(&mut self, value: impl AsRef<OsStr>) -> &mut Self {
        use std::os::windows::process::CommandExt;
        assert!(
            self.raw.is_none(),
            "test profile isolation rejects repeated raw arguments"
        );
        self.raw = Some(value.as_ref().to_string_lossy().into_owned());
        self.command.raw_arg(value);
        self
    }
    #[cfg(unix)]
    pub fn process_group(&mut self, group: i32) -> &mut Self {
        use std::os::unix::process::CommandExt;
        self.command.process_group(group);
        self
    }
    pub fn spawn_with_input(&mut self, input: &str) -> io::Result<Child> {
        use std::io::Write;
        self.admit()?;
        if let Ok(value) = serde_json::from_str::<serde_json::Value>(input)
            && let Some(path) = value
                .get("transcript_path")
                .and_then(serde_json::Value::as_str)
        {
            let cwd = self.command.get_current_dir().unwrap_or(test_root());
            let mut access_path = path.to_owned();
            if cfg!(windows) && path.starts_with('/') {
                let args: Vec<_> = self.command.get_args().collect();
                let root = args
                    .windows(2)
                    .find(|pair| pair[0] == "--wsl-unc-root")
                    .and_then(|pair| pair[1].to_str())
                    .ok_or_else(|| {
                        io::Error::new(
                            io::ErrorKind::PermissionDenied,
                            "test hook requires an explicit owned WSL mapping",
                        )
                    })?;
                environment().guard(Path::new(root), cwd)?;
                access_path = codex_sessions_collector::path_mapping::PathMapper::new(root)
                    .hook_access_path(path)
                    .ok_or_else(|| {
                        io::Error::new(
                            io::ErrorKind::PermissionDenied,
                            "test hook WSL mapping is unresolved",
                        )
                    })?;
            }
            environment().guard(Path::new(&access_path), cwd)?;
        }
        self.command.stdin(Stdio::piped());
        let mut child = self.command.spawn()?;
        if let Err(error) = child.stdin.take().unwrap().write_all(input.as_bytes()) {
            let _ = child.kill();
            let _ = child.wait();
            return Err(error);
        }
        Ok(child)
    }
    pub fn spawn(&mut self) -> io::Result<Child> {
        let timings = self
            .command
            .get_envs()
            .any(|(key, value)| key == "CODEX_SESSIONS_COLLECTOR_TIMINGS" && value.is_some());
        let started = timings.then(std::time::Instant::now);
        self.admit()?;
        if timings
            && self
                .command
                .get_args()
                .take(2)
                .eq([OsStr::new("codex"), OsStr::new("notify")])
        {
            eprintln!(
                "test hook child environment {:?}",
                self.command.get_envs().collect::<Vec<_>>()
            );
        }
        let admitted = timings.then(std::time::Instant::now);
        let child = self.command.spawn();
        if child.is_ok()
            && self
                .command
                .get_program()
                .to_string_lossy()
                .contains("sessions-hub")
            && let Some(address) = self.command.get_args().next()
        {
            own_endpoint(&format!("http://{}", address.to_string_lossy()));
        }
        if let (Some(started), Some(admitted)) = (started, admitted) {
            eprintln!(
                "test child admission_ms={:.3} spawn_ms={:.3}",
                (admitted - started).as_secs_f64() * 1000.0,
                admitted.elapsed().as_secs_f64() * 1000.0
            );
        }
        child
    }
    pub fn output(&mut self) -> io::Result<Output> {
        self.admit()?;
        self.command.output()
    }
    pub fn status(&mut self) -> io::Result<ExitStatus> {
        self.admit()?;
        self.command.status()
    }

    fn admit(&self) -> io::Result<()> {
        let env = environment();
        let cwd = self
            .command
            .get_current_dir()
            .map(PathBuf::from)
            .unwrap_or(std::env::current_dir()?);
        let variables: BTreeMap<_, _> = self
            .command
            .get_envs()
            .filter_map(|(key, value)| value.map(|value| (key, value)))
            .collect();
        admit_executable(&self.command, self.raw.as_deref(), &cwd)?;
        let system: BTreeMap<OsString, OsString> = variables
            .iter()
            .map(|(k, v)| ((*k).to_owned(), (*v).to_owned()))
            .collect();
        guard_system(&system, &env.real_profiles)?;
        for (key, value) in &variables {
            let name = key.to_string_lossy();
            if !PROFILE_KEYS.contains(&name.as_ref())
                && !SYSTEM_KEYS.contains(&name.as_ref())
                && ![
                    "PATH",
                    "SYSTEMROOT",
                    "WINDIR",
                    "COMSPEC",
                    "PATHEXT",
                    "CODEX_SESSIONS_COLLECTOR_BUSY_TIMEOUT_MS",
                    "CODEX_SESSIONS_COLLECTOR_TIMINGS",
                    "CODEX_SESSIONS_HUB_MACHINE_TOKEN",
                    "CODEX_SESSIONS_HUB_OWNER_TOKEN",
                    "CSV_TEST_LEASE_CHILD",
                    "CXV_HANDLE_CHECK_CHILD",
                    "CSV_COMPUTER_USE_TEST_SINK",
                    "CSV_COMPUTER_USE_TEST_MODE",
                ]
                .contains(&name.as_ref())
            {
                return Err(denied(format!("unlisted environment key {name}")));
            }
            if SYSTEM_KEYS.contains(&name.as_ref())
                && env.variables.get(*key).map(OsString::as_os_str) != Some(*value)
            {
                return Err(denied(format!("system override: {name}")));
            }
            if name == "CSV_TEST_LEASE_CHILD" {
                env.guard(Path::new(value), &cwd)?;
            }
            if name == "CSV_COMPUTER_USE_TEST_SINK" {
                env.guard(Path::new(value), &cwd)?;
            }
            if name == "CSV_COMPUTER_USE_TEST_MODE"
                && ![OsStr::new(""), OsStr::new("fail"), OsStr::new("timeout")].contains(value)
            {
                return Err(denied("invalid computer-use fixture mode"));
            }
        }
        let mut profile_paths = std::collections::BTreeSet::new();
        for key in PROFILE_KEYS {
            let value = variables.get(OsStr::new(key)).ok_or_else(|| {
                io::Error::other(format!("test profile isolation requires {key}"))
            })?;
            // Queue paths are explicitly relative to the caller's cwd in the
            // detached-drain contract. Resolve and guard that one path below;
            // profile homes must stay absolute because descendants can change cwd.
            if *key != "CODEX_SESSIONS_COLLECTOR_QUEUE" && !Path::new(value).is_absolute() {
                return Err(denied(format!("profile variable must be absolute: {key}")));
            }
            profile_paths.insert(absolute(Path::new(value), &cwd));
        }
        for (key, value) in &variables {
            let key = key.to_string_lossy();
            if key.starts_with("CODEX_SESSIONS_COLLECTOR_")
                && ![
                    "CODEX_SESSIONS_COLLECTOR_EXE",
                    "CODEX_SESSIONS_COLLECTOR_BUSY_TIMEOUT_MS",
                    "CODEX_SESSIONS_COLLECTOR_TIMINGS",
                ]
                .contains(&key.as_ref())
            {
                profile_paths.insert(absolute(Path::new(value), &cwd));
            }
        }
        // A fixture can assign the same owned root to every profile variable.
        // Resolve each distinct location once per launch, still after overrides.
        for path in profile_paths {
            env.guard(&path, &cwd)?;
        }
        let args: Vec<_> = self
            .command
            .get_args()
            .map(|a| a.to_string_lossy().into_owned())
            .collect();
        let flags = [
            "--db",
            "--standalone",
            "--settings",
            "--root",
            "--input",
            "--claude-wsl-root",
            "--windows-root",
            "--wsl-root",
            "--wsl-unc-root",
            "--claude-root",
            "--queue",
            "--log",
            "--output",
            "--config",
            "--data-dir",
            "--command-file",
        ];
        let mut index = 0;
        while index < args.len() {
            let (flag, inline) = args[index]
                .split_once('=')
                .map_or((args[index].as_str(), None), |(k, v)| (k, Some(v)));
            if flags.contains(&flag) {
                let value = if let Some(value) = inline {
                    value
                } else {
                    index += 1;
                    args.get(index).map_or("", String::as_str)
                };
                env.guard(Path::new(value), &cwd)?;
                if flag == "--settings" {
                    guard_settings(env, &absolute(Path::new(value), &cwd), &cwd)?;
                }
            }
            index += 1;
        }
        let program = self.command.get_program().to_string_lossy();
        if args.len() >= 2
            && matches!(args[0].as_str(), "codex" | "claude")
            && matches!(args[1].as_str(), "ingest" | "parse")
        {
            let switches = [
                "--no-drain",
                "--no-wait",
                "--no-wsl-projects",
                "--force",
                "--json",
                "--progress-json",
                "--cancel-stdin",
            ];
            let mut i = 2;
            while i < args.len() {
                if args[i].starts_with("--") {
                    if !args[i].contains('=') && !switches.contains(&args[i].as_str()) {
                        i += 1;
                    }
                } else {
                    env.guard(Path::new(&args[i]), &cwd)?;
                }
                i += 1;
            }
        }
        if program.contains("codex-sessions-") {
            env.guard(&cwd, &cwd)?;
        }
        if program.contains("codex-sessions-hub") && args.len() >= 3 {
            env.guard(Path::new(&args[1]), &cwd)?;
            env.guard(Path::new(&args[2]), &cwd)?;
        }
        // Resolve the same defaults as the binary, not just explicit flags.
        let platform = if cfg!(windows) {
            codex_sessions_collector::platform_locations::HostPlatform::Windows
        } else if cfg!(target_os = "macos") {
            codex_sessions_collector::platform_locations::HostPlatform::Macos
        } else {
            codex_sessions_collector::platform_locations::HostPlatform::Linux
        };
        if program.contains("codex-sessions-")
            && let Some(locations) =
                codex_sessions_collector::platform_locations::PlatformLocations::resolve(
                    platform,
                    |key| {
                        variables
                            .get(OsStr::new(key))
                            .map(|s| s.to_string_lossy().into_owned())
                    },
                    Path::new(self.command.get_program()),
                )
        {
            if !args
                .iter()
                .any(|arg| arg == "--settings" || arg.starts_with("--settings="))
            {
                guard_settings(env, &absolute(&locations.settings_file, &cwd), &cwd)?;
            }
            if let Some(parent) = locations.queue_dir.parent() {
                env.guard(&parent.join("resident.log"), &cwd)?;
                env.guard(&parent.join("resident.log.1"), &cwd)?;
            }
            for (key, suffix) in [
                ("USERPROFILE", ".claude/projects"),
                ("CODEX_HOME", "config.toml"),
                ("CLAUDE_CONFIG_DIR", "settings.json"),
            ] {
                if let Some(base) = variables.get(OsStr::new(key)) {
                    env.guard(&Path::new(base).join(suffix), &cwd)?;
                }
            }
            for path in [
                locations.database_file,
                locations.settings_file,
                locations.log_dir,
                locations.queue_dir,
                locations.runtime_dir,
                locations.backup_dir,
            ] {
                env.guard(&path, &cwd)?;
            }
        }
        Ok(())
    }
}
fn guard_settings(env: &Environment, path: &Path, cwd: &Path) -> io::Result<()> {
    env.guard(path, cwd)?;
    if !path.is_file() {
        return Ok(());
    }
    let text = std::fs::read_to_string(path)?;
    let settings = text
        .parse::<toml::Table>()
        .map_err(|error| denied(format!("cannot parse settings: {error}")))?;
    if let Some(url) = settings
        .get("hub")
        .and_then(|v| v.get("url"))
        .and_then(toml::Value::as_str)
        .filter(|s| !s.is_empty())
    {
        guard_endpoint(url)?;
    }
    for section in ["paths", "logging", "wsl"] {
        if let Some(table) = settings.get(section).and_then(toml::Value::as_table) {
            for (key, value) in table {
                if (key.ends_with("_path")
                    || key.contains("root")
                    || key == "log_file"
                    || key == "linux_root_unc")
                    && let Some(value) = value.as_str()
                {
                    env.guard(Path::new(value), cwd)?;
                }
            }
        }
    }
    Ok(())
}

fn env_key(key: &OsStr) -> OsString {
    if cfg!(windows) {
        key.to_string_lossy().to_uppercase().into()
    } else {
        key.to_owned()
    }
}
fn denied(message: impl Into<String>) -> io::Error {
    io::Error::new(
        io::ErrorKind::PermissionDenied,
        format!("test profile isolation: {}", message.into()),
    )
}
fn tool(program: &OsStr) -> io::Result<PathBuf> {
    let path = Path::new(program);
    if path.is_absolute() {
        return std::fs::canonicalize(path);
    }
    let suffix = if cfg!(windows) { ".exe" } else { "" };
    for folder in std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default()) {
        let name = program.to_string_lossy();
        let candidate = folder.join(if name.ends_with(suffix) {
            name.into_owned()
        } else {
            format!("{name}{suffix}")
        });
        if candidate.is_file() {
            return std::fs::canonicalize(candidate);
        }
    }
    Err(denied("unknown executable"))
}
fn admit_executable(command: &Command, raw: Option<&str>, cwd: &Path) -> io::Result<()> {
    let program = tool(command.get_program()).map_err(|_| denied("unknown executable"))?;
    let target = Path::new(env!("CARGO_MANIFEST_DIR")).join("target");
    let native = [
        env!("CARGO_BIN_EXE_codex-sessions-collector"),
        env!("CARGO_BIN_EXE_codex-sessions-hub"),
        env!("CARGO_BIN_EXE_codex-sessions-scan-launcher"),
    ];
    let args: Vec<String> = command
        .get_args()
        .map(|s| s.to_string_lossy().into_owned())
        .collect();
    let compiler_name = if cfg!(windows) { "rustc.exe" } else { "rustc" };
    if program.file_name() == Some(OsStr::new(compiler_name)) {
        let rustup = std::env::var_os("RUSTUP_HOME")
            .map(PathBuf::from)
            .or_else(|| {
                std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
                    .map(|home| PathBuf::from(home).join(".rustup"))
            })
            .ok_or_else(|| denied("no original Rust toolchain home"))?;
        let toolchains = physical(&rustup.join("toolchains"))?;
        let valid_location = program.parent().is_some_and(|bin| {
            bin.file_name() == Some(OsStr::new("bin"))
                && bin.parent().and_then(Path::parent) == Some(toolchains.as_path())
        });
        if !valid_location || raw.is_some() || args.len() != 3 || args[1] != "-o" {
            return Err(denied("unlisted compiler location or arguments"));
        }
        let source = Path::new(&args[0]);
        let output = Path::new(&args[2]);
        environment().guard(source, cwd)?;
        environment().guard(output, cwd)?;
        let source = physical(&absolute(source, cwd))?;
        let output = physical(&absolute(output, cwd))?;
        let helper_name = if cfg!(windows) {
            "codex-computer-use.exe"
        } else {
            "codex-computer-use"
        };
        if source.file_name() != Some(OsStr::new("computer_use_fixture.rs"))
            || output.file_name() != Some(OsStr::new(helper_name))
            || source.parent() != output.parent()
        {
            return Err(denied(
                "compiler requires sibling computer-use fixture source and output",
            ));
        }
        return Ok(());
    }
    if native
        .iter()
        .any(|p| Path::new(p) == Path::new(command.get_program()))
        && within(&physical(&target)?, &program)
    {
        if raw.is_some() {
            return Err(denied("raw native arguments"));
        }
        // These exact invalid invocations exercise the product's usage diagnostics;
        // neither can execute a command or consume a caller-supplied path.
        if args == ["codex", "scan", "--frobnicate"]
            || args == ["claude", "setup", "--json", "--config"]
            || args == ["codex", "verify", "--bogus-secret-value", "--json"]
        {
            return Ok(());
        }
        if command
            .get_program()
            .to_string_lossy()
            .contains("sessions-hub")
        {
            if args.len() != 3
                || args[0].parse::<std::net::SocketAddr>().is_err()
                || !args[0].starts_with("127.0.0.1:")
            {
                return Err(denied("invalid fixture hub arguments"));
            }
            environment().guard(Path::new(&args[1]), cwd)?;
            environment().guard(Path::new(&args[2]), cwd)?;
            return Ok(());
        }
        return admit_native_args(&args, cwd);
    }
    if program == std::fs::canonicalize(std::env::current_exe()?)?
        && raw.is_none()
        && args.len() == 3
        && args[0] == "--exact"
        && args[2] == "--nocapture"
        && [
            "lease_child_helper",
            "protocol_windows_first_instance_security_and_handle_cleanup",
        ]
        .contains(&args[1].as_str())
    {
        return Ok(());
    }
    #[cfg(windows)]
    {
        let system =
            PathBuf::from(std::env::var_os("SYSTEMROOT").ok_or_else(|| denied("no system root"))?)
                .join("System32");
        if program == std::fs::canonicalize(system.join("cmd.exe"))? {
            if raw.is_none() && args.len() == 5 && args[..3] == ["/c", "mklink", "/J"] {
                environment().guard(Path::new(&args[3]), cwd)?;
                environment().guard(Path::new(&args[4]), cwd)?;
                return Ok(());
            }
            if args.len() >= 3
                && args[..3] == ["/D", "/S", "/C"]
                && let Some(raw) = raw
            {
                // Only generated managed lifecycle hooks are permitted through cmd.
                if raw.contains(['&', '|', '<', '>', '%', '^', '\n', '\r']) {
                    return Err(denied("shell metacharacter"));
                }
                let words = split_command(
                    raw.strip_prefix('"')
                        .and_then(|s| s.strip_suffix('"'))
                        .ok_or_else(|| denied("invalid hook quoting"))?,
                );
                if words.len() < 3 {
                    return Err(denied("invalid managed hook"));
                }
                let exe = tool(OsStr::new(&words[0]))?;
                if exe != std::fs::canonicalize(native[0])?
                    || !matches!(
                        (words[1].as_str(), words[2].as_str()),
                        ("claude" | "codex", "hook")
                    )
                {
                    return Err(denied("unmanaged hook"));
                }
                return admit_native_args(&words[1..], cwd);
            }
        }
        if program == std::fs::canonicalize(system.join("WindowsPowerShell/v1.0/powershell.exe"))?
            && raw.is_none()
            && args.len() == 4
            && args[..3] == ["-NoProfile", "-NonInteractive", "-Command"]
        {
            let prefix = "Get-CimInstance Win32_Process -Filter 'ParentProcessId=";
            let suffix = "' | Select-Object -ExpandProperty ProcessId";
            if args[3]
                .strip_prefix(prefix)
                .and_then(|s| s.strip_suffix(suffix))
                .and_then(|s| s.parse::<u32>().ok())
                .is_some()
            {
                return Ok(());
            }
        }
    }
    #[cfg(unix)]
    {
        // The detached process-group test chains a marker writer through
        // --previous-notify and then kills the hook's process group.
        if raw.is_none()
            && program == std::fs::canonicalize("/bin/sh")?
            && args.len() == 3
            && args[0] == "-c"
            && args[2] == "sh"
            && let Some(target) = args[1]
                .strip_prefix("sleep 1; echo alive > '")
                .and_then(|rest| rest.strip_suffix('\''))
        {
            environment().guard(Path::new(target), cwd)?;
            return Ok(());
        }
        if raw.is_none()
            && program == tool(OsStr::new("kill"))?
            && args.len() == 3
            && args[..2] == ["-KILL", "--"]
            && args[2]
                .strip_prefix('-')
                .is_some_and(|group| group.parse::<u32>().is_ok())
        {
            return Ok(());
        }
    }
    // Independent example parser is the only Python entry point.
    if raw.is_none()
        && program == tool(OsStr::new("python"))?
        && args.len() >= 2
        && Path::new(&args[0])
            == Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../samples/collector-contract/example_collector.py")
    {
        let source = physical(Path::new(&args[1]))?;
        let samples = physical(&Path::new(env!("CARGO_MANIFEST_DIR")).join("../samples"))?;
        if !within(&samples, &source) {
            environment().guard(Path::new(&args[1]), cwd)?;
        }
        if args.len() == 2
            || args.len() == 4
                && ["--harness", "--machine-id"].contains(&args[2].as_str())
                && ["another", "another-machine"].contains(&args[3].as_str())
        {
            return Ok(());
        }
    }
    Err(denied("executable/arguments are not explicitly allowed"))
}
fn split_command(text: &str) -> Vec<String> {
    let mut words = Vec::new();
    let mut word = String::new();
    let mut quoted = false;
    for ch in text.chars() {
        if ch == '"' {
            quoted = !quoted;
        } else if ch.is_whitespace() && !quoted {
            if !word.is_empty() {
                words.push(std::mem::take(&mut word));
            }
        } else {
            word.push(ch);
        }
    }
    if !word.is_empty() {
        words.push(word);
    }
    words
}
fn admit_native_args(args: &[String], cwd: &Path) -> io::Result<()> {
    if let Some(first) = args.first()
        && !first.starts_with("--")
    {
        if ![
            "codex",
            "claude",
            "query",
            "hub",
            "resident",
            "serve",
            "client",
            "drain",
            "apply",
            "version",
            "serve-replacement",
        ]
        .contains(&first.as_str())
        {
            return Err(denied("unlisted collector command"));
        }
        if ["codex", "claude"].contains(&first.as_str())
            && !args.get(1).is_some_and(|s| {
                [
                    "setup",
                    "verify",
                    "status",
                    "scan",
                    "ingest",
                    "parse",
                    "notify",
                    "hook",
                    "computer-use-hook",
                ]
                .contains(&s.as_str())
            })
        {
            return Err(denied("unlisted harness command"));
        }
        if first == "resident"
            && !args
                .get(1)
                .is_some_and(|s| ["stop", "status", "info"].contains(&s.as_str()))
        {
            return Err(denied("unlisted resident command"));
        }
    }
    let paths = [
        "--db",
        "--standalone",
        "--settings",
        "--input",
        "--root",
        "--config",
        "--windows-root",
        "--wsl-root",
        "--wsl-unc-root",
        "--claude-root",
        "--claude-wsl-root",
        "--queue",
        "--log",
        "--output",
        "--data-dir",
        "--command-file",
    ];
    let values = [
        "--replacement-deadline-ms",
        "--hub",
        "--hub-machine",
        "--index",
        "--machine",
        "--export-format",
        "--max-chars",
        "--max-messages",
        "--lifetime",
        "--parser-workers",
        "--flush-sessions",
        "--flush-bytes",
        "--hub-url",
        "--bind",
        "--previous-notify",
        "--query",
        "--limit",
        "--offset",
        "--session",
        "--ref",
        "--chars",
        "--after-index",
        "--text-offset",
        "--cursor",
        "--path",
        "--project",
        "--since",
        "--until",
        "--harness",
        "--format",
    ];
    let switches = [
        "--no-drain",
        "--no-wait",
        "--no-wsl-projects",
        "--force",
        "--json",
        "--progress-json",
        "--cancel-stdin",
        "--help",
        "--apply",
        "--remove",
        "--local-proof",
        "--check-hub",
        "--include-tools",
    ];
    let mut i = 0;
    while i < args.len() {
        let (flag, inline) = args[i]
            .split_once('=')
            .map_or((args[i].as_str(), None), |(a, b)| (a, Some(b)));
        if flag.starts_with("--") && !switches.contains(&flag) {
            if !paths.contains(&flag) && !values.contains(&flag) {
                return Err(denied(format!("unlisted option {flag}")));
            }
            let value = if let Some(v) = inline {
                v
            } else {
                i += 1;
                args.get(i).ok_or_else(|| denied("missing argument"))?
            };
            if flag == "--replacement-deadline-ms"
                && (args.first().map(String::as_str) != Some("serve-replacement")
                    || value.parse::<u64>().is_err())
            {
                return Err(denied("invalid replacement deadline"));
            }
            if paths.contains(&flag) {
                environment().guard(Path::new(value), cwd)?;
            }
            if ["--hub-url", "--hub"].contains(&flag) {
                guard_endpoint(value)?;
            }
            if flag == "--bind"
                && !value
                    .parse::<std::net::SocketAddr>()
                    .is_ok_and(|a| a.ip().is_loopback())
            {
                return Err(denied("non-loopback network bind endpoint"));
            }
            if flag == "--previous-notify" {
                let previous: Vec<String> =
                    serde_json::from_str(value).map_err(|_| denied("invalid previous notify"))?;
                if previous.is_empty() {
                    return Err(denied("empty previous notify"));
                }
                if previous.len() == 1 && !Path::new(&previous[0]).exists() {
                    environment().guard(Path::new(&previous[0]), cwd)?;
                } else {
                    let mut nested = test_command(&previous[0]);
                    nested.args(&previous[1..]);
                    nested.admit()?;
                }
            }
        }
        i += 1;
    }
    Ok(())
}
