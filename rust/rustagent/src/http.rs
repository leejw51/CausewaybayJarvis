//! The backend over HTTP: a REST surface, answers that stream, and the web
//! client with the shelves behind it.
//!
//! Everything the backend does is already one shape — a JSON request with an
//! `op`, a JSON reply with `ok` and either `data` or `error` — so the REST
//! mapping is thin on purpose:
//!
//! ```text
//! GET  /                     the web client (a browser); /api is the JSON index
//! GET  /api                  what this server is, and every route
//! GET  /where                where this server can be reached from — the phone's URL
//! GET  /health               the health op, so a probe needs no body
//! GET  /ops                  every op this backend answers
//! POST /v1/<op>              any op: the body is the request, minus `op`
//! POST /v1/chat              a turn (`{"text": "...", "agent": "food"}`)
//! GET  /v1/chat/stream?text=…&agent=…    the same turn, as Server-Sent Events
//! POST /v1/chat/stream       the same, with the request in the body
//! GET  /file/<path>          a file on a shelf: agents/<GUID>/photos/cat.png
//! POST /upload?agent=…&name=…            the body is the file; it is filed
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
//! # The shelves, over HTTP
//!
//! `/file/<path>` hands out what is on a shelf, by the same relative path
//! the database holds — `agents/<GUID>/videos/holiday.mov` — and nothing
//! else: only `agents/…` and `global/…`, never a database file, and never a
//! path that climbs (that is [`crate::space::Space::resolve`]'s job). It
//! answers byte ranges, because an iPhone will not play a video from a
//! server that does not, and `HEAD`, because a browser asks that first.
//!
//! `/upload` is the other direction: the request body *is* the file, and
//! the query says whose and what it was called. The bytes are streamed into
//! the space's `tmp/` on the connection's own thread — a phone video is
//! hundreds of megabytes and the dispatcher must not wait on it — and then
//! filed with the same `item.add` every other client uses, which copies it
//! onto the shelf, makes the LÖVE clip if it is a video, and removes the
//! temporary file.
//!
//! # Shape
//!
//! This module is the HTTP half of [`crate::server`]: it parses a request,
//! routes it to an op, and writes the reply — plain or as an event stream.
//! The accept loop and the dispatcher thread that owns the [`Backend`] live
//! there, shared with the other two transports, and hand this module the
//! socket to answer on. A streaming reply is written by the dispatcher as
//! it generates, so the socket travels with the job rather than being
//! borrowed. Files and the web client never reach the dispatcher at all:
//! they are read off the disk by the connection's thread.
//!
//! # Reach
//!
//! It binds `127.0.0.1` unless told otherwise. There is no authentication
//! here — anything that can reach the port can read the archive and spend
//! the GPU — so binding anywhere else is a decision to be made deliberately,
//! and [`crate::server::listen`] says so on the way up.

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{SocketAddr, TcpStream};

use serde_json::{json, Value};

use crate::harness::Chunk;
use crate::proto::Backend;
use crate::space::Space;

/// How much of a JSON request body will be read. A turn is a sentence;
/// anything this large is a mistake or an attack, and either way is refused
/// rather than allocated.
const MAX_BODY: usize = 1 << 20;

/// How large an upload may be. A phone's 4K video is a few hundred
/// megabytes a minute; this is the ceiling, not the expectation.
const MAX_UPLOAD: u64 = 8 << 30;

/// The chunk a file is written to the socket in.
const CHUNK: usize = 64 << 10;

/// What the connection threads know about the server they answer for: the
/// space the files come from, and where a browser can find it.
pub(crate) struct Site {
    pub space: Space,
    pub addr: SocketAddr,
    /// Every URL this server answers on — `http://127.0.0.1:…/`, and when
    /// it is bound to every interface, the LAN address and the `.local`
    /// name a phone can type.
    pub urls: Vec<String>,
}

/// Serve `backend` on `addr` until the process ends: the whole server —
/// HTTP, SSE and the WebSocket — on one port. See [`crate::server::serve`].
pub fn serve(backend: Backend, addr: &str) -> std::io::Result<()> {
    crate::server::serve(backend, addr)
}

/// The request line and the headers, before any body has been read.
struct Head {
    method: String,
    path: String,
    query: HashMap<String, String>,
    headers: Vec<(String, String)>,
    length: u64,
}

impl Head {
    fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }
}

/// A parsed request with its body in memory: the JSON routes.
struct Request {
    method: String,
    path: String,
    query: HashMap<String, String>,
    body: Vec<u8>,
}

/// One HTTP connection: parse, route, and either answer here — a file, the
/// web client, the index — or hand the socket to the dispatcher through
/// `enqueue`, which returns false when the backend is gone.
pub(crate) fn handle(
    stream: TcpStream,
    site: &Site,
    enqueue: &dyn Fn(Value, TcpStream, bool) -> bool,
) -> std::io::Result<()> {
    let mut reader = BufReader::new(stream.try_clone()?);
    let head = match read_head(&mut reader) {
        Ok(h) => h,
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
    match (head.method.as_str(), head.path.as_str()) {
        ("OPTIONS", _) => return write_head(&stream, 204, "text/plain", &[]),
        ("GET" | "HEAD", "/api") => return write_json(&stream, 200, &index()),
        ("GET" | "HEAD", "/ops") => {
            return write_json(
                &stream,
                200,
                &json!({ "ok": true, "data": crate::proto::OPS }),
            )
        }
        ("GET" | "HEAD", "/where") => {
            return write_json(
                &stream,
                200,
                &json!({
                    "ok": true,
                    "data": {
                        "bind": site.addr.ip().to_string(),
                        "port": site.addr.port(),
                        "loopback": site.addr.ip().is_loopback(),
                        "urls": site.urls,
                        "space": site.space.tilde(site.space.root()),
                        "version": env!("CARGO_PKG_VERSION"),
                    }
                }),
            )
        }
        ("GET" | "HEAD", path) if path == "/" || crate::web::asset(path).is_some() => {
            return serve_asset(&stream, &head);
        }
        ("GET" | "HEAD", path) if path.starts_with("/file/") => {
            return serve_file(&stream, site, &head);
        }
        ("POST" | "PUT", "/upload") => return upload(&stream, &mut reader, site, &head, enqueue),
        _ => {}
    }

    // Everything else is an op with a JSON body, read here in full.
    if head.length > MAX_BODY as u64 {
        let _ = write_json(
            &stream,
            413,
            &json!({ "ok": false, "error": format!("body of {} bytes is too large (max {MAX_BODY})", head.length) }),
        );
        return Ok(());
    }
    let mut body = vec![0u8; head.length as usize];
    if head.length > 0 {
        reader.read_exact(&mut body)?;
    }
    let req = Request {
        method: head.method,
        path: head.path,
        query: head.query,
        body,
    };

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
        "version": env!("CARGO_PKG_VERSION"),
        "routes": [
            "GET  /                  the web client — every agent, every shelf, in a browser",
            "GET  /api               this",
            "GET  /where             where this server can be reached from, for a phone",
            "GET  /health            is there a brain, and where does it run",
            "GET  /ops               every op this backend answers",
            "POST /v1/<op>           any op; the body is the request",
            "POST /v1/chat           one turn: {\"text\": \"...\", \"agent\": \"food\"}",
            "GET  /v1/chat/stream?text=…   the same turn, as server-sent events",
            "POST /v1/chat/stream    the same, request in the body",
            "GET  /file/<path>       a file on a shelf, by its path in the space (byte ranges honoured)",
            "POST /upload?agent=…&name=…   file the body with an agent; a video gets its LÖVE clip",
            "WS   /ws                the same ops over a WebSocket, turns streamed",
        ],
        "events": ["token", "reasoning", "tool", "prefill", "done", "error"],
    })
}

/* ---------------------------------------------------------- the client ---- */

/// The web client and its files, out of the binary (or off the disk, in
/// development). Revalidated by ETag, so a reload after a rebuild sees the
/// new page and a reload without one costs a round trip and no bytes.
fn serve_asset(stream: &TcpStream, head: &Head) -> std::io::Result<()> {
    let Some((mime, body)) = crate::web::asset(&head.path) else {
        return write_json(
            stream,
            404,
            &json!({ "ok": false, "error": "no such page" }),
        );
    };
    let tag = crate::web::etag(&head.path);
    if head.header("if-none-match") == Some(tag.as_str())
        && std::env::var(crate::web::DIR_ENV).is_err()
    {
        return write_head(stream, 304, mime, &[("ETag", &tag)]);
    }
    write_head(
        stream,
        200,
        mime,
        &[
            ("Content-Length", &body.len().to_string()),
            ("Cache-Control", "no-cache"),
            ("ETag", &tag),
            ("Connection", "close"),
        ],
    )?;
    if head.method != "HEAD" {
        let mut out = stream;
        out.write_all(&body)?;
        out.flush()?;
    }
    Ok(())
}

/* ---------------------------------------------------------- the shelves --- */

/// The relative path a `/file/…` URL names, checked: only the two folders
/// that hold shelves, never a database or the temp folder. The path is
/// percent-decoded, and `Space::resolve` refuses anything that climbs.
pub fn shelf_path(url_path: &str) -> Result<String, &'static str> {
    let rel = url_path.strip_prefix("/file/").ok_or("not a file route")?;
    let rel = percent_decode(rel);
    let rel = rel.trim_start_matches('/');
    if !(rel.starts_with("agents/") || rel.starts_with("global/")) {
        return Err("only the shelves are served: agents/… and global/…");
    }
    let name = rel.rsplit('/').next().unwrap_or("");
    if name.is_empty() {
        return Err("a folder is not a file");
    }
    let lower = name.to_ascii_lowercase();
    if lower.ends_with(".db") || lower.contains(".db-") {
        return Err("the database is not served");
    }
    if rel.split('/').any(|part| part == "..") {
        return Err("path escapes the space");
    }
    Ok(rel.to_string())
}

/// One file off a shelf, whole or the byte range asked for.
fn serve_file(stream: &TcpStream, site: &Site, head: &Head) -> std::io::Result<()> {
    let rel = match shelf_path(&head.path) {
        Ok(rel) => rel,
        Err(why) => return write_json(stream, 404, &json!({ "ok": false, "error": why })),
    };
    let path = match site.space.resolve(&rel) {
        Ok(p) if p.is_file() => p,
        Ok(_) => {
            return write_json(
                stream,
                404,
                &json!({ "ok": false, "error": format!("no file {rel}") }),
            )
        }
        Err(e) => return write_json(stream, 404, &json!({ "ok": false, "error": e.to_string() })),
    };
    let meta = std::fs::metadata(&path)?;
    let total = meta.len();
    let modified = meta
        .modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let tag = format!("\"{total}-{modified}\"");
    let name = rel.rsplit('/').next().unwrap_or("file");
    let (mime, disposition) = file_headers(&rel, name);

    if head.header("if-none-match") == Some(tag.as_str()) {
        return write_head(
            stream,
            304,
            mime,
            &[("ETag", &tag), ("Accept-Ranges", "bytes")],
        );
    }

    let range = head.header("range").map(|r| parse_range(r, total));
    let (status, start, end) = match range {
        None => (200, 0, total.saturating_sub(1)),
        Some(Some((s, e))) => (206, s, e),
        Some(None) => {
            return write_head(
                stream,
                416,
                "text/plain",
                &[
                    ("Content-Range", &format!("bytes */{total}")),
                    ("Content-Length", "0"),
                    ("Connection", "close"),
                ],
            );
        }
    };
    let length = if total == 0 { 0 } else { end - start + 1 };
    let length_text = length.to_string();
    let content_range = format!("bytes {start}-{end}/{total}");
    let mut extra: Vec<(&str, &str)> = vec![
        ("Content-Length", &length_text),
        ("Accept-Ranges", "bytes"),
        ("ETag", &tag),
        ("Cache-Control", "private, max-age=0, must-revalidate"),
        ("Content-Disposition", &disposition),
        // A shelf holds whatever was uploaded. Nothing served from it may
        // run as part of this page: no scripts, no sniffing a text file
        // into HTML, and an origin of its own for anything that renders.
        ("Content-Security-Policy", "sandbox; default-src 'none'"),
        ("X-Content-Type-Options", "nosniff"),
        ("Connection", "close"),
    ];
    if status == 206 {
        extra.push(("Content-Range", &content_range));
    }
    write_head(stream, status, mime, &extra)?;
    if head.method == "HEAD" || length == 0 {
        return Ok(());
    }

    // The bytes, in chunks, so a gigabyte is never in memory at once.
    use std::io::Seek;
    let mut file = std::fs::File::open(&path)?;
    file.seek(std::io::SeekFrom::Start(start))?;
    let mut left = length;
    let mut buf = vec![0u8; CHUNK];
    let mut out = stream;
    while left > 0 {
        let want = left.min(CHUNK as u64) as usize;
        let n = file.read(&mut buf[..want])?;
        if n == 0 {
            break;
        }
        // A reader that hung up mid-file — a scrubbed video — is not an
        // error worth a log line.
        if out.write_all(&buf[..n]).is_err() {
            return Ok(());
        }
        left -= n as u64;
    }
    out.flush()
}

/// The content type and disposition a shelf file is served with. A
/// picture, a video, a sound, a PDF and plain text render inline — that is
/// what the page and a phone need. Anything a browser would *execute* on
/// this origin — HTML, SVG (which carries script), JavaScript, CSS, XML —
/// is a download and an opaque byte stream, because an upload is not code
/// this server vouches for. Pure, for the tests.
pub fn file_headers(rel: &str, name: &str) -> (&'static str, String) {
    let mime = crate::space::mime_for(rel);
    let safe_name = name.replace(['"', '\r', '\n'], "");
    let active = matches!(
        mime,
        "text/html"
            | "image/svg+xml"
            | "text/javascript"
            | "text/css"
            | "application/manifest+json"
    ) || name.to_ascii_lowercase().ends_with(".xhtml")
        || name.to_ascii_lowercase().ends_with(".xml");
    if active {
        (
            "application/octet-stream",
            format!("attachment; filename=\"{safe_name}\""),
        )
    } else {
        (mime, format!("inline; filename=\"{safe_name}\""))
    }
}

/// `bytes=start-end`, `bytes=start-` or `bytes=-suffix`, as an inclusive
/// pair clamped to the file — or `None` when nothing in it can be served.
/// Only the first range of a list is honoured; a browser sends one.
pub fn parse_range(header: &str, total: u64) -> Option<(u64, u64)> {
    let spec = header.trim().strip_prefix("bytes=")?;
    let first = spec.split(',').next()?.trim();
    let (a, b) = first.split_once('-')?;
    let (a, b) = (a.trim(), b.trim());
    if total == 0 {
        return None;
    }
    if a.is_empty() {
        // The last `b` bytes.
        let n: u64 = b.parse().ok()?;
        if n == 0 {
            return None;
        }
        let start = total.saturating_sub(n);
        return Some((start, total - 1));
    }
    let start: u64 = a.parse().ok()?;
    if start >= total {
        return None;
    }
    let end: u64 = if b.is_empty() {
        total - 1
    } else {
        b.parse::<u64>().ok()?.min(total - 1)
    };
    if end < start {
        return None;
    }
    Some((start, end))
}

/* ------------------------------------------------------------- uploads ---- */

/// A file arriving as the request body: streamed into `tmp/`, then handed
/// to the dispatcher as an `item.add` that consumes it. The reply is the
/// same envelope `item.add` gives every client.
fn upload(
    stream: &TcpStream,
    reader: &mut BufReader<TcpStream>,
    site: &Site,
    head: &Head,
    enqueue: &dyn Fn(Value, TcpStream, bool) -> bool,
) -> std::io::Result<()> {
    let refuse = |status: u16, why: String| -> std::io::Result<()> {
        write_json(
            stream,
            status,
            &json!({ "ok": false, "op": "item.add", "error": why }),
        )
    };
    if head.header("content-length").is_none() {
        return refuse(411, "an upload needs a Content-Length".into());
    }
    if head.length == 0 {
        return refuse(400, "the upload is empty".into());
    }
    if head.length > MAX_UPLOAD {
        return refuse(
            413,
            format!("{} bytes is too large (max {MAX_UPLOAD})", head.length),
        );
    }
    let name = upload_name(
        head.query.get("name").map(String::as_str).unwrap_or(""),
        head.header("content-type").unwrap_or(""),
    );
    let tmp = match site.space.tmp_dir() {
        Ok(dir) => dir,
        Err(e) => return refuse(500, e.to_string()),
    };
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let dest = tmp.join(format!(
        "upload-{}-{stamp}-{}",
        std::process::id(),
        crate::space::slug_filename(&name)
    ));

    // Stream the body onto the disk; nothing of it is held in memory.
    let written = (|| -> std::io::Result<u64> {
        let mut file = std::fs::File::create(&dest)?;
        let mut left = head.length;
        let mut buf = vec![0u8; CHUNK];
        while left > 0 {
            let want = left.min(CHUNK as u64) as usize;
            let n = reader.read(&mut buf[..want])?;
            if n == 0 {
                break;
            }
            file.write_all(&buf[..n])?;
            left -= n as u64;
        }
        file.flush()?;
        Ok(head.length - left)
    })();
    match written {
        Ok(n) if n == head.length => {}
        Ok(n) => {
            let _ = std::fs::remove_file(&dest);
            return refuse(
                400,
                format!("the upload stopped after {n} of {} bytes", head.length),
            );
        }
        Err(e) => {
            let _ = std::fs::remove_file(&dest);
            return refuse(500, format!("writing the upload: {e}"));
        }
    }

    let mut request = json!({
        "op": "item.add",
        "agent": head.query.get("agent").cloned().unwrap_or_default(),
        "path": dest.to_string_lossy(),
        "name": name,
        "consume": true,
    });
    for key in ["title", "body", "kind"] {
        if let Some(v) = head.query.get(key).filter(|v| !v.trim().is_empty()) {
            request[key] = json!(v);
        }
    }
    if !enqueue(request, stream.try_clone()?, false) {
        let _ = std::fs::remove_file(&dest);
        return refuse(503, "the backend is gone".into());
    }
    Ok(())
}

/// What an upload is called on the shelf: the name the client gave, with
/// an extension from the content type when the name has none — a camera
/// roll hands a browser `image/jpeg` blobs called `image`.
pub fn upload_name(name: &str, content_type: &str) -> String {
    let name = name.trim();
    let name = if name.is_empty() { "upload" } else { name };
    let has_ext = name
        .rsplit_once('.')
        .is_some_and(|(base, ext)| !base.is_empty() && !ext.is_empty() && ext.len() <= 5);
    if has_ext {
        return name.to_string();
    }
    let mime = content_type
        .split(';')
        .next()
        .unwrap_or("")
        .trim()
        .to_ascii_lowercase();
    let ext = match mime.as_str() {
        "image/jpeg" => "jpg",
        "image/png" => "png",
        "image/gif" => "gif",
        "image/webp" => "webp",
        "image/heic" => "heic",
        "video/mp4" => "mp4",
        "video/quicktime" => "mov",
        "video/webm" => "webm",
        "video/x-m4v" => "m4v",
        "text/markdown" => "md",
        "text/plain" => "txt",
        "application/json" => "json",
        "application/pdf" => "pdf",
        _ => return name.to_string(),
    };
    format!("{name}.{ext}")
}

/* --------------------------------------------------------- the answer ---- */

/// Run one request and write its reply on `stream`, as one response or as
/// an event stream. Returns the reply, so the caller can see a `daemon.stop`
/// go past.
pub(crate) fn answer(
    backend: &Backend,
    request: &Value,
    mut stream: TcpStream,
    sse: bool,
) -> Value {
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

fn read_head(reader: &mut BufReader<TcpStream>) -> anyhow::Result<Head> {
    let mut line = String::new();
    if reader.read_line(&mut line)? == 0 {
        anyhow::bail!("empty request");
    }
    let mut parts = line.split_whitespace();
    let method = parts.next().unwrap_or_default().to_string();
    let target = parts.next().unwrap_or_default().to_string();
    let (path, query) = split_query(&target);

    let mut headers = Vec::new();
    let mut length = 0u64;
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
            let (name, value) = (name.trim().to_string(), value.trim().to_string());
            if name.eq_ignore_ascii_case("content-length") {
                length = value.parse().unwrap_or(0);
            }
            headers.push((name, value));
        }
    }
    Ok(Head {
        method,
        path,
        query,
        headers,
        length,
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
        206 => "Partial Content",
        304 => "Not Modified",
        400 => "Bad Request",
        404 => "Not Found",
        411 => "Length Required",
        413 => "Payload Too Large",
        416 => "Range Not Satisfiable",
        500 => "Internal Server Error",
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
    head.push_str("Access-Control-Allow-Headers: Content-Type, Range\r\n");
    head.push_str("Access-Control-Allow-Methods: GET, HEAD, POST, PUT, OPTIONS\r\n");
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
         Cache-Control: no-store\r\nConnection: close\r\n\r\n",
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

    #[test]
    fn only_the_shelves_are_served() {
        assert_eq!(
            shelf_path("/file/agents/abc/photos/cat.png").unwrap(),
            "agents/abc/photos/cat.png"
        );
        assert_eq!(
            shelf_path("/file/global/videos/a%20b.mov").unwrap(),
            "global/videos/a b.mov"
        );
        assert!(shelf_path("/file/robots.db").is_err());
        assert!(shelf_path("/file/agents/abc/agent.db").is_err());
        assert!(shelf_path("/file/agents/abc/agent.db-wal").is_err());
        assert!(shelf_path("/file/tmp/upload-1").is_err());
        assert!(shelf_path("/file/agents/../robots.db").is_err());
        assert!(shelf_path("/file/agents/%2e%2e/robots.db").is_err());
        assert!(shelf_path("/file/agents/abc/photos/").is_err());
        assert!(shelf_path("/nowhere").is_err());
        // The markdown page and the mirrors are files a person may read.
        assert!(shelf_path("/file/agents/abc/agent.md").is_ok());
    }

    #[test]
    fn what_a_browser_would_run_is_a_download_and_the_rest_renders() {
        let (mime, disp) = file_headers("agents/a/photos/cat.png", "cat.png");
        assert_eq!(mime, "image/png");
        assert!(disp.starts_with("inline;"));
        let (mime, disp) = file_headers("agents/a/videos/x.mov", "x.mov");
        assert_eq!(mime, "video/quicktime");
        assert!(disp.starts_with("inline;"));
        for name in ["page.html", "logo.svg", "run.js", "look.css", "x.xhtml"] {
            let (mime, disp) = file_headers(&format!("global/files/{name}"), name);
            assert_eq!(mime, "application/octet-stream", "{name}");
            assert!(disp.starts_with("attachment;"), "{name}");
        }
        // A name cannot break out of the header it is quoted in.
        let (_, disp) = file_headers("global/files/a.png", "a\"\r\nX: y.png");
        assert_eq!(disp, "inline; filename=\"aX: y.png\"");
    }

    #[test]
    fn byte_ranges_are_read_the_way_a_browser_writes_them() {
        assert_eq!(parse_range("bytes=0-1", 100), Some((0, 1)));
        assert_eq!(parse_range("bytes=10-", 100), Some((10, 99)));
        assert_eq!(parse_range("bytes=-10", 100), Some((90, 99)));
        assert_eq!(parse_range("bytes=0-500", 100), Some((0, 99)));
        assert_eq!(parse_range("bytes=0-1, 5-6", 100), Some((0, 1)));
        assert_eq!(parse_range("bytes=100-", 100), None);
        assert_eq!(parse_range("bytes=5-2", 100), None);
        assert_eq!(parse_range("bytes=-0", 100), None);
        assert_eq!(parse_range("bytes=0-", 0), None);
        assert_eq!(parse_range("items=0-1", 100), None);
    }

    #[test]
    fn an_upload_keeps_its_name_and_gains_an_extension_when_it_has_none() {
        assert_eq!(
            upload_name("IMG_0042.MOV", "video/quicktime"),
            "IMG_0042.MOV"
        );
        assert_eq!(upload_name("image", "image/jpeg"), "image.jpg");
        assert_eq!(upload_name("", "video/mp4"), "upload.mp4");
        assert_eq!(upload_name("blob", "application/octet-stream"), "blob");
        assert_eq!(
            upload_name("notes", "text/markdown; charset=utf-8"),
            "notes.md"
        );
    }
}
