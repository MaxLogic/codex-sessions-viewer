//! Port of `ProcessWslProjectResolver`: asks WSL for each working
//! directory's git root, falling back silently when WSL is unavailable.

use std::collections::{HashMap, HashSet};
use std::io::{Read, Write};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Sender};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use crate::dart::trim;

const SCRIPT: &str = r#"
while IFS= read -r path; do
  if [ -z "$path" ]; then
    continue
  fi
  if cd "$path" 2>/dev/null; then
    root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
    name=$(basename "$root")
    if [ -n "$name" ]; then
      printf '%s\t%s\n' "$path" "$name"
    fi
  fi
done
"#;

/// The resolver command. `-e` runs `sh` directly: without it `wsl.exe`
/// hands the whole command line to the default shell, which reparses the
/// script and resolves nothing (T-171).
fn wsl_command() -> Command {
    let mut command = Command::new("wsl.exe");
    command.args(["-e", "sh", "-lc", SCRIPT]);
    command
}

/// How long [`ProjectResolver::resolve`] waits for the resolver. It covers a
/// cold WSL start (11-14 s measured) plus the git lookups; past it the
/// resolver is killed and the sessions keep folder-name projects.
pub const RESOLVE_TIMEOUT: Duration = Duration::from_secs(60);

/// Project names for WSL working directories, keyed by trimmed path.
pub fn resolve_project_names(paths: &[String]) -> HashMap<String, String> {
    if unique_paths(paths).is_empty() {
        return HashMap::new();
    }
    ProjectResolver::for_current_platform().resolve(paths, &AtomicBool::new(false), RESOLVE_TIMEOUT)
}

/// A `wsl.exe` resolver that takes paths while the scan still parses.
///
/// The first `wsl.exe` command into a distro that only served
/// `\\wsl.localhost` reads waits 11-14 s for WSL start-up (T-171). Starting
/// the resolver at the first WSL session and streaming paths to it as they
/// are parsed lets both that wait and the git lookups overlap parsing.
/// [`ProjectResolver::push`] never blocks: a thread feeds stdin and another
/// drains stdout. Dropping an unfinished resolver kills the process.
pub struct ProjectResolver {
    child: Option<Child>,
    paths: Option<Sender<String>>,
    sent: HashSet<String>,
    writer: Option<JoinHandle<()>>,
    reader: Option<JoinHandle<Vec<u8>>>,
}

impl ProjectResolver {
    /// The `wsl.exe` resolver on Windows; elsewhere, including a collector
    /// running inside WSL, a resolver that resolves nothing, so WSL
    /// sessions keep folder-name projects.
    pub fn for_current_platform() -> Self {
        if cfg!(windows) {
            Self::spawn(wsl_command())
        } else {
            Self::none()
        }
    }

    fn none() -> Self {
        Self {
            child: None,
            paths: None,
            sent: HashSet::new(),
            writer: None,
            reader: None,
        }
    }

    fn spawn(mut command: Command) -> Self {
        let mut resolver = Self::none();
        let Ok(mut child) = command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
        else {
            return resolver;
        };
        let (sender, receiver) = mpsc::channel::<String>();
        if let Some(mut stdin) = child.stdin.take() {
            resolver.writer = Some(std::thread::spawn(move || {
                for line in receiver {
                    if stdin.write_all(line.as_bytes()).is_err() {
                        break;
                    }
                }
            }));
        }
        if let Some(mut stdout) = child.stdout.take() {
            resolver.reader = Some(std::thread::spawn(move || {
                let mut output = Vec::new();
                let _ = stdout.read_to_end(&mut output);
                output
            }));
        }
        resolver.paths = Some(sender);
        resolver.child = Some(child);
        resolver
    }

    /// Queue one working directory; blank and repeated paths are skipped.
    pub fn push(&mut self, path: &str) {
        let path = trim(path);
        if path.is_empty() || self.sent.contains(path) {
            return;
        }
        if let Some(sender) = &self.paths
            && sender.send(format!("{path}\n")).is_ok()
        {
            self.sent.insert(path.to_owned());
        }
    }

    /// Project names for `paths`, keyed by trimmed path. Paths not pushed
    /// yet are sent now. Empty when WSL is unavailable, the resolver failed,
    /// `cancel` was set, or it did not finish within `timeout`; a resolver
    /// still running then is killed.
    pub fn resolve(
        mut self,
        paths: &[String],
        cancel: &AtomicBool,
        timeout: Duration,
    ) -> HashMap<String, String> {
        let unique = unique_paths(paths);
        if unique.is_empty() {
            return HashMap::new();
        }
        for path in &unique {
            self.push(path);
        }
        if self.child.is_none() {
            return HashMap::new();
        }
        // Closing the channel ends the writer, which closes stdin, which
        // ends the script.
        self.paths = None;
        let deadline = Instant::now() + timeout;
        let status = loop {
            let exited = self
                .child
                .as_mut()
                .and_then(|child| child.try_wait().ok().flatten());
            let drained = self.reader.as_ref().is_none_or(JoinHandle::is_finished);
            if let Some(status) = exited
                && drained
            {
                break status;
            }
            if cancel.load(Ordering::Relaxed) || Instant::now() >= deadline {
                // Drop kills the child; the threads end once its pipes close.
                return HashMap::new();
            }
            std::thread::sleep(Duration::from_millis(10));
        };
        self.child = None;
        if let Some(writer) = self.writer.take() {
            let _ = writer.join();
        }
        let output = self
            .reader
            .take()
            .and_then(|reader| reader.join().ok())
            .unwrap_or_default();
        if !status.success() {
            return HashMap::new();
        }
        parse_output(&String::from_utf8_lossy(&output), &unique)
    }
}

impl Drop for ProjectResolver {
    fn drop(&mut self) {
        self.paths = None;
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

/// `path<TAB>name` lines for the requested paths; other lines are ignored.
fn parse_output(text: &str, requested: &[&str]) -> HashMap<String, String> {
    let requested: HashSet<&str> = requested.iter().copied().collect();
    let mut resolved = HashMap::new();
    for line in text.split(['\n', '\r']) {
        let Some(separator) = line.find('\t') else {
            continue;
        };
        if separator == 0 {
            continue;
        }
        let path = &line[..separator];
        let name = trim(&line[separator + 1..]);
        if requested.contains(path) && !name.is_empty() {
            resolved.insert(path.to_owned(), name.to_owned());
        }
    }
    resolved
}

fn unique_paths(paths: &[String]) -> Vec<&str> {
    let mut unique: Vec<&str> = Vec::new();
    let mut seen: HashSet<&str> = HashSet::new();
    for path in paths {
        let path = trim(path);
        if !path.is_empty() && seen.insert(path) {
            unique.push(path);
        }
    }
    unique
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_resolver_runs_sh_directly_instead_of_through_the_default_shell() {
        let command = wsl_command();
        assert_eq!(command.get_program(), "wsl.exe");
        let args: Vec<_> = command.get_args().collect();
        assert_eq!(args, ["-e", "sh", "-lc", SCRIPT]);
    }

    #[test]
    fn output_lines_map_requested_paths_to_trimmed_names() {
        let text = "/mnt/f/a\tproj-a\r\n/mnt/f/b\t  proj b \n\
                    /mnt/f/unasked\tx\n\tno-path\n/mnt/f/c\t\nnot a record\n";
        let resolved = parse_output(text, &["/mnt/f/a", "/mnt/f/b", "/mnt/f/c"]);
        let expected: HashMap<String, String> = [
            ("/mnt/f/a".to_owned(), "proj-a".to_owned()),
            ("/mnt/f/b".to_owned(), "proj b".to_owned()),
        ]
        .into();
        assert_eq!(resolved, expected);
    }

    #[test]
    fn a_resolver_that_cannot_start_resolves_nothing() {
        let mut resolver =
            ProjectResolver::spawn(Command::new("codex-sessions-no-such-program-t171"));
        resolver.push("/home/someone");
        let resolved = resolver.resolve(
            &["/home/someone".to_owned()],
            &AtomicBool::new(false),
            RESOLVE_TIMEOUT,
        );
        assert!(resolved.is_empty());
    }

    /// A resolver that never reads its input and runs for a minute.
    fn stuck_resolver() -> ProjectResolver {
        let mut command = if cfg!(windows) {
            let mut ping = Command::new("ping");
            ping.args(["-n", "60", "127.0.0.1"]);
            ping
        } else {
            let mut sleep = Command::new("sleep");
            sleep.arg("60");
            sleep
        };
        command.stdin(Stdio::piped());
        let resolver = ProjectResolver::spawn(command);
        assert!(
            resolver.child.is_some(),
            "the stand-in process did not start"
        );
        resolver
    }

    #[test]
    fn a_stuck_resolver_is_killed_at_the_deadline() {
        let started = Instant::now();
        let resolved = stuck_resolver().resolve(
            &["/mnt/stuck".to_owned()],
            &AtomicBool::new(false),
            Duration::from_millis(300),
        );
        assert!(resolved.is_empty());
        assert!(
            started.elapsed() < Duration::from_secs(10),
            "{:?}",
            started.elapsed()
        );
    }

    #[test]
    fn cancelling_stops_a_resolver_that_is_still_starting() {
        let cancel = std::sync::Arc::new(AtomicBool::new(false));
        let setter = {
            let cancel = cancel.clone();
            std::thread::spawn(move || {
                std::thread::sleep(Duration::from_millis(200));
                cancel.store(true, Ordering::Relaxed);
            })
        };
        let started = Instant::now();
        let resolved =
            stuck_resolver().resolve(&["/mnt/stuck".to_owned()], &cancel, RESOLVE_TIMEOUT);
        setter.join().unwrap();
        assert!(resolved.is_empty());
        assert!(
            started.elapsed() < Duration::from_secs(10),
            "{:?}",
            started.elapsed()
        );
    }

    #[cfg(not(windows))]
    #[test]
    fn outside_windows_the_resolver_never_spawns_wsl_exe() {
        let mut resolver = ProjectResolver::for_current_platform();
        assert!(resolver.child.is_none());
        resolver.push("/home/someone");
        let resolved = resolver.resolve(
            &["/home/someone".to_owned()],
            &AtomicBool::new(false),
            RESOLVE_TIMEOUT,
        );
        assert!(resolved.is_empty());
    }

    /// Runs the real script through `sh` with streamed paths, so the script
    /// and the streaming are proven without `wsl.exe`. The fixture lives
    /// under `std::env::temp_dir()`, which must not sit inside a git
    /// repository, or the plain folder would resolve to that repository.
    #[cfg(unix)]
    #[test]
    fn the_script_names_git_roots_and_folders_from_streamed_paths() {
        let git = |args: &[&str], dir: &std::path::Path| {
            Command::new("git")
                .args(args)
                .current_dir(dir)
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()
                .is_ok_and(|status| status.success())
        };
        let base = std::env::temp_dir().join(format!("wsl-resolver-{}", std::process::id()));
        let repo = base.join("repo-root");
        let nested = repo.join("src").join("deep");
        let plain = base.join("plain folder");
        std::fs::create_dir_all(&nested).unwrap();
        std::fs::create_dir_all(&plain).unwrap();
        if !git(&["init", "-q"], &repo) {
            let _ = std::fs::remove_dir_all(&base);
            eprintln!("git is not installed; skipping");
            return;
        }
        let path = |dir: &std::path::Path| dir.to_string_lossy().into_owned();
        let missing = path(&base.join("missing"));
        let mut command = Command::new("sh");
        command.args(["-c", SCRIPT]);
        let mut resolver = ProjectResolver::spawn(command);
        resolver.push(&path(&nested));
        resolver.push(&path(&nested));
        let requested = [path(&nested), path(&plain), missing.clone(), path(&repo)];
        let resolved = resolver.resolve(&requested, &AtomicBool::new(false), RESOLVE_TIMEOUT);
        let _ = std::fs::remove_dir_all(&base);
        let expected: HashMap<String, String> = [
            (path(&nested), "repo-root".to_owned()),
            (path(&repo), "repo-root".to_owned()),
            (path(&plain), "plain folder".to_owned()),
        ]
        .into();
        assert_eq!(resolved, expected);
    }
}
