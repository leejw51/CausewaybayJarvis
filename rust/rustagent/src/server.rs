//! The server: one port, three ways to speak to it, one backend behind them.
//!
//! ```text
//! ws://127.0.0.1:<port>/ws          WebSocket — the clients: LÖVE, rustcli, a browser
//! http://127.0.0.1:<port>/v1/<op>   REST, and /v1/chat/stream as server-sent events
//! {"op":"health"}\n                 line JSON over plain TCP, for `nc` and the old tests
//! ```
//!
//! Every client today loads nothing: the model lives here, once, and a
//! client is a socket. That is the whole reason this file exists — the
//! LÖVE window can be closed and reopened in a second, a fault in the
//! engine takes down this process and not the screen, and a second client
//! (a phone, a browser) shares the same loaded weights and the same archive.
//!
//! # Which protocol
//!
//! A connection is sniffed, not configured. The first bytes are peeked
//! without being consumed: a `{` is a line-JSON client; `GET /ws` is a
//! WebSocket upgrade; anything else is HTTP. One port, so a client needs one
//! number, and the port file in the space keeps saying where it is.
//!
//! # The WebSocket protocol
//!
//! Text frames carrying JSON, the same objects the other two transports
//! carry, plus an `id` the client chooses and the server echoes:
//!
//! ```text
//! → {"id":7,"op":"chat","agent":"food","text":"what should I cook?"}
//! ← {"id":7,"chunk":"prefill","done":120,"total":480}
//! ← {"id":7,"chunk":"token","text":"Pork "}
//! ← {"id":7,"chunk":"tool","text":"searched the archive for \"pork\""}
//! ← {"id":7,"ok":true,"op":"chat","data":{ …the whole turn… }}
//! → {"id":7,"op":"stop"}                     cancel that turn; without an id, every turn
//! ```
//!
//! `chat` and `brain.chat` always stream over a WebSocket; a client that
//! reads only the final frame is a correct client, and the final frame is
//! exactly what the REST route would have returned. Every other op answers
//! with one frame. A connection can have several turns in flight; they run
//! in arrival order, because there is one GPU.
//!
//! # Shape
//!
//! One thread per connection, which owns its socket outright; one
//! dispatcher thread, which owns the [`Backend`] and answers in arrival
//! order. A WebSocket connection thread never hands its socket away: the
//! dispatcher sends it frames over a channel, and it writes them between
//! reads. So there is no lock around a socket, and a client that hangs up
//! is a closed channel, which is what stops the generation.

use std::collections::HashMap;
use std::io::{BufRead, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::time::Duration;

use serde_json::{json, Value};
use tungstenite::protocol::Message;

use crate::harness::Chunk;
use crate::http;
use crate::proto::Backend;

/// The path a WebSocket client upgrades on.
pub const WS_PATH: &str = "/ws";

/// One unit of work for the dispatcher, with the way to answer it.
enum Job {
    /// Line JSON over plain TCP: the reply is one line on the same socket.
    Line {
        line: String,
        conn: Arc<Mutex<TcpStream>>,
    },
    /// HTTP: the reply is a response, or an event stream, on the socket.
    Http {
        request: Value,
        stream: TcpStream,
        sse: bool,
    },
    /// WebSocket: frames go down a channel to the thread that owns the socket.
    Ws {
        request: Value,
        id: Option<Value>,
        out: mpsc::Sender<Frame>,
        cancel: Arc<AtomicBool>,
        turns: Turns,
    },
}

/// One outgoing WebSocket frame, and — for the reply to a `daemon.stop` —
/// a way for the socket's thread to say it has gone out, so the process
/// does not exit with the reply still in a channel.
struct Frame {
    text: String,
    sent: Option<mpsc::SyncSender<()>>,
}

impl From<String> for Frame {
    fn from(text: String) -> Self {
        Frame { text, sent: None }
    }
}

/// The turns a WebSocket connection has in flight, by their `id` as text,
/// so a `stop` can find the one it means.
type Turns = Arc<Mutex<HashMap<String, Arc<AtomicBool>>>>;

/// The daemon on a space: bind, write the port and pid files, serve until
/// `daemon.stop`. This is `agentd listen`.
///
/// One daemon per space. A second `listen` on a space whose daemon is
/// still answering fails, rather than quietly taking another port and
/// overwriting the file the first one's clients are reading — in an mlx
/// build that would also be a second copy of the model on the GPU.
pub fn listen(backend: Backend, port: u16) -> std::io::Result<()> {
    let root = backend.store.space.root().to_path_buf();
    let port_file = root.join("agentd.port");
    let pid_file = root.join("agentd.pid");

    if let Some(taken) = already_listening(&port_file) {
        let pid = std::fs::read_to_string(&pid_file)
            .ok()
            .map(|p| format!(" (pid {})", p.trim()))
            .unwrap_or_default();
        return Err(std::io::Error::new(
            std::io::ErrorKind::AddrInUse,
            format!(
                "another agentd is already listening on 127.0.0.1:{taken}{pid} for {} — stop it first (make stop)",
                root.display()
            ),
        ));
    }

    let listener = bind(&format!("127.0.0.1:{port}"))?;
    let actual = listener.local_addr()?.port();
    std::fs::write(&port_file, format!("{actual}\n"))?;
    std::fs::write(&pid_file, format!("{}\n", std::process::id()))?;
    println!(
        "agentd listening on 127.0.0.1:{actual}  ({})  ws://127.0.0.1:{actual}{WS_PATH}  http://127.0.0.1:{actual}/",
        port_file.display()
    );

    let cleanup = move || {
        let _ = std::fs::remove_file(&port_file);
        let _ = std::fs::remove_file(&pid_file);
    };
    run(backend, listener, Box::new(cleanup))
}

/// The same server on an explicit address, with no port file: what
/// `rustcli backend` runs.
pub fn serve(backend: Backend, addr: &str) -> std::io::Result<()> {
    let listener = bind(addr)?;
    let actual = listener.local_addr()?;
    println!("agent server on http://{actual}/  ws://{actual}{WS_PATH}");
    if !actual.ip().is_loopback() {
        println!(
            "warning: {} is not loopback, and this server has no authentication — \
             anything that can reach it can read the archive and spend the GPU",
            actual.ip()
        );
    }
    run(backend, listener, Box::new(|| {}))
}

fn bind(addr: &str) -> std::io::Result<TcpListener> {
    TcpListener::bind(addr).map_err(|e| {
        if e.kind() == std::io::ErrorKind::AddrInUse {
            std::io::Error::new(
                e.kind(),
                format!("{addr} is already in use — is another agentd running? (make stop)"),
            )
        } else {
            std::io::Error::new(e.kind(), format!("cannot bind {addr}: {e}"))
        }
    })
}

/// The accept loop and the dispatcher. Returns only if the listener fails;
/// `daemon.stop` exits the process from the dispatcher after its reply is
/// on the wire.
fn run(
    backend: Backend,
    listener: TcpListener,
    cleanup: Box<dyn FnOnce() + Send>,
) -> std::io::Result<()> {
    let (tx, rx) = mpsc::channel::<Job>();

    std::thread::spawn(move || {
        let mut cleanup = Some(cleanup);
        for job in rx {
            if dispatch(&backend, job) {
                if let Some(cleanup) = cleanup.take() {
                    cleanup();
                }
                std::process::exit(0);
            }
        }
    });

    for stream in listener.incoming() {
        let Ok(stream) = stream else { continue };
        let tx = tx.clone();
        std::thread::spawn(move || {
            if let Err(e) = connection(stream, tx) {
                // A client that hung up mid-request is not an event.
                if e.kind() != std::io::ErrorKind::UnexpectedEof {
                    eprintln!("server: {e}");
                }
            }
        });
    }
    Ok(())
}

/// Which protocol a fresh connection speaks, from its first bytes.
#[derive(Debug, PartialEq, Eq)]
pub enum Wire {
    Line,
    WebSocket,
    Http,
}

/// Sniff the wire from what a client sent first. Pure, for the tests: a
/// `{` (after any whitespace) is a line-JSON client, a request line for
/// [`WS_PATH`] is an upgrade, and anything else is HTTP.
pub fn sniff(head: &[u8]) -> Wire {
    let trimmed = head
        .iter()
        .position(|b| !b.is_ascii_whitespace())
        .map(|i| &head[i..])
        .unwrap_or(&[]);
    if trimmed.first() == Some(&b'{') {
        return Wire::Line;
    }
    let line = trimmed
        .split(|b| *b == b'\n')
        .next()
        .map(|l| String::from_utf8_lossy(l).trim().to_string())
        .unwrap_or_default();
    let mut parts = line.split_whitespace();
    if parts.next() == Some("GET") {
        if let Some(target) = parts.next() {
            let path = target.split('?').next().unwrap_or(target);
            if path == WS_PATH {
                return Wire::WebSocket;
            }
        }
    }
    Wire::Http
}

fn connection(stream: TcpStream, tx: mpsc::Sender<Job>) -> std::io::Result<()> {
    // Peek, never read: whichever handler takes the socket wants the bytes
    // still in it. A client that connected and said nothing yet is given a
    // moment to say something before being taken for HTTP.
    let mut head = [0u8; 512];
    stream.set_read_timeout(Some(Duration::from_secs(5)))?;
    let n = match stream.peek(&mut head) {
        Ok(n) => n,
        Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => 0,
        Err(e) => return Err(e),
    };
    stream.set_read_timeout(None)?;
    match sniff(&head[..n]) {
        Wire::Line => line_session(stream, tx),
        Wire::WebSocket => ws_session(stream, tx),
        Wire::Http => http::handle(stream, &|request, stream, sse| {
            tx.send(Job::Http {
                request,
                stream,
                sse,
            })
            .is_ok()
        }),
    }
}

/* ----------------------------------------------------------- line JSON ---- */

fn line_session(stream: TcpStream, tx: mpsc::Sender<Job>) -> std::io::Result<()> {
    let reader = stream.try_clone()?;
    let conn = Arc::new(Mutex::new(stream));
    for line in std::io::BufReader::new(reader).lines() {
        let Ok(line) = line else { break };
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        if trimmed == "quit" || trimmed == "exit" {
            break;
        }
        if tx
            .send(Job::Line {
                line,
                conn: conn.clone(),
            })
            .is_err()
        {
            break;
        }
    }
    Ok(())
}

/* ----------------------------------------------------------- WebSocket ---- */

/// How often the connection thread comes up from a blocking read to write
/// what the dispatcher has queued. The bound on how late a token can be.
const WS_TICK: Duration = Duration::from_millis(15);

fn ws_session(stream: TcpStream, tx: mpsc::Sender<Job>) -> std::io::Result<()> {
    let mut ws = match tungstenite::accept(stream) {
        Ok(ws) => ws,
        Err(e) => {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                format!("websocket handshake: {e}"),
            ))
        }
    };
    let sock = ws.get_ref();
    sock.set_nodelay(true)?;
    // The read is the tick: it comes back on a timeout so the frames the
    // dispatcher has queued can go out, then goes back to reading.
    sock.set_read_timeout(Some(WS_TICK))?;

    let (out, frames) = mpsc::channel::<Frame>();
    let turns: Turns = Arc::new(Mutex::new(HashMap::new()));

    loop {
        while let Ok(frame) = frames.try_recv() {
            let written = ws.send(Message::Text(frame.text.into())).is_ok();
            if let Some(sent) = frame.sent {
                let _ = sent.send(());
            }
            if !written {
                return Ok(());
            }
        }
        match ws.read() {
            Ok(Message::Text(text)) => {
                if let Some(frame) = ws_request(text.as_str(), &tx, &out, &turns) {
                    if ws.send(Message::Text(frame.to_string().into())).is_err() {
                        return Ok(());
                    }
                }
            }
            Ok(Message::Binary(bytes)) => {
                let text = String::from_utf8_lossy(&bytes).into_owned();
                if let Some(frame) = ws_request(&text, &tx, &out, &turns) {
                    if ws.send(Message::Text(frame.to_string().into())).is_err() {
                        return Ok(());
                    }
                }
            }
            Ok(Message::Close(_)) => {
                // Whatever is in flight for this socket stops: nobody is
                // listening for it any more.
                cancel_all(&turns);
                let _ = ws.close(None);
                let _ = ws.flush();
                return Ok(());
            }
            // Pings are answered by the library on the next read or write.
            Ok(_) => {}
            Err(tungstenite::Error::Io(e))
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) => {}
            Err(tungstenite::Error::ConnectionClosed) | Err(tungstenite::Error::AlreadyClosed) => {
                cancel_all(&turns);
                return Ok(());
            }
            // A client that vanished without a close frame — a window that
            // quit, a process that died — is not an event worth a log line.
            Err(tungstenite::Error::Protocol(
                tungstenite::error::ProtocolError::ResetWithoutClosingHandshake,
            )) => {
                cancel_all(&turns);
                return Ok(());
            }
            Err(e) => {
                cancel_all(&turns);
                return Err(std::io::Error::other(e.to_string()));
            }
        }
    }
}

fn cancel_all(turns: &Turns) {
    if let Ok(map) = turns.lock() {
        for flag in map.values() {
            flag.store(true, Ordering::Relaxed);
        }
    }
}

/// One frame from a WebSocket client. Returns a frame to answer at once
/// (a `stop`, or a refusal); anything real goes to the dispatcher.
fn ws_request(
    text: &str,
    tx: &mpsc::Sender<Job>,
    out: &mpsc::Sender<Frame>,
    turns: &Turns,
) -> Option<Value> {
    let mut request: Value = match serde_json::from_str(text) {
        Ok(v) => v,
        Err(e) => return Some(json!({ "ok": false, "error": format!("bad json: {e}") })),
    };
    // Over this socket `id` is the frame's number and nothing else. It is
    // taken off the request before the dispatcher sees it, so an item op
    // that forgot its `item` is refused rather than answered — or worse,
    // deleted — under whatever row happens to share the frame counter.
    let id = request
        .as_object_mut()
        .and_then(|o| o.remove("id"))
        .filter(|v| !v.is_null());
    let op = request.get("op").and_then(Value::as_str).unwrap_or("");

    if op == "stop" {
        let stopped = stop(turns, id.as_ref());
        let mut frame = json!({ "ok": true, "op": "stop", "data": { "stopped": stopped } });
        if let Some(id) = id {
            frame["id"] = id;
        }
        return Some(frame);
    }

    let cancel = Arc::new(AtomicBool::new(false));
    if let Some(id) = &id {
        if let Ok(mut map) = turns.lock() {
            map.insert(id.to_string(), cancel.clone());
        }
    }
    if tx
        .send(Job::Ws {
            request,
            id: id.clone(),
            out: out.clone(),
            cancel,
            turns: turns.clone(),
        })
        .is_err()
    {
        let mut frame = json!({ "ok": false, "error": "the backend is gone" });
        if let Some(id) = id {
            frame["id"] = id;
        }
        return Some(frame);
    }
    None
}

/// Cancel one turn by id, or every turn on the connection. Returns how many
/// were told to stop. Pure over the map, for the tests.
pub(crate) fn stop(turns: &Turns, id: Option<&Value>) -> usize {
    let Ok(map) = turns.lock() else { return 0 };
    match id {
        Some(id) => match map.get(&id.to_string()) {
            Some(flag) => {
                flag.store(true, Ordering::Relaxed);
                1
            }
            None => 0,
        },
        None => {
            for flag in map.values() {
                flag.store(true, Ordering::Relaxed);
            }
            map.len()
        }
    }
}

/* ---------------------------------------------------------- dispatcher ---- */

/// Run one job and answer it. Returns true when the job was `daemon.stop`
/// and the reply is on its way, so the caller can shut down.
fn dispatch(backend: &Backend, job: Job) -> bool {
    match job {
        Job::Line { line, conn } => {
            let reply = match serde_json::from_str::<Value>(line.trim()) {
                Ok(req) => backend.handle(&req),
                Err(e) => json!({ "ok": false, "error": format!("bad json: {e}") }),
            };
            let stopping = is_stop(&reply);
            if let Ok(mut stream) = conn.lock() {
                let _ = writeln!(stream, "{reply}");
                let _ = stream.flush();
            }
            stopping
        }
        Job::Http {
            request,
            stream,
            sse,
        } => {
            let reply = http::answer(backend, &request, stream, sse);
            is_stop(&reply)
        }
        Job::Ws {
            request,
            id,
            out,
            cancel,
            turns,
        } => {
            let reply = ws_answer(backend, &request, id.as_ref(), &out, &cancel);
            if let Some(id) = &id {
                if let Ok(mut map) = turns.lock() {
                    map.remove(&id.to_string());
                }
            }
            let stopping = is_stop(&reply);
            if stopping {
                // The socket's thread writes the frame; wait for it to say
                // so before the process goes, or the client that asked for
                // the shutdown is the one client that never hears about it.
                let (sent, gone) = mpsc::sync_channel::<()>(1);
                let _ = out.send(Frame {
                    text: reply.to_string(),
                    sent: Some(sent),
                });
                let _ = gone.recv_timeout(Duration::from_secs(2));
            } else {
                let _ = out.send(reply.to_string().into());
            }
            stopping
        }
    }
}

fn is_stop(reply: &Value) -> bool {
    reply["ok"] == json!(true) && reply["op"] == json!("daemon.stop")
}

/// One request, answered in this process: the dispatch every way in shares.
///
/// `chat` and `brain.chat` are run as streaming turns, so `sink` sees each
/// piece as the model writes it and can return `false` to stop the turn early;
/// every other op is one call into [`Backend::handle`] and never touches it.
/// What comes back is the protocol envelope, whatever carries it.
///
/// Public because the daemon is one way in and not the only one: the C ABI
/// calls this directly, in the caller's own process, with no socket between.
/// Both therefore answer the same op the same way — a thing that stops being
/// true the moment there are two dispatches to keep in step.
pub fn answer(backend: &Backend, request: &Value, sink: &mut crate::harness::Sink<'_>) -> Value {
    let op = request.get("op").and_then(Value::as_str).unwrap_or("");
    match op {
        "chat" => {
            let who = request.get("agent").and_then(Value::as_str);
            let text = request.get("text").and_then(Value::as_str).unwrap_or("");
            http::envelope(
                "chat",
                backend
                    .turn_stream(who, text, &mut *sink)
                    .and_then(|t| Ok(serde_json::to_value(t)?)),
            )
        }
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
                    http::envelope(
                        "brain.chat",
                        backend.brain_chat_stream(&messages, &tools, &mut *sink),
                    )
                }
                Err(e) => {
                    json!({ "ok": false, "op": "brain.chat", "error": format!("bad messages: {e}") })
                }
            }
        }
        _ => backend.handle(request),
    }
}

/// One WebSocket request, streamed when it can be. The chunks go down the
/// connection's channel as the model writes; the reply is returned for the
/// caller to send last.
fn ws_answer(
    backend: &Backend,
    request: &Value,
    id: Option<&Value>,
    out: &mpsc::Sender<Frame>,
    cancel: &AtomicBool,
) -> Value {
    let mut dead = false;
    let mut sink = |chunk: Chunk<'_>| {
        if dead || cancel.load(Ordering::Relaxed) {
            return false;
        }
        let mut frame = match chunk {
            Chunk::Token(t) => json!({ "chunk": "token", "text": t }),
            Chunk::Reasoning(t) => json!({ "chunk": "reasoning", "text": t }),
            Chunk::Tool(t) => json!({ "chunk": "tool", "text": t }),
            Chunk::Prefill { done, total } => {
                json!({ "chunk": "prefill", "done": done, "total": total })
            }
        };
        if let Some(id) = id {
            frame["id"] = id.clone();
        }
        if out.send(frame.to_string().into()).is_err() {
            dead = true;
            return false;
        }
        true
    };

    let mut reply = answer(backend, request, &mut sink);
    if let Some(id) = id {
        reply["id"] = id.clone();
    }
    reply
}

/// The port a live daemon of this space answers on, if the port file names
/// one. A stale file — a daemon that died without cleaning up — names a port
/// nobody accepts on, and that is not a daemon.
pub fn already_listening(port_file: &std::path::Path) -> Option<u16> {
    use std::net::SocketAddr;
    let port: u16 = std::fs::read_to_string(port_file)
        .ok()?
        .trim()
        .parse()
        .ok()?;
    let addr = SocketAddr::from(([127, 0, 0, 1], port));
    TcpStream::connect_timeout(&addr, Duration::from_secs(1))
        .ok()
        .map(|_| port)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_brace_is_a_line_client() {
        assert_eq!(sniff(b"{\"op\":\"health\"}\n"), Wire::Line);
        assert_eq!(sniff(b"  \n {\"op\""), Wire::Line);
    }

    #[test]
    fn an_upgrade_on_the_ws_path_is_a_websocket() {
        assert_eq!(
            sniff(b"GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n"),
            Wire::WebSocket
        );
        assert_eq!(sniff(b"GET /ws?client=love HTTP/1.1\r\n"), Wire::WebSocket);
    }

    #[test]
    fn everything_else_is_http() {
        assert_eq!(sniff(b"GET /health HTTP/1.1\r\n"), Wire::Http);
        assert_eq!(sniff(b"POST /v1/chat HTTP/1.1\r\n"), Wire::Http);
        assert_eq!(sniff(b"GET /wsx HTTP/1.1\r\n"), Wire::Http);
        assert_eq!(sniff(b""), Wire::Http);
    }

    #[test]
    fn stop_finds_a_turn_by_id_or_takes_them_all() {
        let turns: Turns = Arc::new(Mutex::new(HashMap::new()));
        let a = Arc::new(AtomicBool::new(false));
        let b = Arc::new(AtomicBool::new(false));
        turns.lock().unwrap().insert("1".into(), a.clone());
        turns.lock().unwrap().insert("\"two\"".into(), b.clone());
        assert_eq!(stop(&turns, Some(&json!(9))), 0);
        assert_eq!(stop(&turns, Some(&json!(1))), 1);
        assert!(a.load(Ordering::Relaxed));
        assert!(!b.load(Ordering::Relaxed));
        assert_eq!(stop(&turns, None), 2);
        assert!(b.load(Ordering::Relaxed));
    }
}
