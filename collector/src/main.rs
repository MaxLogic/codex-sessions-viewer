fn main() {
    if let Err(error) = codex_sessions_collector::store::connection::ensure() {
        eprintln!("SQLite initialization failed: {error}");
        std::process::exit(1);
    }
    let args: Vec<String> = std::env::args().skip(1).collect();
    std::process::exit(codex_sessions_collector::cli::run(&args));
}
