//! The server, over real sockets: three protocols on one port.
//!
//! `agentd listen` is spawned on a scratch space with both brains shut, the
//! way the daemon suite does it, and then spoken to as each kind of client
//! would — a WebSocket client with ids and streamed turns, an HTTP client
//! reading a response and an event stream, and the old line-JSON client —
//! all on the one port the port file names.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpStream;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use serde_json::{json, Value};
use tungstenite::protocol::Message;

struct Server {
    child: Child,
    dir: tempfile::TempDir,
}

impl Server {
    fn start() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let child = Command::new(env!("CARGO_BIN_EXE_agentd"))
            .arg("listen")
            .env("JARVIS_HOME", dir.path())
            .env("OLLAMA_API_KEY", "")
            .env("OLLAMA_HOST", "https://ollama.com")
            .env("JARVIS_NO_MLX", "1")
            .env("ONDEVICE_ENGINE", "off")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawning agentd");
        Self { child, dir }
    }

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

    fn ws(&self) -> tungstenite::WebSocket<tungstenite::stream::MaybeTlsStream<TcpStream>> {
        let url = format!("ws://127.0.0.1:{}/ws", self.port());
        let (ws, response) = tungstenite::connect(url).expect("websocket handshake");
        assert_eq!(response.status().as_u16(), 101);
        ws
    }

    fn http(&self, request: &str) -> (u16, String) {
        let mut stream = TcpStream::connect(("127.0.0.1", self.port())).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(30)))
            .unwrap();
        stream.write_all(request.as_bytes()).unwrap();
        let mut raw = String::new();
        stream.read_to_string(&mut raw).unwrap();
        let status: u16 = raw
            .split_whitespace()
            .nth(1)
            .and_then(|s| s.parse().ok())
            .unwrap_or(0);
        let body = raw.split("\r\n\r\n").nth(1).unwrap_or("").to_string();
        (status, body)
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// The next text frame, as JSON.
fn frame(ws: &mut tungstenite::WebSocket<tungstenite::stream::MaybeTlsStream<TcpStream>>) -> Value {
    loop {
        match ws.read().expect("a frame") {
            Message::Text(text) => return serde_json::from_str(text.as_str()).expect("json frame"),
            Message::Ping(_) | Message::Pong(_) => continue,
            other => panic!("unexpected frame {other:?}"),
        }
    }
}

fn send(
    ws: &mut tungstenite::WebSocket<tungstenite::stream::MaybeTlsStream<TcpStream>>,
    request: Value,
) {
    ws.send(Message::Text(request.to_string().into())).unwrap();
}

#[test]
fn a_websocket_client_asks_with_an_id_and_is_answered_with_it() {
    let server = Server::start();
    let mut ws = server.ws();

    send(&mut ws, json!({ "id": 7, "op": "health" }));
    let reply = frame(&mut ws);
    assert_eq!(reply["id"], json!(7));
    assert_eq!(reply["ok"], json!(true));
    assert_eq!(reply["op"], json!("health"));
    assert_eq!(reply["data"]["provider"]["effective"], json!("offline"));

    // An id is any JSON value the client likes, and it comes back verbatim.
    send(&mut ws, json!({ "id": "roster", "op": "agents.list" }));
    let reply = frame(&mut ws);
    assert_eq!(reply["id"], json!("roster"));
    assert!(reply["data"].as_array().map(|a| a.len() >= 8).unwrap_or(false));

    // No id: no id in the reply either, and still a reply.
    send(&mut ws, json!({ "op": "stats" }));
    let reply = frame(&mut ws);
    assert!(reply.get("id").is_none());
    assert_eq!(reply["ok"], json!(true));
}

#[test]
fn a_turn_over_a_websocket_streams_its_pieces_before_the_whole() {
    let server = Server::start();
    let mut ws = server.ws();

    send(&mut ws, json!({ "id": 1, "op": "chat", "agent": "food", "text": "what should I cook tonight?" }));
    let mut chunks = Vec::new();
    let done = loop {
        let f = frame(&mut ws);
        assert_eq!(f["id"], json!(1), "every frame of the turn carries its id");
        if f.get("chunk").is_some() {
            chunks.push(f);
        } else {
            break f;
        }
    };
    assert_eq!(done["ok"], json!(true), "{done}");
    assert_eq!(done["op"], json!("chat"));
    assert_eq!(done["data"]["agent"]["slug"], json!("food"));
    // The offline brain answers out of the archive in one piece, and that
    // piece is streamed as a token before the turn lands.
    assert!(!chunks.is_empty(), "no chunks before the turn");
    assert!(chunks.iter().any(|c| c["chunk"] == json!("token")));
    let joined: String = chunks
        .iter()
        .filter(|c| c["chunk"] == json!("token"))
        .map(|c| c["text"].as_str().unwrap_or(""))
        .collect();
    assert_eq!(joined, done["data"]["reply"].as_str().unwrap());
}

#[test]
fn two_turns_in_flight_come_back_in_order_each_under_its_own_id() {
    let server = Server::start();
    let mut ws = server.ws();
    send(&mut ws, json!({ "id": "a", "op": "chat", "agent": "coding", "text": "hello" }));
    send(&mut ws, json!({ "id": "b", "op": "page", "agent": "coding" }));
    let mut finals = Vec::new();
    while finals.len() < 2 {
        let f = frame(&mut ws);
        if f.get("chunk").is_none() {
            finals.push(f);
        }
    }
    assert_eq!(finals[0]["id"], json!("a"));
    assert_eq!(finals[0]["op"], json!("chat"));
    assert_eq!(finals[1]["id"], json!("b"));
    assert_eq!(finals[1]["op"], json!("page"));
}

#[test]
fn stop_is_answered_at_once_and_says_how_many_it_found() {
    let server = Server::start();
    let mut ws = server.ws();
    send(&mut ws, json!({ "id": 3, "op": "stop" }));
    let reply = frame(&mut ws);
    assert_eq!(reply["id"], json!(3));
    assert_eq!(reply["ok"], json!(true));
    assert_eq!(reply["op"], json!("stop"));
    assert_eq!(reply["data"]["stopped"], json!(0), "nothing was in flight");
}

#[test]
fn a_frame_that_is_not_json_is_refused_and_the_connection_lives_on() {
    let server = Server::start();
    let mut ws = server.ws();
    ws.send(Message::Text("}{".into())).unwrap();
    let reply = frame(&mut ws);
    assert_eq!(reply["ok"], json!(false));
    assert!(reply["error"].as_str().unwrap().contains("bad json"));
    send(&mut ws, json!({ "id": 2, "op": "health" }));
    assert_eq!(frame(&mut ws)["id"], json!(2));
}

#[test]
fn http_and_server_sent_events_answer_on_the_same_port() {
    let server = Server::start();
    let (status, body) = server.http("GET /health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
    assert_eq!(status, 200);
    let reply: Value = serde_json::from_str(&body).unwrap();
    assert_eq!(reply["ok"], json!(true));
    assert_eq!(reply["data"]["provider"]["effective"], json!("offline"));

    let (status, body) =
        server.http("GET /v1/chat/stream?text=hello&agent=jarvis HTTP/1.1\r\nHost: x\r\n\r\n");
    assert_eq!(status, 200);
    assert!(body.contains("event: token\n"), "{body}");
    assert!(body.contains("event: done\n"), "{body}");
    let done = body
        .split("event: done\ndata: ")
        .nth(1)
        .and_then(|s| s.lines().next())
        .expect("the done frame");
    let done: Value = serde_json::from_str(done).unwrap();
    assert_eq!(done["ok"], json!(true));
    assert_eq!(done["data"]["agent"]["slug"], json!("jarvis"));

    // The index says the WebSocket is there.
    let (_, body) = server.http("GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    assert!(body.contains("/ws"), "{body}");
}

#[test]
fn the_line_protocol_still_answers_on_that_port_too() {
    let server = Server::start();
    let stream = TcpStream::connect(("127.0.0.1", server.port())).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(30)))
        .unwrap();
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let mut stream = stream;
    writeln!(stream, r#"{{"op":"health"}}"#).unwrap();
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    let reply: Value = serde_json::from_str(line.trim()).unwrap();
    assert_eq!(reply["ok"], json!(true));
    assert_eq!(reply["op"], json!("health"));
}

#[test]
fn daemon_stop_over_the_websocket_shuts_the_server_down() {
    let mut server = Server::start();
    let mut ws = server.ws();
    send(&mut ws, json!({ "id": 9, "op": "daemon.stop" }));
    let reply = frame(&mut ws);
    assert_eq!(reply["id"], json!(9));
    assert_eq!(reply["data"]["stopping"], json!(true));
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if let Ok(Some(_)) = server.child.try_wait() {
            break;
        }
        assert!(Instant::now() < deadline, "agentd did not exit after daemon.stop");
        std::thread::sleep(Duration::from_millis(25));
    }
    assert!(
        !server.dir.path().join("agentd.port").exists(),
        "the port file should be gone"
    );
}
