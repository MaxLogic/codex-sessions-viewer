//! Database identity and crash-safe, process-owned exclusion.
use std::fs::{File, OpenOptions, TryLockError};
use std::io;
use std::path::{Path, PathBuf};

pub fn database_key(database: &Path) -> io::Result<String> {
    let absolute = std::path::absolute(database)?;
    let text = absolute.to_str().ok_or_else(|| {
        io::Error::new(io::ErrorKind::InvalidInput, "database path must be UTF-8")
    })?;
    #[cfg(windows)]
    let text = text.replace('/', "\\").to_lowercase();
    Ok(crate::dart::sha256_hex(text.as_bytes())[..16].to_owned())
}

pub fn lock_path(database: &Path) -> PathBuf {
    let mut name = database.as_os_str().to_owned();
    name.push(".collector.lock");
    PathBuf::from(name)
}

/// Never unlink a lock file: a replacement inode could admit a second owner.
pub struct InstanceLock {
    _file: File,
}
impl InstanceLock {
    pub fn try_acquire(database: &Path) -> io::Result<Option<Self>> {
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(lock_path(database))?;
        match file.try_lock() {
            Ok(()) => Ok(Some(Self { _file: file })),
            Err(TryLockError::WouldBlock) => Ok(None),
            Err(TryLockError::Error(error)) => Err(error),
        }
    }
}
