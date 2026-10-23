//! Protocol v1 framing and validation. Work/commit acknowledgements belong to S2b/S3a.
use serde::Deserialize;
use serde_json::{Value, json};
use std::io::{self, BufRead, Write};

pub const VERSION: u64 = 1;
pub const MAX_REQUEST_BYTES: usize = 64 * 1024;
pub const MAX_EVENT_BYTES: usize = 16 * 1024 * 1024;

#[derive(Clone, Deserialize)]
pub struct Request {
    pub v: u64,
    pub id: String,
    pub op: String,
    pub client: Option<String>,
    pub lifetime: Option<String>,
    pub entry: Option<String>,
    /// Ownership metadata for hook wake-ups, never a collection command.
    pub queue: Option<std::path::PathBuf>,
    pub database_key: Option<String>,
    #[serde(default)]
    pub harnesses: Vec<String>,
    pub harness: Option<String>,
    pub path: Option<String>,
    pub force: Option<bool>,
    pub parser_workers: Option<usize>,
}

pub enum Frame {
    Eof,
    Partial,
    Complete,
}

/// Consume at most one buffered chunk, so control cancellation is checked even
/// while a slow peer continuously supplies bytes without completing a line.
pub fn read_frame(
    reader: &mut impl BufRead,
    line: &mut Vec<u8>,
    limit: usize,
) -> io::Result<Frame> {
    let bytes = reader.fill_buf()?;
    if bytes.is_empty() {
        return if line.is_empty() {
            Ok(Frame::Eof)
        } else {
            Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "unterminated request",
            ))
        };
    }
    let take = bytes
        .iter()
        .position(|b| *b == b'\n')
        .map_or(bytes.len(), |at| at + 1);
    if line.len() + take > limit {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "protocol frame exceeds limit",
        ));
    }
    let complete = bytes[take - 1] == b'\n';
    line.extend_from_slice(&bytes[..take]);
    reader.consume(take);
    if complete {
        return Ok(Frame::Complete);
    }
    Ok(Frame::Partial)
}

pub fn decode(line: &[u8]) -> Result<Request, Value> {
    let value: Value = serde_json::from_slice(line)
        .map_err(|_| error("", "bad_request", "invalid JSON request"))?;
    let id = value.get("id").and_then(Value::as_str).unwrap_or("");
    let v = value
        .get("v")
        .and_then(Value::as_u64)
        .ok_or_else(|| error(id, "bad_request", "missing protocol version"))?;
    if v != VERSION {
        return Err(error(
            id,
            "unsupported_version",
            "this server supports protocol v1",
        ));
    }
    if value.get("arguments").is_some()
        || value.get("collection").is_some()
        || value.get("cwd").is_some()
    {
        return Err(error(
            id,
            "bad_request",
            "CLI command forwarding is not supported",
        ));
    }
    let request: Request = serde_json::from_value(value)
        .map_err(|_| error("", "bad_request", "request requires v, id and op"))?;
    if request.id.is_empty() {
        return Err(error("", "bad_request", "request id must not be empty"));
    }
    Ok(request)
}
pub fn event(id: &str, name: &str) -> Value {
    json!({"v": VERSION, "id": id, "event": name})
}
pub fn error(id: &str, code: &str, message: &str) -> Value {
    json!({"v": VERSION, "id": id, "event": "error", "code": code, "message": message})
}
pub fn send(writer: &mut impl Write, value: &Value) -> io::Result<()> {
    let mut bytes = serde_json::to_vec(value)?;
    if bytes.len() >= MAX_EVENT_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "event exceeds 16 MiB",
        ));
    }
    bytes.push(b'\n');
    writer.write_all(&bytes)?;
    writer.flush()
}
