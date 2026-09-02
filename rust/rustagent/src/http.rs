//! The backend over HTTP: a REST surface, and answers that stream.
//!
//! Everything the backend does is already one shape — a JSON request with an
//! `op`, a JSON reply with `ok` and either `data` or `error` — so the REST
//! mapping is thin on purpose:
//!
//! ```text
//! GET  /                     what this server is, and every route
//! GET  /health               the health op, so a probe needs no body
//! GET  /ops                  every op this backend answers
//! POST /v1/<op>              any op: the body is the request, minus `op`
//! POST /v1/chat              a turn (`{"text": "...", "agent": "food"}`)
//! GET  /v1/chat/stream?text=…&agent=…    the same turn, as Server-Sent Events
//! POST /v1/chat/stream       the same, with the request in the body
//! ```
//!
//! `/v1/chat/stream` is the one that matters. A turn against the on-device
//! model takes seconds, and a client that has to wait for all of it before
//! showing anything feels broken. So the streaming routes answer
//! `text/event-stream` and push one frame per piece as the model writes:
//!
//! ```text
//! event: token
//! data: {"text":"A hash map "}
//!
//! event: tool
//! data: {"text":"searched the archive for \"pork belly\""}
//!
//! event: done
//! data: {"ok":true,"op":"chat","data":{ …the whole turn… }}
//! ```
//!
//! `done` carries exactly what `POST /v1/chat` would have returned, so a
//! client that only reads `done` is a correct client — the token frames are
//! there to be shown, not to be reassembled into the answer.
//!
//! SSE beside the WebSocket, deliberately: SSE is a plain HTTP response any
//! client can read — `curl -N`, a browser's `EventSource`, a shell script —
//! with no library at all. The WebSocket in [`crate::server`] is for the
//! clients that also need to talk back mid-turn (a stop, another request);
//! both carry the same pieces from the same sink.
//!
//! # Shape
//!
//! This module is the HTTP half of [`crate::server`]: it parses a request,
//! routes it to an op, and writes the reply — plain or as an event stream.
//! The accept loop and the dispatcher thread that owns the [`Backend`] live
//! there, shared with the other two transports, and hand this module the
//! socket to answer on. A streaming reply is written by the dispatcher as
//! it generates, so the socket travels with the job rather than being
//! borrowed.
//!
//! # Reach
//!
//! It binds `127.0.0.1` unless told otherwise. There is no authentication
//! here — anything that can reach the port can read the archive and spend
//! the GPU — so binding anywhere else is a decision to be made deliberately,
//! and [`serve`] says so on the way up.

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpStream;

use serde_json::{json, Value};

use crate::harness::Chunk;
use crate::proto::Backend;

/// How much of a request body will be read. A turn is a sentence; anything
/// this large is a mistake or an attack, and either way is refused rather
/// than allocated.
const MAX_BODY: usize = 1 << 20;

/// Serve `backend` on `addr` until the process ends: the whole server —
/// HTTP, SSE and the WebSocket — on one port. See [`crate::server::serve`].
pub fn serve(backend: Backend, addr: &str) -> std::io::Result<()> {
    crate::server::serve(backend, addr)
}

/// A parsed request line and headers.
struct Request {
    method: String,
    path: String,
    query: HashMap<String, String>,
    body: Vec<u8>,
}

/// One HTTP connection: parse, route, and hand the socket to the dispatcher
/// through `enqueue`, which returns false when the backend is gone.
pub(crate) fn handle(
    stream: TcpStream,
    enqueue: &dyn Fn(Value, TcpStream, bool) -> bool,
) -> std::io::Result<()> {
    let req = match read_request(&stream) {
        Ok(r) => r,
        Err(e) => {
            let _ = write_json(
                &stream,
                400,
                &json!({ "ok": false, "error": e.to_string() }),
            );
            return Ok(());
        }
    };

    // The routes that need no backend at all.
    match (req.method.as_str(), req.path.as_str()) {
        ("GET", "/") => return write_json(&stream, 200, &index()),
        ("GET", "/ops") => {
            return write_json(
                &stream,
                200,
                &json!({ "ok": true, "data": crate::proto::OPS }),
            )
        }
        ("OPTIONS", _) => return write_head(&stream, 204, "text/plain", &[]),
        _ => {}
    }

    let (request, sse) = match route(&req) {
        Ok(pair) => pair,
        Err(status) => {
            let body = json!({
                "ok": false,
                "error": format!("no route {} {}", req.method, req.path),
                "routes": index()["routes"],
            });
            return write_json(&stream, status, &body);
        }
    };

    // The socket goes with the job: the dispatcher writes the reply itself,
    // because a streaming one is written across the whole turn.
    if !enqueue(request, stream.try_clone()?, sse) {
        let _ = write_json(
            &stream,
            503,
            &json!({ "ok": false, "error": "the backend is gone" }),
        );
    }
    Ok(())
}

/// Which op a request is asking for, and whether it wants it streamed.
fn route(req: &Request) -> Result<(Value, bool), u16> {
    let body: Value = if req.body.is_empty() {
        json!({})
    } else {
        serde_json::from_slice(&req.body).unwrap_or_else(|_| json!({}))
    };
    let mut request = body.as_object().cloned().unwrap_or_default();
    // Query parameters fill in what the body did not carry, so a stream can
    // be opened with a plain GET from anything that speaks EventSource.
    for (k, v) in &req.query {
        request.entry(k.clone()).or_insert_with(|| json!(v));
    }

    let (op, sse) = match (req.method.as_str(), req.path.as_str()) {
        ("GET", "/health") => ("health", false),
        ("GET", "/v1/chat/stream") | ("POST", "/v1/chat/stream") => ("chat", true),
        ("POST", "/v1/brain.chat/stream") => ("brain.chat", true),
        ("POST", path) => match path.strip_prefix("/v1/") {
            // An op name is what the backend already answers; anything else
            // is a 404 here rather than an "unknown op" from the dispatcher,
            // because a wrong URL is a different mistake from a wrong op.
            Some(name) if crate::proto::OPS.contains(&name) => (name, false),
            _ => return Err(404),
        },
        _ => return Err(404),
    };
    request.insert("op".into(), json!(op));
    Ok((Value::Object(request), sse))
}

fn index() -> Value {
    json!({
        "ok": true,
        "name": "causewaybay jarvis — the robot backend",
        "routes": [
            "GET  /                  this",
            "GET  /health            is there a brain, and where does it run",
            "GET  /ops               every op this backend answers",
            "POST /v1/<op>           any op; the body is the request",
            "POST /v1/chat           one turn: {\"text\": \"...\", \"agent\": \"food\"}",
            "GET  /v1/chat/stream?text=…   the same turn, as server-sent events",
            "POST /v1/chat/stream    the same, request in the body",
            "WS   /ws                the same ops over a WebSocket, turns streamed",
        ],
        "events": ["token", "reasoning", "tool", "prefill", "done", "error"],
    })
}

/// Run one request and write its reply on `stream`, as one response or as
/// an event stream. Returns the reply, so the caller can see a `daemon.stop`
/// go past.
pub(crate) fn answer(backend: &Backend, request: &Value, mut stream: TcpStream, sse: bool) -> Value {
    if !sse {
        let reply = backend.handle(request);
        let _ = write_json(&stream, 200, &reply);
        return reply;
    }

    // A streaming reply: headers first, so the client sees the stream open
    // before the model has produced anything, then one frame per piece.
    if write_head(
        &stream,
        200,
        "text/event-stream",
        &[
            ("Cache-Control", "no-cache"),
            ("Connection", "keep-alive"),
            // Nagle would hold a two-hundred-byte frame back waiting for
            // company, which is the one thing a stream must not do.
            ("X-Accel-Buffering", "no"),
        ],
    )
    .is_err()
    {
        return json!({ "ok": false, "error": "the client went away" });
    }
    let _ = stream.set_nodelay(true);

    let mut dead = false;
    let mut sink = |chunk: Chunk<'_>| {
        if dead {
            // The reader hung up. Saying stop here is what cancels the
            // generation — a browser closing a tab should not leave the GPU
            // finishing a paragraph nobody will read.
            return false;
        }
        let (event, data) = match chunk {
            Chunk::Token(t) => ("token", json!({ "text": t })),
            Chunk::Reasoning(t) => ("reasoning", json!({ "text": t })),
            Chunk::Tool(t) => ("tool", json!({ "text": t })),
            Chunk::Prefill { done, total } => ("prefill", json!({ "done": done, "total": total })),
        };
        if write_event(&mut stream, event, &data).is_err() {
            dead = true;
            return false;
        }
        true
    };

    let op = request.get("op").and_then(Value::as_str).unwrap_or("chat");
    let reply = match op {
        "brain.chat" => {
            let messages: Result<Vec<crate::ollama::Message>, _> = serde_json::from_value(
                request
                    .get("messages")
                    .cloned()
                    .unwrap_or_else(|| json!([])),
            );
            match messages {
                Ok(messages) => {
                    let tools: Vec<Value> = request
                        .get("tools")
                        .and_then(Value::as_array)
                        .cloned()
                        .unwrap_or_default();
                    envelope(
                        "brain.chat",
                        backend.brain_chat_stream(&messages, &tools, &mut sink),
                    )
                }
                Err(e) => {
                    json!({ "ok": false, "op": "brain.chat", "error": format!("bad messages: {e}") })
                }
            }
        }
        _ => {
            let who = request.get("agent").and_then(Value::as_str);
            let text = request.get("text").and_then(Value::as_str).unwrap_or("");
            envelope(
                "chat",
                backend
                    .turn_stream(who, text, &mut sink)
                    .and_then(|t| Ok(serde_json::to_value(t)?)),
            )
        }
    };

    if !dead {
        let event = if reply["ok"] == json!(true) {
            "done"
        } else {
            "error"
        };
        let _ = write_event(&mut stream, event, &reply);
        let _ = stream.flush();
    }
    reply
}

pub(crate) fn envelope<T>(op: &str, result: anyhow::Result<T>) -> Value
where
    Value: From<T>,
{
    match result {
        Ok(data) => json!({ "ok": true, "op": op, "data": Value::from(data) }),
        Err(e) => json!({ "ok": false, "op": op, "error": e.to_string() }),
    }
}

/* ------------------------------------------------------------- the wire ---- */

fn read_request(stream: &TcpStream) -> anyhow::Result<Request> {
    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    if reader.read_line(&mut line)? == 0 {
        anyhow::bail!("empty request");
    }
    let mut parts = line.split_whitespace();
    let method = parts.next().unwrap_or_default().to_string();
    let target = parts.next().unwrap_or_default().to_string();
    let (path, query) = split_query(&target);

    let mut length = 0usize;
    loop {
        let mut header = String::new();
        if reader.read_line(&mut header)? == 0 {
            break;
        }
        let header = header.trim_end();
        if header.is_empty() {
            break;
        }
        if let Some((name, value)) = header.split_once(':') {
            if name.eq_ignore_ascii_case("content-length") {
                length = value.trim().parse().unwrap_or(0);
            }
        }
    }
    if length > MAX_BODY {
        anyhow::bail!("body of {length} bytes is too large (max {MAX_BODY})");
    }
    let mut body = vec![0u8; length];
    if length > 0 {
        reader.read_exact(&mut body)?;
    }
    Ok(Request {
        method,
        path,
        query,
        body,
    })
}

fn split_query(target: &str) -> (String, HashMap<String, String>) {
    let (path, raw) = match target.split_once('?') {
        Some((p, q)) => (p, q),
        None => (target, ""),
    };
    let mut query = HashMap::new();
    for pair in raw.split('&').filter(|s| !s.is_empty()) {
        let (k, v) = pair.split_once('=').unwrap_or((pair, ""));
        query.insert(percent_decode(k), percent_decode(v));
    }
    (path.to_string(), query)
}

/// Enough of a URL decoder for a query string: `%hh` and `+`.
fn percent_decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            b'%' if i + 2 < bytes.len() => {
                let hex = std::str::from_utf8(&bytes[i + 1..i + 3]).unwrap_or("");
                match u8::from_str_radix(hex, 16) {
                    Ok(byte) => {
                        out.push(byte);
                        i += 3;
                    }
                    Err(_) => {
                        out.push(bytes[i]);
                        i += 1;
                    }
                }
            }
            b => {
                out.push(b);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn reason(status: u16) -> &'static str {
    match status {
        200 => "OK",
        204 => "No Content",
        400 => "Bad Request",
        404 => "Not Found",
        503 => "Service Unavailable",
        _ => "Error",
    }
}

fn write_head(
    mut stream: &TcpStream,
    status: u16,
    content_type: &str,
    extra: &[(&str, &str)],
) -> std::io::Result<()> {
    let mut head = format!(
        "HTTP/1.1 {status} {}\r\nContent-Type: {content_type}\r\n",
        reason(status)
    );
    // The server is local and unauthenticated; a browser page loaded from
    // anywhere may read it, which is the point of a local API.
    head.push_str("Access-Control-Allow-Origin: *\r\n");
    head.push_str("Access-Control-Allow-Headers: Content-Type\r\n");
    head.push_str("Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n");
    for (name, value) in extra {
        head.push_str(&format!("{name}: {value}\r\n"));
    }
    head.push_str("\r\n");
    stream.write_all(head.as_bytes())?;
    stream.flush()
}

fn write_json(mut stream: &TcpStream, status: u16, body: &Value) -> std::io::Result<()> {
    let text = body.to_string();
    let head = format!(
        "HTTP/1.1 {status} {}\r\nContent-Type: application/json\r\n\
         Content-Length: {}\r\nAccess-Control-Allow-Origin: *\r\n\
         Connection: close\r\n\r\n",
        reason(status),
        text.len()
    );
    stream.write_all(head.as_bytes())?;
    stream.write_all(text.as_bytes())?;
    stream.flush()
}

/// One SSE frame. The data is JSON on a single line, which is what makes
/// `data:` safe to write without worrying about embedded newlines.
fn write_event(stream: &mut TcpStream, event: &str, data: &Value) -> std::io::Result<()> {
    write!(stream, "event: {event}\ndata: {data}\n\n")?;
    stream.flush()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn get(path: &str) -> Request {
        Request {
            method: "GET".into(),
            path: split_query(path).0,
            query: split_query(path).1,
            body: Vec::new(),
        }
    }

    fn post(path: &str, body: &str) -> Request {
        Request {
            method: "POST".into(),
            path: split_query(path).0,
            query: split_query(path).1,
            body: body.as_bytes().to_vec(),
        }
    }

    #[test]
    fn a_query_string_is_split_and_decoded() {
        let (path, query) = split_query("/v1/chat/stream?text=pork+belly%20buns&agent=food");
        assert_eq!(path, "/v1/chat/stream");
        assert_eq!(query.get("text").unwrap(), "pork belly buns");
        assert_eq!(query.get("agent").unwrap(), "food");
    }

    #[test]
    fn a_stream_can_be_opened_with_a_plain_get() {
        let (request, sse) = route(&get("/v1/chat/stream?text=hello&agent=food")).unwrap();
        assert!(sse);
        assert_eq!(request["op"], json!("chat"));
        assert_eq!(request["text"], json!("hello"));
        assert_eq!(request["agent"], json!("food"));
    }

    #[test]
    fn a_body_wins_over_a_query_parameter_of_the_same_name() {
        let (request, _) = route(&post(
            "/v1/chat?text=from-the-url",
            r#"{"text":"from the body"}"#,
        ))
        .unwrap();
        assert_eq!(request["text"], json!("from the body"));
    }

    #[test]
    fn every_op_the_backend_answers_has_a_route() {
        for op in crate::proto::OPS {
            let (request, sse) = route(&post(&format!("/v1/{op}"), "{}"))
                .unwrap_or_else(|_| panic!("no route for {op}"));
            assert_eq!(request["op"], json!(op));
            assert!(!sse);
        }
    }

    #[test]
    fn an_unknown_route_is_a_404_rather_than_an_unknown_op() {
        assert_eq!(route(&post("/v1/nonsense", "{}")).unwrap_err(), 404);
        assert_eq!(route(&get("/nowhere")).unwrap_err(), 404);
        // …and a GET where a POST belongs is not quietly accepted.
        assert_eq!(route(&get("/v1/chat")).unwrap_err(), 404);
    }

    #[test]
    fn a_health_check_needs_no_body() {
        let (request, sse) = route(&get("/health")).unwrap();
        assert_eq!(request["op"], json!("health"));
        assert!(!sse);
    }

    #[test]
    fn a_body_that_is_not_json_does_not_take_the_request_down_with_it() {
        // The op is in the path; a broken body just means no arguments.
        let (request, _) = route(&post("/v1/stats", "}{")).unwrap();
        assert_eq!(request["op"], json!("stats"));
    }
}
