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
                    reason: timeout.reason,
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
                    reason: timeout.reason,
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
