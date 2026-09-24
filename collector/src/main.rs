fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    std::process::exit(codex_sessions_collector::cli::run(&args));
}
