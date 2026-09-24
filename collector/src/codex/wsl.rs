//! Port of `ProcessWslProjectResolver`: asks WSL for each working
//! directory's git root, falling back silently when WSL is unavailable.

use std::collections::{HashMap, HashSet};
use std::io::Write;
use std::process::{Command, Stdio};

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

/// Project names for WSL working directories, keyed by trimmed path.
pub fn resolve_project_names(paths: &[String]) -> HashMap<String, String> {
    let mut unique: Vec<&str> = Vec::new();
    let mut seen: HashSet<&str> = HashSet::new();
    for path in paths {
        let path = trim(path);
        if !path.is_empty() && seen.insert(path) {
            unique.push(path);
        }
    }
    if unique.is_empty() {
        return HashMap::new();
    }
    let child = Command::new("wsl.exe")
        .args(["sh", "-lc", SCRIPT])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn();
    let Ok(mut child) = child else {
        return HashMap::new();
    };
    let input: String = unique.iter().map(|path| format!("{path}\n")).collect();
    // Feed stdin from a thread so a full stdout pipe cannot deadlock us.
    let stdin = child.stdin.take();
    let writer = std::thread::spawn(move || {
        if let Some(mut stdin) = stdin {
            let _ = stdin.write_all(input.as_bytes());
        }
    });
    let output = child.wait_with_output();
    let _ = writer.join();
    let Ok(output) = output else {
        return HashMap::new();
    };
    if !output.status.success() {
        return HashMap::new();
    }
    let requested: HashSet<&str> = unique.into_iter().collect();
    let text = String::from_utf8_lossy(&output.stdout);
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
