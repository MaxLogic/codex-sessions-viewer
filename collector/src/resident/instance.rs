//! Database identity and crash-safe, process-owned exclusion.
use std::fs::{File, OpenOptions, TryLockError};
use std::io;
use std::path::{Path, PathBuf};

/// One spelling for all names derived from a database (or queue directory).
/// Resolve existing files through junctions/symlinks; permission and I/O errors
/// must not silently create a second identity.
pub fn identity_path(path: &Path) -> io::Result<PathBuf> {
    let mut ancestor = std::path::absolute(path)?;
    let mut suffix = Vec::new();
    let mut resolved = loop {
        match std::fs::canonicalize(&ancestor) {
            Ok(path) => break path,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                let component = ancestor.components().next_back().ok_or(error)?;
                suffix.push(component.as_os_str().to_owned());
                if !ancestor.pop() {
                    return Err(io::Error::new(
                        io::ErrorKind::NotFound,
                        "path has no existing ancestor",
                    ));
                }
            }
            Err(error) => return Err(error),
        }
    };
    // Resolve the existing prefix before appending missing names: aliases of a
    // not-yet-created database must keep their identity when it is created.
    for component in suffix.into_iter().rev() {
        if component == ".." {
            resolved.pop();
        } else if component != "." {
            resolved.push(component);
        }
    }
    #[cfg(windows)]
    {
        let text = resolved
            .to_str()
            .ok_or_else(|| {
                io::Error::new(io::ErrorKind::InvalidInput, "identity path must be UTF-8")
            })?
            .replace('/', "\\")
            .to_lowercase();
        let text = if let Some(unc) = text.strip_prefix(r"\\?\unc\") {
            format!(r"\\{unc}")
        } else {
            text.strip_prefix(r"\\?\").unwrap_or(&text).to_owned()
        };
        Ok(PathBuf::from(text))
    }
    #[cfg(not(windows))]
    {
        Ok(resolved)
    }
}

pub fn database_key(database: &Path) -> io::Result<String> {
    let resolved = identity_path(database)?;
    let text = resolved.to_str().ok_or_else(|| {
        io::Error::new(io::ErrorKind::InvalidInput, "database path must be UTF-8")
    })?;
    Ok(crate::dart::sha256_hex(text.as_bytes())[..16].to_owned())
}

pub fn lock_path(database: &Path) -> io::Result<PathBuf> {
    let mut name = identity_path(database)?.into_os_string();
    name.push(".collector.lock");
    Ok(PathBuf::from(name))
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
            .open(lock_path(database)?)?;
        match file.try_lock() {
            Ok(()) => Ok(Some(Self { _file: file })),
            Err(TryLockError::WouldBlock) => Ok(None),
            Err(TryLockError::Error(error)) => Err(error),
        }
    }
}
