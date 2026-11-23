use std::collections::VecDeque;
use std::io::{self, BufRead, BufReader, Read};
use std::net::{Ipv4Addr, SocketAddrV4};
use std::path::Path;
use std::process::{Child, Stdio};
use std::sync::mpsc;
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use super::{own_endpoint, test_command};

const STARTUP_TIMEOUT: Duration = Duration::from_secs(10);
const READY_PREFIX: &str = "hub listening on http://";
const DIAGNOSTIC_LIMIT: usize = 64 * 1024;

#[derive(Default)]
struct OutputTail {
    bytes: VecDeque<u8>,
    truncated: bool,
}

impl OutputTail {
    fn append(&mut self, bytes: &[u8]) {
        debug_assert!(bytes.len() <= DIAGNOSTIC_LIMIT);
        let excess = (self.bytes.len() + bytes.len()).saturating_sub(DIAGNOSTIC_LIMIT);
        self.truncated |= excess > 0;
        self.bytes.drain(..excess);
        self.bytes.extend(bytes);
    }

    fn diagnostic(&mut self) -> String {
        let marker = if self.truncated {
            "[output tail truncated]\n"
        } else {
            ""
        };
        format!(
            "{marker}{}",
            String::from_utf8_lossy(self.bytes.make_contiguous())
        )
    }
}

pub struct Hub {
    child: Child,
    stdout: Option<JoinHandle<OutputTail>>,
    stderr: Option<JoinHandle<OutputTail>>,
    pub url: String,
}

impl Hub {
    pub fn start(data: &Path, config: &Path, owner_token: Option<&str>) -> Self {
        let mut command = test_command(env!("CARGO_BIN_EXE_codex-sessions-hub"));
        command.arg("127.0.0.1:0").arg(data).arg(config);
        if let Some(token) = owner_token {
            command.env("CODEX_SESSIONS_HUB_OWNER_TOKEN", token);
        }
        #[cfg(windows)]
        command.creation_flags(windows_sys::Win32::System::Threading::CREATE_NO_WINDOW);
        let child = command
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("could not spawn test hub");
        Self::from_child(child)
    }

    pub fn from_child(child: Child) -> Self {
        let mut hub = Self {
            child,
            stdout: None,
            stderr: None,
            url: String::new(),
        };
        let mut stderr = hub.child.stderr.take().unwrap();
        hub.stderr = Some(thread::spawn(move || {
            let mut tail = OutputTail::default();
            let mut chunk = [0; 8192];
            loop {
                match stderr.read(&mut chunk) {
                    Ok(0) => break,
                    Ok(count) => tail.append(&chunk[..count]),
                    Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                    Err(_) => break,
                }
            }
            tail
        }));
        let mut stdout = BufReader::new(hub.child.stdout.take().unwrap());
        let (report, ready) = mpsc::channel();
        hub.stdout = Some(thread::spawn(move || {
            let mut tail = OutputTail::default();
            let mut line = Vec::new();
            let mut continuation = false;
            loop {
                line.clear();
                // Limit any single read, including an oversized or unfinished line.
                match stdout
                    .by_ref()
                    .take(DIAGNOSTIC_LIMIT as u64)
                    .read_until(b'\n', &mut line)
                {
                    Ok(0) => break,
                    Ok(_) => {}
                    Err(error) => {
                        let _ = report.send(Err(error));
                        break;
                    }
                }
                let complete = line.ends_with(b"\n");
                if complete && !continuation && line.starts_with(READY_PREFIX.as_bytes()) {
                    let _ = report.send(Ok(line));
                    break;
                }
                tail.append(&line);
                continuation = !complete;
            }
            drop(report);
            let _ = io::copy(&mut stdout, &mut io::sink());
            tail
        }));

        let deadline = Instant::now() + STARTUP_TIMEOUT;
        let line = match ready.recv_timeout(STARTUP_TIMEOUT) {
            Ok(Ok(line)) => line,
            Ok(Err(error)) => hub.startup_failed(&format!("could not read hub stdout: {error}")),
            Err(mpsc::RecvTimeoutError::Timeout) => {
                hub.startup_failed("hub did not report a listening address within 10 seconds");
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                hub.startup_failed("hub stdout closed before it reported a listening address");
            }
        };
        let line = String::from_utf8_lossy(&line);
        let address = line
            .trim_end()
            .strip_prefix(READY_PREFIX)
            .and_then(|address| address.parse::<SocketAddrV4>().ok())
            .filter(|address| *address.ip() == Ipv4Addr::LOCALHOST && address.port() != 0);
        let Some(address) = address else {
            hub.startup_failed(&format!(
                "invalid hub listening report: {:?}",
                line.trim_end()
            ));
        };
        hub.url = format!("http://{address}");
        own_endpoint(&hub.url);
        if let Err(error) = ureq::get(format!("{}/v1/health", hub.url))
            .config()
            .timeout_global(Some(deadline.saturating_duration_since(Instant::now())))
            .build()
            .call()
        {
            hub.startup_failed(&format!("hub health check failed: {error}"));
        }
        hub
    }

    pub fn stop(&mut self) {
        self.reap();
    }

    fn startup_failed(&mut self, reason: &str) -> ! {
        let (mut stdout, mut stderr) = self.reap();
        panic!(
            "{reason}\nhub stdout:\n{}\nhub stderr:\n{}",
            stdout.diagnostic(),
            stderr.diagnostic()
        );
    }

    fn reap(&mut self) -> (OutputTail, OutputTail) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let output = |reader: Option<JoinHandle<OutputTail>>| {
            reader
                .and_then(|reader| reader.join().ok())
                .unwrap_or_default()
        };
        (output(self.stdout.take()), output(self.stderr.take()))
    }
}

impl Drop for Hub {
    fn drop(&mut self) {
        self.reap();
    }
}
