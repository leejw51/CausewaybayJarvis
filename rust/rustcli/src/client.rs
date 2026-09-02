//! The WebSocket client: how this command line reaches the backend.
//!
//! `rustcli` loads no model of its own for a conversation. The model lives
//! in `agentd`, the server every client shares, and this module finds it
//! the way the LÖVE client does — by the `agentd.port` file in the space —
//! and starts one when the file leads nowhere. What goes over the socket is
//! the protocol `rustagent::server` documents: a JSON request with an `id`,
//! `chunk` frames while a turn is written, then the reply under that id.

use std::io::{ErrorKind, Write};
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Context, Result};
use serde_json::{json, Value};
use tungstenite::protocol::Message;
use tungstenite::stream::MaybeTlsStream;
use tungstenite::WebSocket;

use crate::ui::{StatusLine, Style};

/// How long to wait for a server that was just started to write its port.
const START_TIMEOUT: Duration = Duration::from_secs(20);

/// How often a streaming read comes up for air to check the interrupt flag.
const TICK: Duration = Duration::from_millis(50);

pub struct Client {
    ws: WebSocket<MaybeTlsStream<TcpStream>>,
    next: u64,
    /// Where it connected, for a status line.
    pub addr: String,
}

/// The space: `$JARVIS_HOME`, or `~/.causewaybayjarvis`, unless the caller
/// named one.
pub fn space_root(home: Option<&Path>) -> PathBuf {
    if let Some(home) = home {
        return home.to_path_buf();
    }
    if let Ok(env) = std::env::var("JARVIS_HOME") {
        if !env.trim().is_empty() {
            return PathBuf::from(env.trim_end_matches('/'));
        }
    }
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
    PathBuf::from(home).join(".causewaybayjarvis")
}

/// The port a server of this space answers on, if the port file names one
/// that accepts a connection.
pub fn live_port(root: &Path) -> Option<u16> {
    let port: u16 = std::fs::read_to_string(root.join("agentd.port"))
        .ok()?
        .trim()
        .parse()
        .ok()?;
    let addr = std::net::SocketAddr::from(([127, 0, 0, 1], port));
    TcpStream::connect_timeout(&addr, Duration::from_secs(1))
        .ok()
        .map(|_| port)
}

/// Where the server binary is: `$JARVIS_AGENTD`, then beside this binary
/// (`agentd-mlx` first, the engine-carrying one), then on `PATH`.
pub fn find_agentd() -> Option<PathBuf> {
    if let Ok(explicit) = std::env::var("JARVIS_AGENTD") {
        let path = PathBuf::from(explicit);
        return path.is_file().then_some(path);
    }
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            // Beside this binary first; then the release build, so a debug
            // `rustcli` does not start a lean debug server on a machine
            // that has the engine-carrying one built.
            let dirs = [dir.to_path_buf(), dir.join("../release")];
            for dir in dirs {
                for name in ["agentd-mlx", "agentd"] {
                    let candidate = dir.join(name);
                    if candidate.is_file() {
                        return Some(candidate);
                    }
                }
            }
        }
    }
    let path = std::env::var("PATH").unwrap_or_default();
    for dir in path.split(':') {
        let candidate = Path::new(dir).join("agentd");
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}

/// Start `agentd listen` on the space, detached, logging to `agentd.log`
/// there. It outlives this process on purpose: it is the server, and the
/// next client — this one again, or the LÖVE window — finds it by the
/// port file. `make stop` takes it down.
fn spawn_server(root: &Path) -> Result<()> {
    let bin = find_agentd().ok_or_else(|| {
        anyhow!(
            "no server is running for {} and no `agentd` was found to start one — \
             run `make agentd` (or `make start`), or set JARVIS_AGENTD",
            root.display()
        )
    })?;
    std::fs::create_dir_all(root)?;
    let _ = std::fs::remove_file(root.join("agentd.port"));
    let log = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(root.join("agentd.log"))?;
    std::process::Command::new(&bin)
        .arg("listen")
        .env("JARVIS_HOME", root)
        .stdin(std::process::Stdio::null())
        .stdout(log.try_clone()?)
        .stderr(log)
        .spawn()
        .with_context(|| format!("starting {}", bin.display()))?;
    Ok(())
}

impl Client {
    /// Connect to the space's server, starting one if there is none.
    pub fn connect(home: Option<&Path>, style: Style) -> Result<Self> {
        let root = space_root(home);
        let port = match live_port(&root) {
            Some(port) => port,
            None => {
                let mut line = StatusLine::new(style);
                line.force(&format!(
                    "  {} starting the server for {}…",
                    style.dim("…"),
                    root.display()
                ));
                spawn_server(&root)?;
                let deadline = Instant::now() + START_TIMEOUT;
                let port = loop {
                    if let Some(port) = live_port(&root) {
                        break port;
                    }
                    if Instant::now() > deadline {
                        line.clear();
                        bail!(
                            "the server did not come up — see {}",
                            root.join("agentd.log").display()
                        );
                    }
                    std::thread::sleep(Duration::from_millis(100));
                };
                line.clear();
                port
            }
        };
        Self::connect_port(port)
    }

    /// Connect to a known port.
    pub fn connect_port(port: u16) -> Result<Self> {
        let addr = format!("127.0.0.1:{port}");
        let (ws, response) = tungstenite::connect(format!("ws://{addr}/ws"))
            .with_context(|| format!("connecting to the server at ws://{addr}/ws"))?;
        if response.status().as_u16() != 101 {
            bail!(
                "the server at {addr} refused the WebSocket: {}",
                response.status()
            );
        }
        if let MaybeTlsStream::Plain(stream) = ws.get_ref() {
            let _ = stream.set_nodelay(true);
        }
        Ok(Self { ws, next: 0, addr })
    }

    fn send(&mut self, mut request: Value) -> Result<u64> {
        self.next += 1;
        let id = self.next;
        request["id"] = json!(id);
        self.ws
            .send(Message::Text(request.to_string().into()))
            .context("sending to the server")?;
        Ok(id)
    }

    fn set_read_timeout(&self, timeout: Option<Duration>) {
        if let MaybeTlsStream::Plain(stream) = self.ws.get_ref() {
            let _ = stream.set_read_timeout(timeout);
        }
    }

    /// One request, one reply: the whole envelope, `ok` and all.
    pub fn call(&mut self, request: Value) -> Result<Value> {
        self.stream(request, None, &mut |_| {})
    }

    /// One request, with every `chunk` frame handed to `on_chunk` as it
    /// arrives, then the reply. `cancel` is polled while waiting; raised, it
    /// sends a `stop` for this request and the turn comes back interrupted.
    pub fn stream(
        &mut self,
        request: Value,
        cancel: Option<&AtomicBool>,
        on_chunk: &mut dyn FnMut(&Value),
    ) -> Result<Value> {
        let id = self.send(request)?;
        self.set_read_timeout(Some(TICK));
        let mut stopped = false;
        let result = loop {
            match self.ws.read() {
                Ok(Message::Text(text)) => {
                    let frame: Value = match serde_json::from_str(text.as_str()) {
                        Ok(v) => v,
                        Err(_) => continue,
                    };
                    if frame["id"] != json!(id) {
                        // A stop's own reply, or a straggler: not this turn.
                        continue;
                    }
                    if frame.get("chunk").is_some() {
                        on_chunk(&frame);
                    } else {
                        break Ok(frame);
                    }
                }
                Ok(Message::Close(_)) => break Err(anyhow!("the server closed the connection")),
                Ok(_) => {}
                Err(tungstenite::Error::Io(e))
                    if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) =>
                {
                    if !stopped && cancel.is_some_and(|c| c.load(Ordering::Relaxed)) {
                        stopped = true;
                        let _ = self.ws.send(Message::Text(
                            json!({ "op": "stop", "id": id }).to_string().into(),
                        ));
                    }
                }
                Err(e) => break Err(anyhow!("reading from the server: {e}")),
            }
        };
        self.set_read_timeout(None);
        result
    }

    /// `data` out of a reply, or its `error` as the error.
    pub fn data(reply: Value) -> Result<Value> {
        if reply["ok"] == json!(true) {
            Ok(reply["data"].clone())
        } else {
            Err(anyhow!(
                "{}",
                reply["error"].as_str().unwrap_or("the server refused")
            ))
        }
    }

    /// Say goodbye. The server stays up for the next client.
    pub fn close(mut self) {
        let _ = self.ws.close(None);
        let _ = self.ws.flush();
        let _ = std::io::stdout().flush();
    }
}
