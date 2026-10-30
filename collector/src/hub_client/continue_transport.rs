//! Work around ureq-proto 0.6's rejection of headers on 100 Continue.
//! Caddy can send its own bare 100, then relay the hub's 100 with Server: Caddy.
//! Normalize only 100 response heads, after TLS, retaining the admission handshake.

use std::io;
use std::time::Instant;

use ureq::unversioned::resolver::DefaultResolver;
use ureq::unversioned::transport::{
    Buffers, ConnectionDetails, Connector, DefaultConnector, LazyBuffers, NextTimeout, Transport,
};

const MAX_HEAD_BYTES: usize = 64 * 1024;
const MAX_INTERIM_RESPONSES: usize = 16;

pub(super) fn agent(config: ureq::config::Config) -> ureq::Agent {
    ureq::Agent::with_parts(
        config,
        DefaultConnector::default().chain(ContinueConnector),
        DefaultResolver::default(),
    )
}

#[derive(Debug)]
struct ContinueConnector;

impl Connector<Box<dyn Transport>> for ContinueConnector {
    type Out = ContinueTransport;

    fn connect(
        &self,
        _: &ConnectionDetails,
        chained: Option<Box<dyn Transport>>,
    ) -> Result<Option<Self::Out>, ureq::Error> {
        Ok(chained.map(|inner| ContinueTransport {
            inner,
            buffers: LazyBuffers::new(2 * MAX_HEAD_BYTES, 16 * 1024),
            head: Vec::new(),
            interim_responses: 0,
            final_response: false,
        }))
    }
}

#[derive(Debug)]
struct ContinueTransport {
    inner: Box<dyn Transport>,
    buffers: LazyBuffers,
    head: Vec<u8>,
    interim_responses: usize,
    final_response: bool,
}

fn invalid(message: &'static str) -> ureq::Error {
    io::Error::new(io::ErrorKind::InvalidData, message).into()
}

impl Transport for ContinueTransport {
    fn buffers(&mut self) -> &mut dyn Buffers {
        &mut self.buffers
    }

    fn transmit_output(&mut self, amount: usize, timeout: NextTimeout) -> Result<(), ureq::Error> {
        // A pooled connection starts a new exchange after the final response.
        // Body writes happen before that response and do not reset the filter.
        if self.final_response {
            self.final_response = false;
            self.interim_responses = 0;
        }
        // The wrapped TLS/TCP transport may have a smaller output buffer.
        let started = Instant::now();
        let mut sent = 0;
        while sent < amount {
            let output = self.inner.buffers().output();
            let count = output.len().min(amount - sent);
            output[..count].copy_from_slice(&self.buffers.output()[sent..sent + count]);
            let after = timeout.after.saturating_sub(started.elapsed());
            if after.is_zero() {
                return Err(ureq::Error::Timeout(timeout.reason));
            }
            self.inner.transmit_output(
                count,
                NextTimeout {
                    after: after.into(),
                    ..timeout
                },
            )?;
            sent += count;
        }
        Ok(())
    }

    fn await_input(&mut self, timeout: NextTimeout) -> Result<bool, ureq::Error> {
        let started = Instant::now();
        loop {
            let mut headers = [httparse::EMPTY_HEADER; 128];
            let mut response = httparse::Response::new(&mut headers);
            let parsed = response
                .parse(&self.head)
                .map_err(|_| invalid("invalid informational response head"))?;
            let httparse::Status::Complete(length) = parsed else {
                if self.head.len() == MAX_HEAD_BYTES {
                    return Err(invalid("response head exceeds 64 KiB"));
                }
                let after = timeout.after.saturating_sub(started.elapsed());
                if after.is_zero() {
                    return Err(ureq::Error::Timeout(timeout.reason));
                }
                let remaining = NextTimeout {
                    after: after.into(),
                    ..timeout
                };
                if !self.inner.maybe_await_input(remaining)? {
                    if !self.head.is_empty() {
                        return Err(invalid("incomplete informational response"));
                    }
                    return Ok(false);
                }
                let input = self.inner.buffers().input();
                if self.final_response {
                    let output = self.buffers.input_append_buf();
                    let count = input.len().min(output.len());
                    output[..count].copy_from_slice(&input[..count]);
                    self.buffers.input_appended(count);
                    self.inner.buffers().input_consume(count);
                    return Ok(true);
                }
                // Head parsing and any body prefetch share this fixed byte cap.
                let count = input.len().min(MAX_HEAD_BYTES - self.head.len());
                self.head.extend_from_slice(&input[..count]);
                self.inner.buffers().input_consume(count);
                continue;
            };
            let status = response.code.unwrap_or_default();
            if (100..200).contains(&status) {
                self.interim_responses += 1;
                if self.interim_responses > MAX_INTERIM_RESPONSES {
                    return Err(invalid("too many informational responses"));
                }
            }
            let output = if status == 100 {
                b"HTTP/1.1 100 Continue\r\n\r\n".as_slice()
            } else {
                self.final_response = !(102..200).contains(&status);
                &self.head[..length]
            };
            self.buffers.input_append_buf()[..output.len()].copy_from_slice(output);
            self.buffers.input_appended(output.len());
            self.head.drain(..length);
            // A final response's remaining bytes are its body, passed unchanged.
            // Interim tails stay pending for parsing the next response head.
            if self.final_response && !self.head.is_empty() {
                self.buffers.input_append_buf()[..self.head.len()].copy_from_slice(&self.head);
                self.buffers.input_appended(self.head.len());
                self.head.clear();
            }
            return Ok(true);
        }
    }

    fn is_open(&mut self) -> bool {
        self.inner.is_open()
    }
    fn is_tls(&self) -> bool {
        self.inner.is_tls()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;
    use std::sync::{Arc, Mutex};

    #[derive(Debug)]
    struct Input {
        buffers: LazyBuffers,
        chunks: VecDeque<Result<Vec<u8>, ureq::Timeout>>,
        sent: Arc<Mutex<Vec<u8>>>,
    }
    impl Transport for Input {
        fn buffers(&mut self) -> &mut dyn Buffers {
            &mut self.buffers
        }
        fn transmit_output(&mut self, amount: usize, _: NextTimeout) -> Result<(), ureq::Error> {
            self.sent
                .lock()
                .unwrap()
                .extend_from_slice(&self.buffers.output()[..amount]);
            Ok(())
        }
        fn await_input(&mut self, timeout: NextTimeout) -> Result<bool, ureq::Error> {
            assert!(timeout.after <= Duration::from_secs(1).into());
            match self.chunks.pop_front() {
                Some(Ok(bytes)) => {
                    self.buffers.input_append_buf()[..bytes.len()].copy_from_slice(&bytes);
                    self.buffers.input_appended(bytes.len());
                    Ok(true)
                }
                Some(Err(reason)) => Err(ureq::Error::Timeout(reason)),
                None => Ok(false),
            }
        }
        fn is_open(&mut self) -> bool {
            true
        }
    }
    use std::time::Duration;
    fn transport(chunks: Vec<Result<Vec<u8>, ureq::Timeout>>) -> ContinueTransport {
        ContinueTransport {
            inner: Box::new(Input {
                buffers: LazyBuffers::new(128 * 1024, 3),
                chunks: chunks.into(),
                sent: Arc::default(),
            }),
            buffers: LazyBuffers::new(2 * MAX_HEAD_BYTES, 16 * 1024),
            head: Vec::new(),
            interim_responses: 0,
            final_response: false,
        }
    }
    fn timeout() -> NextTimeout {
        NextTimeout {
            after: Duration::from_secs(1).into(),
            reason: ureq::Timeout::RecvResponse,
            per_read: None,
            per_write: None,
        }
    }
    fn drain(transport: &mut ContinueTransport) -> Result<Vec<u8>, ureq::Error> {
        let mut bytes = Vec::new();
        while transport.await_input(timeout())? {
            let input = transport.buffers().input();
            bytes.extend_from_slice(input);
            let len = input.len();
            transport.buffers().input_consume(len);
        }
        Ok(bytes)
    }
    #[test]
    fn every_split_and_coalesced_heads_preserve_body_bytes() {
        let wire=b"HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 100 Continue\r\nServer: Caddy\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n\0\xff\r\n100xyz";
        let expected=b"HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n\0\xff\r\n100xyz";
        for split in 0..=wire.len() {
            let chunks = [&wire[..split], &wire[split..]]
                .into_iter()
                .filter(|b| !b.is_empty())
                .map(|b| Ok(b.to_vec()))
                .collect();
            assert_eq!(
                drain(&mut transport(chunks)).unwrap(),
                expected,
                "split={split}"
            );
        }
        assert_eq!(
            drain(&mut transport(
                wire.chunks(1).map(|b| Ok(b.to_vec())).collect()
            ))
            .unwrap(),
            expected
        );
    }
    #[test]
    fn no_continue_and_other_informational_responses_are_unchanged() {
        for wire in [
            b"HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nyes".as_slice(),
            b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: test\r\n\r\nraw\0bytes",
            b"HTTP/1.1 103 Early Hints\r\nLink: </test>\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nyes",
        ] {
            for split in 0..=wire.len() {
                let chunks=[&wire[..split],&wire[split..]].into_iter().filter(|b| !b.is_empty()).map(|b| Ok(b.to_vec())).collect();
                assert_eq!(drain(&mut transport(chunks)).unwrap(),wire,"split={split}");
            }
        }
        let mut filter=transport(vec![Ok(b"HTTP/1.1 103 Early Hints\r\nLink: </test>\r\n\r\nHTTP/1.1 100 Continue\r\nServer: Caddy\r\n\r\nHTTP/1.1 204 No Content\r\n\r\n".to_vec())]);
        assert_eq!(drain(&mut filter).unwrap(),b"HTTP/1.1 103 Early Hints\r\nLink: </test>\r\n\r\nHTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 204 No Content\r\n\r\n");
    }
    #[test]
    fn sixteen_interims_are_allowed_and_seventeen_are_refused() {
        for count in [16, 17] {
            let mut wire = b"HTTP/1.1 100 Continue\r\nServer: Caddy\r\n\r\n".repeat(count);
            wire.extend_from_slice(b"HTTP/1.1 204 No Content\r\n\r\n");
            let result = drain(&mut transport(vec![Ok(wire)]));
            if count == 16 {
                let mut expected = b"HTTP/1.1 100 Continue\r\n\r\n".repeat(count);
                expected.extend_from_slice(b"HTTP/1.1 204 No Content\r\n\r\n");
                assert_eq!(result.unwrap(), expected);
            } else {
                assert!(
                    result
                        .unwrap_err()
                        .to_string()
                        .contains("too many informational responses")
                );
            }
        }
    }
    #[test]
    fn partial_head_timeout_retains_bytes_and_timeout_reason() {
        let mut filter = transport(vec![
            Ok(b"HTTP/1.1 100 Continue\r\nServer:".to_vec()),
            Err(ureq::Timeout::Await100),
            Ok(b" Caddy\r\n\r\nHTTP/1.1 204 No Content\r\n\r\n".to_vec()),
        ]);
        assert!(matches!(
            filter.await_input(NextTimeout {
                reason: ureq::Timeout::Await100,
                ..timeout()
            }),
            Err(ureq::Error::Timeout(ureq::Timeout::Await100))
        ));
        assert!(
            filter.buffers().input().is_empty(),
            "never emit a partial head"
        );
        assert_eq!(
            drain(&mut filter).unwrap(),
            b"HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 204 No Content\r\n\r\n"
        );
        let mut expired = transport(vec![Ok(b"HTTP/1.1 100".to_vec())]);
        assert!(matches!(
            expired.await_input(NextTimeout {
                after: Duration::ZERO.into(),
                ..timeout()
            }),
            Err(ureq::Error::Timeout(ureq::Timeout::RecvResponse))
        ));
    }
    #[test]
    fn two_exchanges_reuse_one_pooled_connection() {
        use std::io::{Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = std::thread::spawn(move || {
            let (mut socket, _) = listener.accept().unwrap();
            socket
                .set_read_timeout(Some(Duration::from_secs(5)))
                .unwrap();
            for body in [b"one", b"two"] {
                let mut head = Vec::new();
                while !head.ends_with(b"\r\n\r\n") {
                    let mut byte = [0];
                    socket.read_exact(&mut byte).unwrap();
                    head.push(byte[0]);
                }
                assert!(String::from_utf8_lossy(&head).starts_with("GET /"));
                socket.write_all(b"HTTP/1.1 100 Continue\r\nServer: Caddy\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\n").unwrap();
                socket.write_all(body).unwrap();
                socket.flush().unwrap();
            }
        });
        let agent = agent(
            ureq::Agent::config_builder()
                .timeout_global(Some(Duration::from_secs(5)))
                .build(),
        );
        for body in ["one", "two"] {
            assert_eq!(
                agent
                    .get(format!("http://{address}/"))
                    .call()
                    .unwrap()
                    .body_mut()
                    .read_to_string()
                    .unwrap(),
                body
            );
        }
        server.join().unwrap();
    }
}
