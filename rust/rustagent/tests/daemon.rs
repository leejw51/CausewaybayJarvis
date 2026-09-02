//! The daemon, over a real socket.
//!
//! Everything else tests the `Backend` in-process; this suite runs the actual
//! `agentd listen` binary against a scratch space, finds it the way a client
//! does — by reading `agentd.port` — and talks to it over TCP. It is the only
//! place the accept loop, the dispatcher thread, the port file and the
//! shutdown handshake are exercised at all.

use std::io::{BufRead, BufReader, Write};
use std::net::TcpStream;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use serde_json::{json, Value};

struct Daemon {
    child: Child,
    dir: tempfile::TempDir,
}

/// `agentd listen` on a space, not yet spawned.
fn listen(space: &std::path::Path, args: &[&str]) -> Command {
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_agentd"));
    cmd.arg("listen")
        .args(args)
        .env("JARVIS_HOME", space)
        // A blank key shuts the cloud, JARVIS_NO_MLX shuts the engine and
        // ONDEVICE_ENGINE=off keeps a daemon that happens to be running on
        // this machine out of it — so the suite is deterministic on a
        // laptop with the weights and in CI with nothing.
        .env("OLLAMA_API_KEY", "")
        .env("OLLAMA_HOST", "https://ollama.com")
        .env("JARVIS_NO_MLX", "1")
        .env("ONDEVICE_ENGINE", "off");
    cmd
}

impl Daemon {
    fn start() -> Self {
        Self::start_with(&[])
    }

    fn start_with(args: &[&str]) -> Self {
        let dir = tempfile::tempdir().unwrap();
        let child = listen(dir.path(), args)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawning agentd");
        Self { child, dir }
    }

    /// Wait for the port file, the way the LOVE client does.
    fn port(&self) -> u16 {
        let path = self.dir.path().join("agentd.port");
        let deadline = Instant::now() + Duration::from_secs(20);
        loop {
            if let Ok(text) = std::fs::read_to_string(&path) {
                if let Ok(port) = text.trim().parse() {
                    return port;
                }
            }
            assert!(Instant::now() < deadline, "agentd never wrote {path:?}");
            std::thread::sleep(Duration::from_millis(25));
        }
    }

    fn connect(&self) -> Conn {
        let stream = TcpStream::connect(("127.0.0.1", self.port())).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(30)))
            .unwrap();
        Conn {
            reader: BufReader::new(stream.try_clone().unwrap()),
            stream,
        }
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

struct Conn {
    stream: TcpStream,
    reader: BufReader<TcpStream>,
}

impl Conn {
    fn ask(&mut self, req: Value) -> Value {
        writeln!(self.stream, "{req}").unwrap();
        self.stream.flush().unwrap();
        let mut line = String::new();
        self.reader.read_line(&mut line).unwrap();
        serde_json::from_str(&line).unwrap_or_else(|e| panic!("bad reply {line:?}: {e}"))
    }
}

#[test]
fn the_daemon_serves_the_whole_protocol_over_tcp() {
    let daemon = Daemon::start();
    let mut conn = daemon.connect();

    let health = conn.ask(json!({ "op": "health" }));
    assert_eq!(health["ok"], json!(true), "{health}");
    assert_eq!(health["data"]["online"], json!(false));

    let roster = conn.ask(json!({ "op": "agents.list" }));
    assert!(roster["data"].as_array().unwrap().len() >= 8);

    // A whole turn, through the socket. Offline, so it is fast and hermetic.
    let turn = conn.ask(json!({ "op": "chat", "text": "what should I cook for dinner?" }));
    assert_eq!(turn["ok"], json!(true), "{turn}");
    assert_eq!(turn["data"]["agent"]["slug"], json!("food"));

    // Garbage is answered, not fatal — the connection survives it.
    let bad = conn.ask(json!("not an object"));
    assert_eq!(bad["ok"], json!(false));
    let still = conn.ask(json!({ "op": "stats" }));
    assert_eq!(still["ok"], json!(true));
}

#[test]
fn two_connections_share_one_backend_in_order() {
    let daemon = Daemon::start();
    let mut gui = daemon.connect();
    let mut cli = daemon.connect();

    let made = cli.ask(json!({
        "op": "item.add", "agent": "coding", "kind": "note",
        "title": "socket", "body": "written over one connection"
    }));
    assert_eq!(made["ok"], json!(true), "{made}");

    // …and visible over the other, because there is exactly one database.
    let found = gui.ask(json!({
        "op": "search", "agent": "coding", "query": "written over one connection",
        "mode": "bm25"
    }));
    assert_eq!(found["data"]["hits"].as_array().unwrap().len(), 1);
}

#[test]
fn provider_choice_persists_and_is_honoured_not_substituted() {
    let daemon = Daemon::start();
    let mut conn = daemon.connect();

    let info = conn.ask(json!({ "op": "provider" }));
    assert_eq!(info["data"]["current"], json!("auto"));

    // Both brains are shut by the environment above, so auto resolves to
    // offline and names both reasons.
    assert_eq!(info["data"]["effective"], json!("offline"));
    let why = info["data"]["why"].as_str().unwrap();
    assert!(why.contains("cloud"), "{why}");

    // Ask for the cloud explicitly: with no key that is offline, not a quiet
    // fallback to anything else.
    let set = conn.ask(json!({ "op": "provider.set", "provider": "cloud" }));
    assert_eq!(set["data"]["current"], json!("cloud"));
    assert_eq!(set["data"]["effective"], json!("offline"));

    // The choice is in the space, not the process: a new daemon on the same
    // folder wakes up with it.
    drop(conn);
    let stats = daemon.connect().ask(json!({ "op": "provider" }));
    assert_eq!(stats["data"]["current"], json!("cloud"));

    let bad = daemon
        .connect()
        .ask(json!({ "op": "provider.set", "provider": "abacus" }));
    assert_eq!(bad["ok"], json!(false));
}

#[test]
fn the_setup_is_read_written_and_cleared_through_the_space() {
    let daemon = Daemon::start();
    let mut conn = daemon.connect();

    // Every value comes with where it came from. The engine is `off` from
    // the environment above; the model is nobody's choice yet.
    let info = conn.ask(json!({ "op": "config" }));
    assert_eq!(info["ok"], json!(true));
    let setup = &info["data"]["setup"];
    assert_eq!(setup["ondevice.engine"]["value"], json!("off"));
    assert_eq!(setup["ondevice.engine"]["source"], json!("env"));
    assert_eq!(setup["ondevice.model"]["value"], json!("qwen3.8:27b-mlx"));
    assert_eq!(setup["ondevice.model"]["source"], json!("default"));
    assert_eq!(setup["cloud.key"]["set"], json!(false));
    assert!(info["data"]["keys"]
        .as_array()
        .unwrap()
        .contains(&json!("cloud.host")));

    // Written into the space, and rewired without a restart.
    let set = conn.ask(json!({
        "op": "config.set",
        "values": { "ondevice.model": "qwen3.8:8b", "cloud.key": "sk-0123456789" }
    }));
    assert_eq!(set["ok"], json!(true), "{set}");
    let setup = &set["data"]["setup"];
    assert_eq!(setup["ondevice.model"]["value"], json!("qwen3.8:8b"));
    assert_eq!(setup["ondevice.model"]["source"], json!("space"));
    // A secret is reported as set, never shown.
    assert_eq!(setup["cloud.key"]["set"], json!(true));
    assert_eq!(setup["cloud.key"]["value"], json!("********6789"));
    // The key is enough to open the cloud path; the environment still says
    // the engine is off, and the environment wins for this run.
    assert_eq!(set["data"]["provider"]["cloud"]["ready"], json!(true));
    assert_eq!(setup["ondevice.engine"]["value"], json!("off"));

    // A new daemon on the same folder wakes up with it.
    drop(conn);
    let again = daemon.connect().ask(json!({ "op": "config" }));
    assert_eq!(
        again["data"]["setup"]["ondevice.model"]["value"],
        json!("qwen3.8:8b")
    );

    // Blank clears the override and the default shows through.
    let cleared = daemon
        .connect()
        .ask(json!({ "op": "config.set", "key": "ondevice.model", "value": "" }));
    assert_eq!(
        cleared["data"]["setup"]["ondevice.model"]["source"],
        json!("default")
    );

    // Unknown keys and impossible values are refused with a sentence.
    let bad = daemon
        .connect()
        .ask(json!({ "op": "config.set", "key": "cloud.password", "value": "x" }));
    assert_eq!(bad["ok"], json!(false));
    assert!(bad["error"].as_str().unwrap().contains("no setting"));
    let bad = daemon
        .connect()
        .ask(json!({ "op": "config.set", "key": "ondevice.host", "value": "localhost:11434" }));
    assert_eq!(bad["ok"], json!(false));
    assert!(bad["error"].as_str().unwrap().contains("http://"));
}

#[test]
fn a_raw_brain_call_obeys_the_same_choice_and_refuses_when_nothing_can_answer() {
    let daemon = Daemon::start();
    let mut conn = daemon.connect();

    // Both brains are shut, so the swarm's console gets the same refusal
    // the robots would — not a quiet dial-out on a link of its own.
    let reply = conn.ask(json!({
        "op": "brain.chat",
        "messages": [{ "role": "user", "content": "hello" }],
        "tools": [],
    }));
    assert_eq!(reply["ok"], json!(false));
    let why = reply["error"].as_str().unwrap();
    assert!(why.contains("no brain can answer"), "{why}");

    let empty = conn.ask(json!({ "op": "brain.chat" }));
    assert_eq!(empty["ok"], json!(false));
    assert!(empty["error"].as_str().unwrap().contains("messages"));
}

#[test]
fn daemon_stop_stops_the_daemon_but_a_chat_about_it_does_not() {
    let mut daemon = Daemon::start();
    let mut conn = daemon.connect();

    // The trap: a message whose *text* names the op. This must be an ordinary
    // turn, and the daemon must still be standing afterwards.
    let chat = conn.ask(json!({ "op": "chat", "text": "what does daemon.stop do?" }));
    assert_eq!(chat["ok"], json!(true));
    let alive = conn.ask(json!({ "op": "health" }));
    assert_eq!(alive["ok"], json!(true));

    let port_file = daemon.dir.path().join("agentd.port");
    assert!(port_file.exists());

    let bye = conn.ask(json!({ "op": "daemon.stop" }));
    assert_eq!(bye["data"]["stopping"], json!(true));

    let status = daemon.child.wait().unwrap();
    assert!(status.success(), "the daemon exited badly: {status:?}");
    // …and it cleaned up after itself, so the next client cannot find a corpse.
    assert!(!port_file.exists(), "agentd.port was left behind");
}

/// One daemon per space. The second `listen` must fail — not take another
/// ephemeral port and overwrite the file the first one's clients are reading.
#[test]
fn a_second_daemon_on_the_same_space_fails() {
    let daemon = Daemon::start();
    let port = daemon.port();

    let second = listen(daemon.dir.path(), &[])
        .stdout(Stdio::null())
        .output()
        .unwrap();
    assert!(
        !second.status.success(),
        "the second daemon should have refused"
    );
    let err = String::from_utf8_lossy(&second.stderr);
    assert!(err.contains("already listening"), "{err}");
    assert!(err.contains(&port.to_string()), "{err}");

    // The first one is untouched: same port on file, still answering.
    assert_eq!(daemon.port(), port);
    let mut conn = daemon.connect();
    assert_eq!(conn.ask(json!({ "op": "stats" }))["ok"], json!(true));
}

/// A fixed port that something else already holds is a failure with the
/// port in the message — `make start` pins the port, so this is the case a
/// second `make start` runs into.
#[test]
fn a_daemon_on_a_taken_port_fails() {
    let daemon = Daemon::start();
    let port = daemon.port();

    let other_space = tempfile::tempdir().unwrap();
    let second = listen(other_space.path(), &["--port", &port.to_string()])
        .stdout(Stdio::null())
        .output()
        .unwrap();
    assert!(
        !second.status.success(),
        "the port was taken; the daemon should have failed"
    );
    let err = String::from_utf8_lossy(&second.stderr);
    assert!(err.contains("already in use"), "{err}");
    assert!(err.contains(&port.to_string()), "{err}");
    assert!(
        !other_space.path().join("agentd.port").exists(),
        "a daemon that never listened must not write a port file"
    );
    assert_eq!(daemon.port(), port);
}

/// `prepare` is what the client asks for behind its boot screen. With no
/// engine to load — this suite runs with both shut — it answers at once and
/// says why, rather than failing: a cloud or offline session has nothing to
/// wait for, and the boot screen must not stall on it.
#[test]
fn prepare_answers_at_once_when_there_is_nothing_to_load() {
    let daemon = Daemon::start();
    let mut conn = daemon.connect();

    let reply = conn.ask(json!({ "op": "prepare" }));
    assert_eq!(reply["ok"], json!(true), "{reply}");
    assert_eq!(reply["data"]["loaded"], json!(false));
    assert_eq!(reply["data"]["engine"], json!(null));
    assert!(
        reply["data"]["why"].as_str().is_some_and(|w| !w.is_empty()),
        "{reply}"
    );
    assert!(reply["data"]["seconds"].as_f64().unwrap() < 5.0);

    // Still standing, still answering.
    assert_eq!(conn.ask(json!({ "op": "stats" }))["ok"], json!(true));
}
