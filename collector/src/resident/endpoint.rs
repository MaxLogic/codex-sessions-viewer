//! OS transport selection. No platform decisions escape this module.
use std::io;
use std::time::Duration;

pub use platform::{Listener, Stream};
#[cfg(unix)]
use unix as platform;
#[cfg(not(any(windows, unix)))]
use unsupported as platform;
#[cfg(windows)]
use windows as platform;

pub fn endpoint_name(key: &str) -> io::Result<String> {
    if key.len() != 16 || !key.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "invalid database key",
        ));
    }
    platform::endpoint_name(key)
}
pub fn connect(key: &str, timeout: Duration) -> io::Result<Stream> {
    let name = endpoint_name(key)?;
    platform::connect(&name, timeout)
}

#[cfg(windows)]
mod windows {
    use super::*;
    use std::io::{Read, Write};
    use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
    use std::ptr::{null, null_mut};
    use std::time::Instant;
    use windows_sys::Win32::{
        Foundation::*,
        Security::{Authorization::*, *},
        Storage::FileSystem::*,
        System::{IO::*, Pipes::*, Threading::*},
    };

    fn wide(text: &str) -> Vec<u16> {
        text.encode_utf16().chain(Some(0)).collect()
    }
    fn owned(handle: HANDLE) -> io::Result<OwnedHandle> {
        if handle.is_null() || handle == INVALID_HANDLE_VALUE {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: callers transfer a newly created, non-null owning Windows handle.
        Ok(unsafe { OwnedHandle::from_raw_handle(handle) })
    }
    struct LocalAllocation(*mut core::ffi::c_void);
    impl Drop for LocalAllocation {
        fn drop(&mut self) {
            // SAFETY: only allocations returned by the LocalAlloc-based security APIs enter this guard.
            unsafe {
                LocalFree(self.0);
            }
        }
    }
    fn current_sid() -> io::Result<String> {
        // SAFETY: outputs point to initialized locals; the token is owned and closed exactly once.
        unsafe {
            let mut raw = null_mut();
            if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut raw) == 0 {
                return Err(io::Error::last_os_error());
            }
            let token = owned(raw)?;
            let mut size = 0;
            GetTokenInformation(token.as_raw_handle(), TokenUser, null_mut(), 0, &mut size);
            if size == 0 {
                return Err(io::Error::last_os_error());
            }
            // usize storage provides TOKEN_USER alignment; the API supplies the required byte count.
            let mut buffer = vec![0usize; (size as usize).div_ceil(size_of::<usize>())];
            if GetTokenInformation(
                token.as_raw_handle(),
                TokenUser,
                buffer.as_mut_ptr().cast(),
                size,
                &mut size,
            ) == 0
            {
                return Err(io::Error::last_os_error());
            }
            let user = &*buffer.as_ptr().cast::<TOKEN_USER>();
            let mut sid = null_mut();
            if ConvertSidToStringSidW(user.User.Sid, &mut sid) == 0 {
                return Err(io::Error::last_os_error());
            }
            let _allocation = LocalAllocation(sid.cast());
            let mut len = 0;
            while *sid.add(len) != 0 {
                len += 1;
            }
            Ok(String::from_utf16_lossy(std::slice::from_raw_parts(
                sid, len,
            )))
        }
    }
    fn security() -> io::Result<LocalAllocation> {
        let text = wide(&format!("D:P(A;;GA;;;{})(A;;GA;;;SY)", current_sid()?));
        let mut descriptor = null_mut();
        // SAFETY: text is NUL-terminated and descriptor is an out parameter, later LocalFree'd.
        if unsafe {
            ConvertStringSecurityDescriptorToSecurityDescriptorW(
                text.as_ptr(),
                SDDL_REVISION_1,
                &mut descriptor,
                null_mut(),
            )
        } == 0
        {
            return Err(io::Error::last_os_error());
        }
        Ok(LocalAllocation(descriptor))
    }
    pub fn endpoint_name(key: &str) -> io::Result<String> {
        Ok(format!(r"\\.\pipe\CodexSessionViewer.collector.{key}"))
    }

    pub struct Listener {
        name: Vec<u16>,
        pending: Option<OwnedHandle>,
    }
    impl Listener {
        pub fn bind(key: &str) -> io::Result<Self> {
            let mut listener = Self {
                name: wide(&super::endpoint_name(key)?),
                pending: None,
            };
            listener.pending = Some(listener.create(true)?);
            Ok(listener)
        }
        fn create(&self, first: bool) -> io::Result<OwnedHandle> {
            let descriptor = security()?;
            let attributes = SECURITY_ATTRIBUTES {
                nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
                lpSecurityDescriptor: descriptor.0,
                bInheritHandle: 0,
            };
            // SAFETY: name and descriptor live across the call. CreateNamedPipe copies the descriptor.
            owned(unsafe {
                CreateNamedPipeW(
                    self.name.as_ptr(),
                    PIPE_ACCESS_DUPLEX
                        | FILE_FLAG_OVERLAPPED
                        | if first {
                            FILE_FLAG_FIRST_PIPE_INSTANCE
                        } else {
                            0
                        },
                    PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
                    8,
                    65536,
                    65536,
                    1000,
                    &attributes,
                )
            })
        }
        pub fn accept(&mut self) -> io::Result<Stream> {
            let pipe = self
                .pending
                .as_ref()
                .ok_or_else(|| io::Error::other("listener closed"))?;
            if let Err(error) = Self::connect_pending(pipe) {
                let disconnected = matches!(
                    error.raw_os_error().map(|code| code as u32),
                    Some(ERROR_NO_DATA | ERROR_BROKEN_PIPE | ERROR_PIPE_NOT_CONNECTED)
                );
                let cancelled = error.raw_os_error() == Some(ERROR_OPERATION_ABORTED as i32);
                if disconnected || cancelled || error.kind() == io::ErrorKind::TimedOut {
                    // Reset this same instance: closing the last server handle
                    // would let another process claim first-instance ownership.
                    // SAFETY: connect_pending has completed/drained all I/O.
                    if unsafe { DisconnectNamedPipe(pipe.as_raw_handle()) } == 0 {
                        let reset_error = io::Error::last_os_error();
                        if !matches!(
                            reset_error.raw_os_error().map(|code| code as u32),
                            Some(ERROR_PIPE_NOT_CONNECTED | ERROR_NO_DATA | ERROR_BROKEN_PIPE)
                        ) {
                            return Err(reset_error);
                        }
                    }
                    return Err(if disconnected {
                        io::Error::new(io::ErrorKind::ConnectionAborted, error)
                    } else if cancelled {
                        io::Error::new(io::ErrorKind::Interrupted, error)
                    } else {
                        error
                    });
                }
                return Err(error);
            }
            // Create the replacement before transferring the accepted handle.
            let next = self.create(false)?;
            let pipe = self.pending.replace(next).unwrap();
            Ok(Stream {
                pipe,
                timeout: Duration::from_millis(200),
            })
        }

        fn connect_pending(pipe: &OwnedHandle) -> io::Result<()> {
            // SAFETY: overlapped and its event live until completion. No buffer is borrowed by accept.
            unsafe {
                let event = owned(CreateEventW(null(), 1, 0, null()))?;
                let mut operation: OVERLAPPED = std::mem::zeroed();
                operation.hEvent = event.as_raw_handle();
                if ConnectNamedPipe(pipe.as_raw_handle(), &mut operation) == 0 {
                    let error = GetLastError();
                    if error == ERROR_IO_PENDING {
                        let mut bytes = 0;
                        if GetOverlappedResultEx(
                            pipe.as_raw_handle(),
                            &operation,
                            &mut bytes,
                            200,
                            0,
                        ) == 0
                        {
                            let wait_error = GetLastError();
                            CancelIoEx(pipe.as_raw_handle(), &operation);
                            // Cancellation may lose to a successful connect. Adopt that
                            // connection rather than trying ConnectNamedPipe again on it.
                            if GetOverlappedResult(pipe.as_raw_handle(), &operation, &mut bytes, 1)
                                == 0
                            {
                                let completion_error = GetLastError();
                                return if wait_error == WAIT_TIMEOUT
                                    && completion_error == ERROR_OPERATION_ABORTED
                                {
                                    Err(io::Error::new(io::ErrorKind::TimedOut, "accept poll"))
                                } else {
                                    Err(io::Error::from_raw_os_error(completion_error as i32))
                                };
                            }
                        }
                    } else if error != ERROR_PIPE_CONNECTED {
                        return Err(io::Error::from_raw_os_error(error as i32));
                    }
                }
            }
            Ok(())
        }
    }
    pub struct Stream {
        pipe: OwnedHandle,
        timeout: Duration,
    }
    impl Stream {
        fn transfer(&self, buffer: *mut u8, length: usize, writing: bool) -> io::Result<usize> {
            // SAFETY: Read/Write supply a valid live buffer for the duration of this function.
            // Every pending I/O completes (or is cancelled and drained) before returning, so
            // neither OVERLAPPED, event, nor buffer can be dropped while the kernel uses it.
            unsafe {
                let event = owned(CreateEventW(null(), 1, 0, null()))?;
                let mut operation: OVERLAPPED = std::mem::zeroed();
                operation.hEvent = event.as_raw_handle();
                let length = length.min(u32::MAX as usize) as u32;
                let ok = if writing {
                    WriteFile(
                        self.pipe.as_raw_handle(),
                        buffer.cast(),
                        length,
                        null_mut(),
                        &mut operation,
                    )
                } else {
                    ReadFile(
                        self.pipe.as_raw_handle(),
                        buffer,
                        length,
                        null_mut(),
                        &mut operation,
                    )
                };
                if ok == 0 {
                    let error = GetLastError();
                    if !writing && error == ERROR_BROKEN_PIPE {
                        return Ok(0);
                    }
                    if error != ERROR_IO_PENDING {
                        return Err(io::Error::from_raw_os_error(error as i32));
                    }
                }
                let mut bytes = 0;
                if GetOverlappedResultEx(
                    self.pipe.as_raw_handle(),
                    &operation,
                    &mut bytes,
                    self.timeout.as_millis().min(u128::from(u32::MAX - 1)) as u32,
                    0,
                ) == 0
                {
                    let error = GetLastError();
                    CancelIoEx(self.pipe.as_raw_handle(), &operation);
                    // A completion racing the deadline still consumed these bytes.
                    // Preserve Read/Write's byte count instead of reporting a false timeout.
                    if GetOverlappedResult(self.pipe.as_raw_handle(), &operation, &mut bytes, 1)
                        != 0
                    {
                        return Ok(bytes as usize);
                    }
                    if error == WAIT_TIMEOUT {
                        return Err(io::Error::new(io::ErrorKind::TimedOut, "pipe I/O timeout"));
                    }
                    if !writing && error == ERROR_BROKEN_PIPE {
                        return Ok(0);
                    }
                    return Err(io::Error::from_raw_os_error(error as i32));
                }
                Ok(bytes as usize)
            }
        }
    }
    impl Read for Stream {
        fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
            if buffer.is_empty() {
                return Ok(0);
            }
            self.transfer(buffer.as_mut_ptr(), buffer.len(), false)
        }
    }
    impl Write for Stream {
        fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
            if buffer.is_empty() {
                return Ok(0);
            }
            self.transfer(buffer.as_ptr().cast_mut(), buffer.len(), true)
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }
    pub fn connect(name: &str, timeout: Duration) -> io::Result<Stream> {
        let name = wide(name);
        let deadline = Instant::now() + timeout;
        loop {
            // SAFETY: NUL-terminated name, no inherited handle or borrowed security data.
            let raw = unsafe {
                CreateFileW(
                    name.as_ptr(),
                    GENERIC_READ | GENERIC_WRITE,
                    0,
                    null(),
                    OPEN_EXISTING,
                    FILE_FLAG_OVERLAPPED,
                    null_mut(),
                )
            };
            if raw != INVALID_HANDLE_VALUE {
                return Ok(Stream {
                    pipe: owned(raw)?,
                    timeout,
                });
            }
            let error = io::Error::last_os_error();
            if error.raw_os_error() != Some(ERROR_PIPE_BUSY as i32) {
                return Err(error);
            }
            let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "pipe connect timeout",
                ));
            };
            // SAFETY: name is live. The finite budget is never NMPWAIT_WAIT_FOREVER (0xffffffff).
            unsafe {
                WaitNamedPipeW(
                    name.as_ptr(),
                    remaining.as_millis().clamp(1, u128::from(u32::MAX - 1)) as u32,
                );
            }
        }
    }
}

#[cfg(unix)]
mod unix {
    use super::*;
    use std::fs::{DirBuilder, Permissions};
    use std::os::unix::{
        fs::{DirBuilderExt, FileTypeExt, MetadataExt, PermissionsExt},
        net::{UnixListener, UnixStream},
    };
    use std::path::{Path, PathBuf};
    pub type Stream = UnixStream;
    fn runtime() -> io::Result<PathBuf> {
        crate::platform_locations::PlatformLocations::current()
            .map(|l| l.runtime_dir)
            .ok_or_else(|| {
                io::Error::new(io::ErrorKind::Unsupported, "runtime directory unavailable")
            })
    }
    fn secure_directory(path: &Path) -> io::Result<()> {
        // Validate before recursive creation, so a pre-existing link is never traversed.
        for ancestor in path.ancestors() {
            match std::fs::symlink_metadata(ancestor) {
                Ok(meta) if meta.file_type().is_symlink() => {
                    return Err(io::Error::new(
                        io::ErrorKind::PermissionDenied,
                        "symlinked runtime directory",
                    ));
                }
                Ok(_) => (),
                Err(error) if error.kind() == io::ErrorKind::NotFound => (),
                Err(error) => return Err(error),
            }
        }
        let mut builder = DirBuilder::new();
        builder.recursive(true).mode(0o700);
        builder.create(path)?;
        // Inspect every ancestor as well: do not traverse a symlink to reach a private directory.
        for ancestor in path.ancestors() {
            let meta = std::fs::symlink_metadata(ancestor)?;
            if meta.file_type().is_symlink() {
                return Err(io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    "symlinked runtime directory",
                ));
            }
        }
        let metadata = std::fs::symlink_metadata(path)?;
        // SAFETY: geteuid takes no arguments and has no memory preconditions.
        if !metadata.is_dir() || metadata.uid() != unsafe { libc::geteuid() } {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "foreign runtime directory",
            ));
        }
        std::fs::set_permissions(path, Permissions::from_mode(0o700))
    }
    pub fn endpoint_name(key: &str) -> io::Result<String> {
        let path = runtime()?.join(format!("collector-{key}.sock"));
        let text = path.to_str().ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "runtime path must be UTF-8")
        })?;
        if text.len() >= 104 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "runtime socket path exceeds portable limit",
            ));
        }
        Ok(text.to_owned())
    }
    pub struct Listener {
        listener: UnixListener,
        path: PathBuf,
    }
    impl Listener {
        /// Caller must hold the database instance lock before stale socket removal.
        pub fn bind(key: &str) -> io::Result<Self> {
            let path = PathBuf::from(super::endpoint_name(key)?);
            secure_directory(path.parent().unwrap())?;
            match std::fs::symlink_metadata(&path) {
                Ok(metadata) => {
                    // SAFETY: geteuid has no preconditions. Only remove a socket we own.
                    if !metadata.file_type().is_socket()
                        || metadata.uid() != unsafe { libc::geteuid() }
                    {
                        return Err(io::Error::new(
                            io::ErrorKind::PermissionDenied,
                            "refusing non-owned stale socket",
                        ));
                    }
                    // Do not steal a live endpoint, even when called without the instance lock.
                    match connect(path.to_str().unwrap(), Duration::from_millis(200)) {
                        Ok(_) => {
                            return Err(io::Error::new(
                                io::ErrorKind::AddrInUse,
                                "endpoint already active",
                            ));
                        }
                        Err(error) if error.kind() == io::ErrorKind::ConnectionRefused => (),
                        Err(error) => return Err(error),
                    }
                    std::fs::remove_file(&path)?;
                }
                Err(error) if error.kind() == io::ErrorKind::NotFound => (),
                Err(error) => return Err(error),
            }
            let listener = UnixListener::bind(&path)?;
            listener.set_nonblocking(true)?;
            std::fs::set_permissions(&path, Permissions::from_mode(0o600))?;
            Ok(Self { listener, path })
        }
        pub fn accept(&mut self) -> io::Result<Stream> {
            let (stream, _) = self.listener.accept()?;
            stream.set_nonblocking(false)?;
            stream.set_read_timeout(Some(Duration::from_millis(200)))?;
            stream.set_write_timeout(Some(Duration::from_millis(200)))?;
            Ok(stream)
        }
    }
    impl Drop for Listener {
        fn drop(&mut self) {
            if let Err(error) = std::fs::remove_file(&self.path) {
                eprintln!("resident socket cleanup: {error}");
            }
        }
    }
    pub fn connect(name: &str, timeout: Duration) -> io::Result<Stream> {
        use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
        use std::time::Instant;
        let deadline = Instant::now() + timeout;
        loop {
            // SAFETY: syscall arguments are constants; successful descriptors enter RAII immediately.
            let raw = unsafe { libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0) };
            if raw < 0 {
                return Err(io::Error::last_os_error());
            }
            // SAFETY: raw is freshly owned and valid.
            let fd = unsafe { OwnedFd::from_raw_fd(raw) };
            // SAFETY: fd is live; flags use the platform's libc constants.
            unsafe {
                if libc::fcntl(fd.as_raw_fd(), libc::F_SETFD, libc::FD_CLOEXEC) < 0
                    || libc::fcntl(fd.as_raw_fd(), libc::F_SETFL, libc::O_NONBLOCK) < 0
                {
                    return Err(io::Error::last_os_error());
                }
            }
            // SAFETY: sockaddr_un is zero-initialized and filled within its path capacity.
            let mut address: libc::sockaddr_un = unsafe { std::mem::zeroed() };
            if name.len() >= address.sun_path.len() || name.as_bytes().contains(&0) {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "invalid socket path",
                ));
            }
            address.sun_family = libc::AF_UNIX as _;
            for (to, from) in address.sun_path.iter_mut().zip(name.bytes()) {
                *to = from as _;
            }
            let length = std::mem::offset_of!(libc::sockaddr_un, sun_path) + name.len() + 1;
            #[cfg(any(
                target_os = "macos",
                target_os = "ios",
                target_os = "freebsd",
                target_os = "openbsd",
                target_os = "netbsd",
                target_os = "dragonfly"
            ))]
            {
                address.sun_len = length as _;
            }
            // SAFETY: address is initialized, NUL-terminated, and length stays within sockaddr_un.
            let connected = unsafe {
                libc::connect(
                    fd.as_raw_fd(),
                    (&address as *const libc::sockaddr_un).cast(),
                    length as libc::socklen_t,
                )
            };
            if connected < 0 {
                let error = io::Error::last_os_error();
                if error.raw_os_error() == Some(libc::EINPROGRESS) {
                    loop {
                        let remaining = deadline.saturating_duration_since(Instant::now());
                        if remaining.is_zero() {
                            return Err(io::Error::new(
                                io::ErrorKind::TimedOut,
                                "socket connect timeout",
                            ));
                        }
                        let mut poll = libc::pollfd {
                            fd: fd.as_raw_fd(),
                            events: libc::POLLOUT,
                            revents: 0,
                        };
                        // SAFETY: one initialized pollfd; timeout is finite and within c_int.
                        let ready = unsafe {
                            libc::poll(
                                &mut poll,
                                1,
                                remaining.as_millis().clamp(1, i32::MAX as u128) as i32,
                            )
                        };
                        if ready == 0 {
                            return Err(io::Error::new(
                                io::ErrorKind::TimedOut,
                                "socket connect timeout",
                            ));
                        }
                        if ready < 0 {
                            let error = io::Error::last_os_error();
                            if error.kind() == io::ErrorKind::Interrupted {
                                continue;
                            }
                            return Err(error);
                        }
                        let mut error: libc::c_int = 0;
                        let mut length = size_of::<libc::c_int>() as libc::socklen_t;
                        // SAFETY: fd is live and outputs have the required sizes and alignment.
                        if unsafe {
                            libc::getsockopt(
                                fd.as_raw_fd(),
                                libc::SOL_SOCKET,
                                libc::SO_ERROR,
                                (&mut error as *mut libc::c_int).cast(),
                                &mut length,
                            )
                        } < 0
                        {
                            return Err(io::Error::last_os_error());
                        }
                        if error != 0 {
                            return Err(io::Error::from_raw_os_error(error));
                        }
                        break;
                    }
                } else if !matches!(error.raw_os_error(), Some(libc::EAGAIN | libc::EINTR)) {
                    return Err(error);
                } else {
                    // Retry backlog pressure within one deadline.
                    if Instant::now() >= deadline {
                        return Err(io::Error::new(
                            io::ErrorKind::TimedOut,
                            "socket connect timeout",
                        ));
                    }
                    drop(fd);
                    std::thread::sleep(
                        Duration::from_millis(5)
                            .min(deadline.saturating_duration_since(Instant::now())),
                    );
                    continue;
                }
            }
            // SAFETY: fd is connected; restore blocking I/O for std's socket timeouts.
            if unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_SETFL, 0) } < 0 {
                return Err(io::Error::last_os_error());
            }
            let stream = UnixStream::from(fd);
            stream.set_read_timeout(Some(timeout))?;
            stream.set_write_timeout(Some(timeout))?;
            return Ok(stream);
        }
    }
}

#[cfg(not(any(windows, unix)))]
mod unsupported {
    use super::*;
    use std::io::{Read, Write};
    fn error() -> io::Error {
        io::Error::new(
            io::ErrorKind::Unsupported,
            "local IPC unsupported on this platform",
        )
    }
    pub fn endpoint_name(_: &str) -> io::Result<String> {
        Err(error())
    }
    pub struct Listener;
    impl Listener {
        pub fn bind(_: &str) -> io::Result<Self> {
            Err(error())
        }
        pub fn accept(&mut self) -> io::Result<Stream> {
            Err(error())
        }
    }
    pub struct Stream;
    impl Read for Stream {
        fn read(&mut self, _: &mut [u8]) -> io::Result<usize> {
            Err(error())
        }
    }
    impl Write for Stream {
        fn write(&mut self, _: &[u8]) -> io::Result<usize> {
            Err(error())
        }
        fn flush(&mut self) -> io::Result<()> {
            Err(error())
        }
    }
    pub fn connect(_: &str, _: Duration) -> io::Result<Stream> {
        Err(error())
    }
}
