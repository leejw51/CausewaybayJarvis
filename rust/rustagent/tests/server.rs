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

    /// A request as bytes in, the status, the headers and the body out.
    fn raw(&self, request: &[u8]) -> (u16, String, Vec<u8>) {
        let mut stream = TcpStream::connect(("127.0.0.1", self.port())).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(60)))
            .unwrap();
        stream.write_all(request).unwrap();
        let mut bytes = Vec::new();
        stream.read_to_end(&mut bytes).unwrap();
        let split = bytes
            .windows(4)
            .position(|w| w == b"\r\n\r\n")
            .expect("a header block");
        let head = String::from_utf8_lossy(&bytes[..split]).to_string();
        let status: u16 = head
            .split_whitespace()
            .nth(1)
            .and_then(|s| s.parse().ok())
            .unwrap_or(0);
        (status, head, bytes[split + 4..].to_vec())
    }

    /// A file up the `/upload` route, as the web client sends one.
    fn upload(&self, agent: &str, name: &str, mime: &str, body: &[u8]) -> Value {
        let mut req = format!(
            "POST /upload?agent={agent}&name={name} HTTP/1.1\r\nHost: x\r\nContent-Type: {mime}\r\nContent-Length: {}\r\n\r\n",
            body.len()
        )
        .into_bytes();
        req.extend_from_slice(body);
        let (status, _, reply) = self.raw(&req);
        assert_eq!(status, 200);
        serde_json::from_slice(&reply).unwrap()
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
    assert!(reply["data"]
        .as_array()
        .map(|a| a.len() >= 8)
        .unwrap_or(false));

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

    send(
        &mut ws,
        json!({ "id": 1, "op": "chat", "agent": "food", "text": "what should I cook tonight?" }),
    );
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
    send(
        &mut ws,
        json!({ "id": "a", "op": "chat", "agent": "coding", "text": "hello" }),
    );
    send(
        &mut ws,
        json!({ "id": "b", "op": "page", "agent": "coding" }),
    );
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
    let (status, body) =
        server.http("GET /health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
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

    // The index says the WebSocket is there — and the page a browser gets
    // at the root is the web client, not the index.
    let (_, body) = server.http("GET /api HTTP/1.1\r\nHost: x\r\n\r\n");
    assert!(body.contains("/ws"), "{body}");
    let (status, body) = server.http("GET / HTTP/1.1\r\nHost: x\r\n\r\n");
    assert_eq!(status, 200);
    assert!(body.contains("<!doctype html>"), "{body}");
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
        assert!(
            Instant::now() < deadline,
            "agentd did not exit after daemon.stop"
        );
        std::thread::sleep(Duration::from_millis(25));
    }
    assert!(
        !server.dir.path().join("agentd.port").exists(),
        "the port file should be gone"
    );
}

#[test]
fn over_the_websocket_the_frame_id_is_never_taken_for_a_row() {
    let server = Server::start();
    let mut ws = server.ws();

    send(
        &mut ws,
        json!({ "id": 1, "op": "item.add", "agent": "food", "body": "a note to keep" }),
    );
    let reply = frame(&mut ws);
    assert_eq!(reply["id"], json!(1), "{reply}");
    assert_eq!(reply["ok"], json!(true), "{reply}");
    let row = reply["data"]["id"].as_i64().expect("the row's number");

    // A delete that names no `item`, whose frame id happens to be that
    // very row: refused, and the row is still there.
    send(&mut ws, json!({ "id": row, "op": "item.delete" }));
    let reply = frame(&mut ws);
    assert_eq!(reply["id"], json!(row));
    assert_eq!(reply["ok"], json!(false), "{reply}");
    assert!(
        reply["error"]
            .as_str()
            .unwrap_or("")
            .contains("needs an item"),
        "{reply}"
    );
    send(&mut ws, json!({ "id": 2, "op": "item.read", "item": row }));
    let reply = frame(&mut ws);
    assert_eq!(reply["ok"], json!(true), "{reply}");
    assert_eq!(reply["data"]["body"], json!("a note to keep"));

    // The same read without `item` is refused too, even with a frame id
    // that is a real row.
    send(&mut ws, json!({ "id": row, "op": "item.read" }));
    let reply = frame(&mut ws);
    assert_eq!(reply["ok"], json!(false), "{reply}");

    // Named properly, the row goes, and the reply carries the frame id.
    send(
        &mut ws,
        json!({ "id": 3, "op": "item.delete", "item": row }),
    );
    let reply = frame(&mut ws);
    assert_eq!(reply["id"], json!(3));
    assert_eq!(reply["data"]["deleted"], json!(true), "{reply}");
}

fn header<'a>(head: &'a str, name: &str) -> Option<&'a str> {
    head.lines().find_map(|l| {
        let (k, v) = l.split_once(':')?;
        k.eq_ignore_ascii_case(name).then(|| v.trim())
    })
}

#[test]
fn the_web_client_and_its_files_come_out_of_the_binary() {
    let server = Server::start();
    for (path, mime) in [
        ("/", "text/html"),
        ("/app.css", "text/css"),
        ("/app.js", "text/javascript"),
        ("/manifest.webmanifest", "application/manifest+json"),
        ("/fonts/chakra-petch-700-latin.woff2", "font/woff2"),
    ] {
        let (status, head, body) =
            server.raw(format!("GET {path} HTTP/1.1\r\nHost: x\r\n\r\n").as_bytes());
        assert_eq!(status, 200, "{path}");
        assert!(
            header(&head, "content-type").unwrap().starts_with(mime),
            "{path}: {head}"
        );
        assert!(!body.is_empty(), "{path} is empty");
        // Revalidation: the same tag back is a 304 and no body.
        let tag = header(&head, "etag").unwrap().to_string();
        let (status, _, body) = server.raw(
            format!("GET {path} HTTP/1.1\r\nHost: x\r\nIf-None-Match: {tag}\r\n\r\n").as_bytes(),
        );
        assert_eq!(status, 304, "{path}");
        assert!(body.is_empty());
    }
    // HEAD answers the headers and nothing else.
    let (status, head, body) = server.raw(b"HEAD / HTTP/1.1\r\nHost: x\r\n\r\n");
    assert_eq!(status, 200);
    assert!(header(&head, "content-length").is_some());
    assert!(body.is_empty());
    // And `/where` says where the server is.
    let (_, body) = server.http("GET /where HTTP/1.1\r\nHost: x\r\n\r\n");
    let reply: Value = serde_json::from_str(&body).unwrap();
    assert_eq!(reply["data"]["loopback"], json!(true));
    assert_eq!(
        reply["data"]["urls"][0],
        json!(format!("http://127.0.0.1:{}/", server.port()))
    );
}

#[test]
fn an_upload_is_filed_and_the_shelf_is_served_back_in_ranges() {
    let server = Server::start();
    let png = std::fs::read(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/tests/fixtures/orange.jpg"
    ))
    .unwrap();
    let reply = server.upload("food", "IMG%200042.JPG", "image/jpeg", &png);
    assert_eq!(reply["ok"], json!(true), "{reply}");
    assert_eq!(reply["data"]["kind"], json!("image"));
    assert_eq!(reply["data"]["title"], json!("IMG 0042.JPG"));
    let rel = reply["data"]["path"].as_str().unwrap().to_string();
    assert!(rel.ends_with("/photos/img-0042.jpg"), "{rel}");
    assert!(server.dir.path().join(&rel).is_file());
    // The temporary file is gone once the picture is on the shelf.
    let leftovers: Vec<_> = std::fs::read_dir(server.dir.path().join("tmp"))
        .map(|d| {
            d.filter_map(|e| e.ok())
                .filter(|e| e.file_name().to_string_lossy().starts_with("upload-"))
                .collect()
        })
        .unwrap_or_default();
    assert!(leftovers.is_empty(), "{leftovers:?}");

    // The whole file back, byte for byte.
    let (status, head, body) =
        server.raw(format!("GET /file/{rel} HTTP/1.1\r\nHost: x\r\n\r\n").as_bytes());
    assert_eq!(status, 200);
    assert_eq!(header(&head, "content-type"), Some("image/jpeg"));
    assert_eq!(header(&head, "accept-ranges"), Some("bytes"));
    assert!(header(&head, "content-security-policy")
        .unwrap()
        .contains("sandbox"));
    assert_eq!(header(&head, "x-content-type-options"), Some("nosniff"));
    assert_eq!(body, png);

    // An upload a browser would execute on this origin comes back as a
    // download, never as a page.
    let reply = server.upload(
        "food",
        "evil.html",
        "text/html",
        b"<script>alert(1)</script>",
    );
    assert_eq!(reply["data"]["kind"], json!("file"));
    let html = reply["data"]["path"].as_str().unwrap().to_string();
    let (status, head, _) =
        server.raw(format!("GET /file/{html} HTTP/1.1\r\nHost: x\r\n\r\n").as_bytes());
    assert_eq!(status, 200);
    assert_eq!(
        header(&head, "content-type"),
        Some("application/octet-stream")
    );
    assert!(header(&head, "content-disposition")
        .unwrap()
        .starts_with("attachment;"));

    // A range — what an iPhone asks for before it will play a video.
    let (status, head, body) = server
        .raw(format!("GET /file/{rel} HTTP/1.1\r\nHost: x\r\nRange: bytes=2-5\r\n\r\n").as_bytes());
    assert_eq!(status, 206);
    assert_eq!(
        header(&head, "content-range"),
        Some(format!("bytes 2-5/{}", png.len()).as_str())
    );
    assert_eq!(body, &png[2..6]);
    let (status, _, _) = server.raw(
        format!("GET /file/{rel} HTTP/1.1\r\nHost: x\r\nRange: bytes=99999999-\r\n\r\n").as_bytes(),
    );
    assert_eq!(status, 416);

    // Nothing but the shelves.
    for bad in [
        "/file/robots.db",
        "/file/../robots.db",
        "/file/agents/x/agent.db",
        "/file/tmp/x",
    ] {
        let (status, _, _) =
            server.raw(format!("GET {bad} HTTP/1.1\r\nHost: x\r\n\r\n").as_bytes());
        assert_eq!(status, 404, "{bad}");
    }

    // An empty upload, and one with no length, are refused with a sentence.
    let (status, _, body) =
        server.raw(b"POST /upload?agent=food&name=x.png HTTP/1.1\r\nHost: x\r\n\r\n");
    assert_eq!(status, 411);
    assert!(String::from_utf8_lossy(&body).contains("Content-Length"));
}

/// A video up the same route: filed on the video shelf, and — when this
/// machine can encode Theora — with the three-second LÖVE clip and a poster
/// frame beside it. Without an encoder the video is still filed and the
/// row says why there is no clip.
#[test]
fn a_video_upload_gets_its_love_clip() {
    let Some(ffmpeg) = rustagent::video::which("ffmpeg") else {
        eprintln!("skipping: no ffmpeg to make a test video with");
        return;
    };
    let dir = tempfile::tempdir().unwrap();
    let src = dir.path().join("test.mp4");
    let made = std::process::Command::new(&ffmpeg)
        .args([
            "-y",
            "-hide_banner",
            "-loglevel",
            "error",
            "-f",
            "lavfi",
            "-i",
            "testsrc=duration=5:size=320x240:rate=15",
            "-pix_fmt",
            "yuv420p",
        ])
        .arg(&src)
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    if !made {
        eprintln!("skipping: ffmpeg could not make a test video");
        return;
    }
    let bytes = std::fs::read(&src).unwrap();

    let server = Server::start();
    let reply = server.upload("food", "holiday.mp4", "video/mp4", &bytes);
    assert_eq!(reply["ok"], json!(true), "{reply}");
    let item = &reply["data"];
    assert_eq!(item["kind"], json!("video"));
    assert_eq!(item["mime"], json!("video/mp4"));
    let rel = item["path"].as_str().unwrap().to_string();
    assert!(rel.ends_with("/videos/holiday.mp4"), "{rel}");
    let meta: Value = serde_json::from_str(item["meta"].as_str().unwrap()).unwrap();

    match rustagent::video::tools().encoder() {
        Err(why) => {
            eprintln!("no Theora encoder here ({why}); the video is filed without a clip");
            assert!(meta["clip"].is_null());
            assert!(meta["why"].as_str().unwrap().contains("brew install"));
        }
        Ok(_) => {
            let clip = meta["clip"].as_str().expect("the clip in the meta");
            assert_eq!(clip, rel.replace(".mp4", ".clip.ogv"));
            let ogv = std::fs::read(server.dir.path().join(clip)).unwrap();
            assert_eq!(&ogv[..4], b"OggS", "the clip is an Ogg file");
            assert!(ogv.windows(6).any(|w| w == b"theora"), "the clip is Theora");
            assert!(meta["seconds"].as_f64().unwrap() <= 3.0);
            assert!(
                item["clip"].as_str().unwrap().ends_with(".clip.ogv"),
                "an absolute clip path for LÖVE"
            );
            let poster = meta["poster"].as_str().expect("the poster frame");
            let png = std::fs::read(server.dir.path().join(poster)).unwrap();
            assert_eq!(&png[1..4], b"PNG");
            assert!(item["body"].as_str().unwrap().contains("LÖVE clip"));
            // The page lists it on its own shelf, and the clip is served.
            let (_, body) = server.http("POST /v1/page HTTP/1.1\r\nHost: x\r\nContent-Length: 16\r\n\r\n{\"agent\":\"food\"}");
            let page: Value = serde_json::from_str(&body).unwrap();
            assert_eq!(page["data"]["videos"][0]["title"], json!("holiday.mp4"));
            let (status, head, served) =
                server.raw(format!("GET /file/{clip} HTTP/1.1\r\nHost: x\r\n\r\n").as_bytes());
            assert_eq!(status, 200);
            assert_eq!(header(&head, "content-type"), Some("video/ogg"));
            assert_eq!(served, ogv);
        }
    }
}
