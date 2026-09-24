use std::path::PathBuf;

fn main() {
    let mut args = std::env::args().skip(1);
    let (Some(listen), Some(data_root), Some(config)) = (args.next(), args.next(), args.next())
    else {
        eprintln!("usage: codex-sessions-hub LISTEN_IP:PORT DATA_DIR CONFIG.json");
        std::process::exit(2);
    };
    if args.next().is_some() {
        eprintln!("unexpected hub argument");
        std::process::exit(2);
    }
    if let Err(error) = codex_sessions_collector::hub_server::serve(
        &listen,
        &PathBuf::from(data_root),
        &PathBuf::from(config),
    ) {
        eprintln!("hub: {error}");
        std::process::exit(1);
    }
}
