//! Windowless resident entry point. The scheduled process owns all collection in-process.
#![cfg_attr(windows, windows_subsystem = "windows")]
fn main() {
    let mut args = vec!["serve".to_owned()];
    for arg in std::env::args_os().skip(1) {
        let Ok(arg) = arg.into_string() else {
            std::process::exit(2);
        };
        args.push(arg);
    }
    std::process::exit(codex_sessions_collector::cli::run(&args));
}
