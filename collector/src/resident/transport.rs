//! Bounded, independently drained IPC reads. No database or collection policy.
use super::{endpoint, protocol};
use serde_json::Value;
use std::{
    collections::VecDeque,
    io::{self, BufRead, BufReader, Write},
    sync::{
        Arc, Condvar, Mutex,
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

const POLL: Duration = Duration::from_millis(20);

/// One queued frame plus one writing frame, each <=16 MiB. Only the connection
/// owner waits for space; the writer never owns a state, request or queue lock
/// during I/O. Cancellation is checked while waiting, independently of output.
pub(super) struct Output {
    sender: Option<mpsc::SyncSender<Vec<u8>>>,
    thread: Option<JoinHandle<()>>,
    stopped: Arc<AtomicBool>,
    failed: Arc<AtomicBool>,
    pending: Arc<std::sync::atomic::AtomicUsize>,
    space: Arc<Wake>,
    synchronous_stdio: bool,
    cancelled: Arc<dyn Fn() -> bool + Send + Sync>,
}
impl Output {
    pub fn new(
        writer: impl Write + Send + 'static,
        cancelled: impl Fn() -> bool + Send + Sync + 'static,
    ) -> Self {
        let (sender, receiver) = mpsc::sync_channel::<Vec<u8>>(1);
        let stopped = Arc::new(AtomicBool::new(false));
        let failed = Arc::new(AtomicBool::new(false));
        let pending = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let space = Arc::new(Wake::default());
        let write_space = space.clone();
        let cancelled: Arc<dyn Fn() -> bool + Send + Sync> = Arc::new(cancelled);
        let (stop, failure, count, cancel) = (
            stopped.clone(),
            failed.clone(),
            pending.clone(),
            cancelled.clone(),
        );
        let thread = thread::spawn(move || {
            let mut writer =
                RetryingWriter::new(writer, || stop.load(Ordering::SeqCst) || cancel());
            while !stop.load(Ordering::SeqCst) {
                match receiver.recv_timeout(POLL) {
                    Ok(bytes) => {
                        write_space.notify();
                        let result = writer.write_all(&bytes).and_then(|()| writer.flush());
                        count.fetch_sub(1, Ordering::SeqCst);
                        if result.is_err() {
                            failure.store(true, Ordering::SeqCst);
                            return;
                        }
                    }
                    Err(mpsc::RecvTimeoutError::Timeout) => (),
                    Err(mpsc::RecvTimeoutError::Disconnected) => return,
                }
            }
        });
        Self {
            sender: Some(sender),
            thread: Some(thread),
            stopped,
            failed,
            pending,
            space,
            synchronous_stdio: false,
            cancelled,
        }
    }
    pub fn stdout(cancelled: impl Fn() -> bool + Send + Sync + 'static) -> io::Result<Self> {
        let mut output = Self::new(endpoint::stdout()?, cancelled);
        output.synchronous_stdio = true;
        Ok(output)
    }
}
impl Write for Output {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        if bytes.len() > protocol::MAX_EVENT_BYTES {
            return Err(io::ErrorKind::InvalidData.into());
        }
        let mut frame = bytes.to_vec();
        self.pending.fetch_add(1, Ordering::SeqCst);
        loop {
            match self.sender.as_ref().unwrap().try_send(frame) {
                Ok(()) => return Ok(bytes.len()),
                Err(mpsc::TrySendError::Full(bytes)) => frame = bytes,
                Err(mpsc::TrySendError::Disconnected(_)) => break,
            }
            if (self.cancelled)() || self.failed.load(Ordering::SeqCst) {
                break;
            }
            self.space.wait();
        }
        self.pending.fetch_sub(1, Ordering::SeqCst);
        Err(io::Error::new(
            io::ErrorKind::ConnectionAborted,
            "IPC output stopped",
        ))
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}
impl Drop for Output {
    fn drop(&mut self) {
        // Give small final replies (notably shutdown/version errors) a bounded
        // drain opportunity. A stalled peer cannot prevent stop/cancel/join.
        let deadline = Instant::now() + Duration::from_millis(200);
        while self.pending.load(Ordering::SeqCst) > 0
            && !self.failed.load(Ordering::SeqCst)
            && Instant::now() < deadline
        {
            thread::sleep(POLL);
        }
        self.stopped.store(true, Ordering::SeqCst);
        self.sender.take();
        if let Some(thread) = self.thread.take() {
            if self.synchronous_stdio {
                endpoint::join_io(thread);
            } else {
                let _ = thread.join();
            }
        }
    }
}

#[derive(Default)]
pub(super) struct Wake {
    ready: Mutex<bool>,
    changed: Condvar,
}
impl Wake {
    pub fn notify(&self) {
        *self.ready.lock().unwrap() = true;
        self.changed.notify_one();
    }
    pub fn wait(&self) {
        let ready = self.ready.lock().unwrap();
        let mut ready = self
            .changed
            .wait_timeout_while(ready, POLL, |ready| !*ready)
            .unwrap()
            .0;
        *ready = false;
    }
}

pub(super) enum Event {
    Frame(Vec<u8>),
    Rejected(Value),
    Closed(io::Error),
}

struct Buffered {
    events: VecDeque<(Event, usize)>,
    bytes: usize,
}
struct Queue {
    buffered: Mutex<Buffered>,
    space: Condvar,
    messages: usize,
    bytes: usize,
    wake: Arc<Wake>,
}
impl Queue {
    fn push(&self, event: Event, bytes: usize, stopped: &AtomicBool) {
        self.push_until(event, bytes, stopped, || false);
    }
    fn push_until(
        &self,
        event: Event,
        bytes: usize,
        stopped: &AtomicBool,
        closed: impl Fn() -> bool,
    ) {
        let mut buffered = self.buffered.lock().unwrap();
        while !stopped.load(Ordering::SeqCst) {
            if buffered.events.len() < self.messages && buffered.bytes + bytes <= self.bytes {
                buffered.bytes += bytes;
                buffered.events.push_back((event, bytes));
                self.wake.notify();
                return;
            }
            // Probing must not retain even the connection-local queue lock.
            drop(buffered);
            if closed() {
                return;
            }
            buffered = self.buffered.lock().unwrap();
            buffered = self.space.wait_timeout(buffered, POLL).unwrap().0;
        }
    }
    fn pop(&self) -> Option<Event> {
        let mut buffered = self.buffered.lock().unwrap();
        let (event, bytes) = buffered.events.pop_front()?;
        buffered.bytes -= bytes;
        self.space.notify_one();
        Some(event)
    }
}

pub(super) struct Incoming {
    queue: Arc<Queue>,
    stopped: Arc<AtomicBool>,
    closed: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
    synchronous_stdio: bool,
}
impl Incoming {
    pub fn new(
        reader: BufReader<endpoint::Stream>,
        requests: bool,
        wake: Arc<Wake>,
    ) -> io::Result<Self> {
        let probe = reader.get_ref().try_clone()?;
        Ok(Self::reader(reader, requests, wake, false, move || {
            endpoint::peer_closed(&probe)
        }))
    }
    pub fn stdin(wake: Arc<Wake>) -> Self {
        Self::reader(
            BufReader::new(endpoint::Stdin),
            true,
            wake,
            true,
            endpoint::stdin_closed,
        )
    }
    fn reader(
        mut reader: impl BufRead + Send + 'static,
        requests: bool,
        wake: Arc<Wake>,
        synchronous_stdio: bool,
        probe: impl Fn() -> bool + Send + 'static,
    ) -> Self {
        let queue = Arc::new(Queue {
            buffered: Mutex::new(Buffered {
                events: VecDeque::new(),
                bytes: 0,
            }),
            space: Condvar::new(),
            messages: if requests { 64 } else { 32 },
            bytes: if requests {
                4 * protocol::MAX_REQUEST_BYTES
            } else {
                2 * protocol::MAX_EVENT_BYTES
            },
            wake,
        });
        let stopped = Arc::new(AtomicBool::new(false));
        let closed = Arc::new(AtomicBool::new(false));
        let (events, stop, peer_closed) = (queue.clone(), stopped.clone(), closed.clone());
        let thread = thread::spawn(move || {
            let disconnected = || {
                if probe() {
                    peer_closed.store(true, Ordering::SeqCst);
                    events.wake.notify();
                    true
                } else {
                    false
                }
            };
            let mut frame = protocol::RequestFramer::default();
            let mut line = Vec::new();
            let mut partial_since = None;
            while !stop.load(Ordering::SeqCst) {
                let result = if requests {
                    frame.read(&mut reader)
                } else {
                    protocol::read_frame(&mut reader, &mut line, protocol::MAX_EVENT_BYTES).map(
                        |r| match r {
                            protocol::Frame::Complete => {
                                protocol::RequestFrame::Complete(std::mem::take(&mut line))
                            }
                            protocol::Frame::Partial => protocol::RequestFrame::Partial,
                            protocol::Frame::Eof => protocol::RequestFrame::Eof,
                        },
                    )
                };
                match result {
                    Ok(protocol::RequestFrame::Complete(bytes)) => {
                        partial_since = None;
                        let size = bytes.len();
                        events.push_until(Event::Frame(bytes), size, &stop, disconnected);
                    }
                    Ok(protocol::RequestFrame::Rejected(error)) => {
                        partial_since = None;
                        events.push_until(Event::Rejected(error), 256, &stop, disconnected);
                    }
                    Ok(protocol::RequestFrame::Partial) => {
                        if requests && !frame.pending() {
                            partial_since = None;
                        } else {
                            partial_since.get_or_insert_with(Instant::now);
                        }
                    }
                    Err(e)
                        if matches!(
                            e.kind(),
                            io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock
                        ) => {}
                    other => {
                        peer_closed.store(true, Ordering::SeqCst);
                        events.wake.notify();
                        let error = other.err().unwrap_or_else(|| {
                            io::Error::new(io::ErrorKind::UnexpectedEof, "resident endpoint closed")
                        });
                        events.push(Event::Closed(error), 0, &stop);
                        return;
                    }
                }
                if peer_closed.load(Ordering::SeqCst) {
                    return;
                }
                if requests && partial_since.is_some_and(|t| t.elapsed() > Duration::from_secs(5)) {
                    peer_closed.store(true, Ordering::SeqCst);
                    events.push(
                        Event::Closed(io::Error::new(
                            io::ErrorKind::TimedOut,
                            "incomplete request timed out",
                        )),
                        0,
                        &stop,
                    );
                    return;
                }
            }
        });
        Self {
            queue,
            stopped,
            closed,
            thread: Some(thread),
            synchronous_stdio,
        }
    }
    pub fn try_recv(&self) -> Option<Event> {
        self.queue.pop()
    }
    pub fn closed_flag(&self) -> Arc<AtomicBool> {
        self.closed.clone()
    }
    pub fn outgoing(&self, stream: endpoint::Stream) -> Outgoing {
        let (sender, receiver) = mpsc::sync_channel::<Vec<u8>>(1);
        let (events, stop, peer_closed) = (
            self.queue.clone(),
            self.stopped.clone(),
            self.closed.clone(),
        );
        let write_stop = stop.clone();
        let thread = thread::spawn(move || {
            let mut writer = RetryingWriter::new(stream, || {
                write_stop.load(Ordering::SeqCst) || peer_closed.load(Ordering::SeqCst)
            });
            while !stop.load(Ordering::SeqCst) {
                match receiver.recv_timeout(POLL) {
                    Ok(bytes) => {
                        events.wake.notify();
                        if let Err(error) = writer.write_all(&bytes).and_then(|()| writer.flush()) {
                            peer_closed.store(true, Ordering::SeqCst);
                            events.wake.notify();
                            events.push(Event::Closed(error), 0, &stop);
                            return;
                        }
                    }
                    Err(mpsc::RecvTimeoutError::Timeout) => (),
                    Err(mpsc::RecvTimeoutError::Disconnected) => return,
                }
            }
        });
        Outgoing {
            sender: Some(sender),
            thread: Some(thread),
            stopped: self.stopped.clone(),
        }
    }
}
impl Drop for Incoming {
    fn drop(&mut self) {
        self.stopped.store(true, Ordering::SeqCst);
        self.queue.space.notify_all();
        if let Some(thread) = self.thread.take() {
            if self.synchronous_stdio {
                endpoint::join_io(thread);
            } else {
                let _ = thread.join();
            }
        }
    }
}
pub(super) struct Outgoing {
    sender: Option<mpsc::SyncSender<Vec<u8>>>,
    thread: Option<JoinHandle<()>>,
    stopped: Arc<AtomicBool>,
}
impl Outgoing {
    pub fn try_send(&self, bytes: Vec<u8>) -> Result<(), mpsc::TrySendError<Vec<u8>>> {
        self.sender.as_ref().unwrap().try_send(bytes)
    }
}
impl Drop for Outgoing {
    fn drop(&mut self) {
        self.stopped.store(true, Ordering::SeqCst);
        self.sender.take();
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

/// A full pipe is back-pressure, not a dropped client. Retain partial-write
/// offsets through Write::write_all; never resend the beginning of a frame.
pub(super) struct RetryingWriter<W, F> {
    writer: W,
    stopped: F,
    in_frame: bool,
}
impl<W, F> RetryingWriter<W, F> {
    pub fn new(writer: W, stopped: F) -> Self {
        Self {
            writer,
            stopped,
            in_frame: false,
        }
    }
}
impl<W: Write, F: Fn() -> bool> Write for RetryingWriter<W, F> {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        // Permit the small shutdown acknowledgement's first write, but abort
        // an already partial frame even if a slow peer keeps making progress.
        if self.in_frame && (self.stopped)() {
            return Err(io::Error::new(
                io::ErrorKind::ConnectionAborted,
                "IPC writer stopped",
            ));
        }
        self.in_frame = true;
        loop {
            match self.writer.write(bytes) {
                Err(e)
                    if matches!(
                        e.kind(),
                        io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock
                    ) && !(self.stopped)() =>
                {
                    if e.kind() == io::ErrorKind::WouldBlock {
                        thread::sleep(POLL);
                    }
                }
                other => return other,
            }
        }
    }
    fn flush(&mut self) -> io::Result<()> {
        self.writer.flush()?;
        self.in_frame = false;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn transport_outbound_capacity_wait_is_cancellable() {
        struct Stalled {
            entered: mpsc::Sender<()>,
            cancelled: Arc<AtomicBool>,
        }
        impl Write for Stalled {
            fn write(&mut self, _: &[u8]) -> io::Result<usize> {
                self.entered.send(()).unwrap();
                while !self.cancelled.load(Ordering::SeqCst) {
                    thread::sleep(POLL);
                }
                Err(io::ErrorKind::TimedOut.into())
            }
            fn flush(&mut self) -> io::Result<()> {
                Ok(())
            }
        }
        let cancelled = Arc::new(AtomicBool::new(false));
        let cancel = cancelled.clone();
        let (entered, writing) = mpsc::channel();
        let mut output = Output::new(
            Stalled {
                entered,
                cancelled: cancelled.clone(),
            },
            move || cancel.load(Ordering::SeqCst),
        );
        assert_eq!(
            output
                .write(&vec![0; protocol::MAX_EVENT_BYTES + 1])
                .unwrap_err()
                .kind(),
            io::ErrorKind::InvalidData
        );
        output.write_all(b"first\n").unwrap();
        writing.recv_timeout(Duration::from_secs(1)).unwrap();
        output.write_all(b"queued\n").unwrap();
        let (done, received) = mpsc::channel();
        let producer = thread::spawn(move || {
            done.send(output.write_all(b"backpressured\n").unwrap_err().kind())
                .unwrap();
        });
        let early = received.recv_timeout(Duration::from_millis(60));
        cancelled.store(true, Ordering::SeqCst);
        let result = received.recv_timeout(Duration::from_secs(1));
        producer.join().unwrap();
        assert!(
            early.is_err(),
            "a full outbound queue did not apply backpressure"
        );
        assert_eq!(result.unwrap(), io::ErrorKind::ConnectionAborted);
    }

    #[test]
    fn transport_backpressure_bounds_bytes_and_messages() {
        for (messages, bytes) in [(2, 4), (1, 64)] {
            let queue = Arc::new(Queue {
                buffered: Mutex::new(Buffered {
                    events: VecDeque::new(),
                    bytes: 0,
                }),
                space: Condvar::new(),
                messages,
                bytes,
                wake: Arc::default(),
            });
            let stop = Arc::new(AtomicBool::new(false));
            queue.push(Event::Frame(vec![1; 3]), 3, &stop);
            let (sent, received) = mpsc::channel();
            let (producer, stopped) = (queue.clone(), stop.clone());
            let thread = thread::spawn(move || {
                producer.push(Event::Frame(vec![2; 3]), 3, &stopped);
                sent.send(()).unwrap();
            });
            assert!(received.recv_timeout(POLL).is_err());
            assert!(matches!(queue.pop(), Some(Event::Frame(bytes)) if bytes == [1; 3]));
            received.recv_timeout(Duration::from_secs(1)).unwrap();
            thread.join().unwrap();
            assert!(matches!(queue.pop(), Some(Event::Frame(bytes)) if bytes == [2; 3]));
        }
    }

    #[test]
    fn transport_retry_preserves_partial_frame() {
        #[derive(Default)]
        struct Pipe {
            bytes: Vec<u8>,
            calls: usize,
        }
        impl Write for Pipe {
            fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
                self.calls += 1;
                if self.calls == 2 {
                    return Err(io::ErrorKind::TimedOut.into());
                }
                let take = if self.calls == 1 { 3 } else { bytes.len() };
                self.bytes.extend_from_slice(&bytes[..take]);
                Ok(take)
            }
            fn flush(&mut self) -> io::Result<()> {
                Ok(())
            }
        }
        let mut writer = RetryingWriter::new(Pipe::default(), || false);
        writer.write_all(b"one complete frame\n").unwrap();
        assert_eq!(writer.writer.bytes, b"one complete frame\n");
        let mut closed = RetryingWriter::new(
            Pipe {
                calls: 1,
                ..Pipe::default()
            },
            || true,
        );
        assert_eq!(
            closed.write_all(b"closed").unwrap_err().kind(),
            io::ErrorKind::TimedOut
        );
        let stopped = AtomicBool::new(false);
        let mut partial = RetryingWriter::new(Pipe::default(), || stopped.load(Ordering::SeqCst));
        assert_eq!(partial.write(b"abcdef").unwrap(), 3);
        stopped.store(true, Ordering::SeqCst);
        assert_eq!(
            partial.write(b"def").unwrap_err().kind(),
            io::ErrorKind::ConnectionAborted
        );
        assert_eq!(partial.writer.bytes, b"abc");
    }
}
