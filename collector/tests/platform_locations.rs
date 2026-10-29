mod support;
use codex_sessions_collector::platform_locations::{HostPlatform, PlatformLocations};
use std::path::Path;

fn normalized(path: &Path) -> String {
    path.to_string_lossy().replace('\\', "/")
}

#[test]
fn windows_defaults_and_adjacent_settings() {
    let temp = support::temp_dir().join(format!("cxv-locations-{}", std::process::id()));
    std::fs::create_dir_all(&temp).unwrap();
    let exe = temp.join("viewer.exe");
    std::fs::write(temp.join("settings.toml"), "").unwrap();
    let locations = PlatformLocations::resolve(
        HostPlatform::Windows,
        |name| match name {
            "APPDATA" => Some(temp.join("Roaming").to_string_lossy().into_owned()),
            "LOCALAPPDATA" => Some(temp.join("Local").to_string_lossy().into_owned()),
            _ => None,
        },
        &exe,
    )
    .unwrap();
    assert_eq!(
        locations.database_file,
        temp.join("Roaming/CodexSessionViewer/codex_sessions_viewer.sqlite")
    );
    assert_eq!(locations.settings_file, temp.join("settings.toml"));
    assert_eq!(locations.assets_dir, temp.join("assets"));
    assert_eq!(
        locations.backup_dir,
        temp.join("Roaming/CodexSessionViewer/backups")
    );
    assert_eq!(locations.log_dir, Path::new("logs"));
    assert_eq!(
        locations.queue_dir,
        temp.join("Local/CodexSessionViewer/collector/queue")
    );
    assert_eq!(
        locations.runtime_dir,
        temp.join("Local/CodexSessionViewer/run")
    );
    std::fs::remove_file(temp.join("settings.toml")).unwrap();
    let fresh = PlatformLocations::resolve(
        HostPlatform::Windows,
        |name| match name {
            "APPDATA" => Some(temp.join("Roaming").to_string_lossy().into_owned()),
            "LOCALAPPDATA" => Some(temp.join("Local").to_string_lossy().into_owned()),
            _ => None,
        },
        &exe,
    )
    .unwrap();
    assert_eq!(
        fresh.settings_file,
        temp.join("Roaming/CodexSessionViewer/settings.toml")
    );
    std::fs::remove_dir_all(temp).unwrap();
}

#[test]
fn macos_and_linux_defaults() {
    let mac = PlatformLocations::resolve(
        HostPlatform::Macos,
        |name| (name == "HOME").then(|| "/Users/tester".into()),
        Path::new("/Applications/Viewer.app/Contents/MacOS/viewer"),
    )
    .unwrap();
    assert_eq!(
        normalized(&mac.database_file),
        "/Users/tester/Library/Application Support/CodexSessionViewer/codex_sessions_viewer.sqlite"
    );
    assert_eq!(
        normalized(&mac.queue_dir),
        "/Users/tester/Library/Caches/CodexSessionViewer/collector/queue"
    );
    assert_eq!(
        normalized(&mac.runtime_dir),
        "/Users/tester/Library/Caches/CodexSessionViewer/run"
    );
    assert_eq!(
        normalized(&mac.sql_dir),
        "/Applications/Viewer.app/Contents/Resources/sql"
    );
    let mac_runtime = PlatformLocations::resolve(
        HostPlatform::Macos,
        |name| match name {
            "HOME" => Some("/Users/tester".into()),
            "XDG_RUNTIME_DIR" => Some("/tmp/runtime".into()),
            _ => None,
        },
        Path::new("/Applications/Viewer.app/Contents/MacOS/viewer"),
    )
    .unwrap();
    assert_eq!(
        normalized(&mac_runtime.runtime_dir),
        "/tmp/runtime/CodexSessionViewer"
    );

    let linux = PlatformLocations::resolve(
        HostPlatform::Linux,
        |name| match name {
            "HOME" => Some("/home/tester".into()),
            "XDG_DATA_HOME" => Some("/custom/data".into()),
            "XDG_CONFIG_HOME" => Some("/custom/config".into()),
            "XDG_STATE_HOME" => Some("/custom/state".into()),
            "XDG_CACHE_HOME" => Some("/custom/cache".into()),
            "XDG_RUNTIME_DIR" => Some("/run/user/1000".into()),
            _ => None,
        },
        Path::new("/opt/viewer/bin/viewer"),
    )
    .unwrap();
    assert_eq!(
        normalized(&linux.database_file),
        "/custom/data/CodexSessionViewer/codex_sessions_viewer.sqlite"
    );
    assert_eq!(
        normalized(&linux.settings_file),
        "/custom/config/CodexSessionViewer/settings.toml"
    );
    assert_eq!(
        normalized(&linux.log_dir),
        "/custom/state/CodexSessionViewer/logs"
    );
    assert_eq!(
        normalized(&linux.queue_dir),
        "/custom/cache/CodexSessionViewer/collector/queue"
    );
    assert_eq!(
        normalized(&linux.runtime_dir),
        "/run/user/1000/CodexSessionViewer"
    );
    assert_eq!(normalized(&linux.sql_dir), "/opt/viewer/bin/data/sql");
    assert_eq!(normalized(&linux.assets_dir), "/opt/viewer/bin/data/assets");
    assert_eq!(
        normalized(&linux.backup_dir),
        "/custom/data/CodexSessionViewer/backups"
    );
    assert!(
        PlatformLocations::resolve(
            HostPlatform::Linux,
            |_| None,
            Path::new("/opt/viewer/bin/viewer")
        )
        .is_none()
    );
}

#[test]
fn linux_explicit_xdg_roots_do_not_need_home() {
    let all_xdg = |name: &str| match name {
        "XDG_DATA_HOME" => Some("/custom/data".into()),
        "XDG_CONFIG_HOME" => Some("/custom/config".into()),
        "XDG_STATE_HOME" => Some("/custom/state".into()),
        "XDG_CACHE_HOME" => Some("/custom/cache".into()),
        _ => None,
    };
    let exe = Path::new("/opt/viewer/bin/viewer");
    let locations = PlatformLocations::resolve(HostPlatform::Linux, all_xdg, exe)
        .expect("all XDG roots determine locations without HOME");
    assert_eq!(
        normalized(&locations.runtime_dir),
        "/custom/cache/CodexSessionViewer/run"
    );
    assert_eq!(
        normalized(&locations.database_file),
        "/custom/data/CodexSessionViewer/codex_sessions_viewer.sqlite"
    );
    assert_eq!(
        normalized(&locations.settings_file),
        "/custom/config/CodexSessionViewer/settings.toml"
    );
    assert_eq!(
        normalized(&locations.log_dir),
        "/custom/state/CodexSessionViewer/logs"
    );
    assert_eq!(
        normalized(&locations.queue_dir),
        "/custom/cache/CodexSessionViewer/collector/queue"
    );

    assert!(
        PlatformLocations::resolve(
            HostPlatform::Linux,
            |name| (name == "XDG_DATA_HOME").then(|| "/custom/data".into()),
            exe
        )
        .is_none()
    );
}
