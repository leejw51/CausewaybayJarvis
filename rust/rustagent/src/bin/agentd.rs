//! `agentd` — the robot backend, on a pipe.
//!
//! ```sh
//! agentd listen                     # the daemon: TCP on 127.0.0.1, port in agentd.port
//! agentd serve                      # the same protocol on stdin/stdout
//! agentd health                     # one-shot, for a terminal
//! agentd config                     # the AI setup, and where each value came from
//! agentd chat --agent coding "why won't this borrow?"
//! agentd search "pork belly" --mode bm25
//! agentd call '{"op":"page","agent":"food"}'
//! ```
//!
//! `listen` is the server every client talks to: one long-lived process
//! holding the database — and, in a `--features mlx` build, fifteen
//! gigabytes of model — open across turns. It binds one port on 127.0.0.1
//! and writes it to `agentd.port` in the space, so a client finds it by
//! reading a file rather than by guessing, and two spaces never fight over
//! one port. On that port it speaks three ways: a WebSocket at `/ws` (the
//! LÖVE client, rustcli), HTTP with server-sent events (`curl`, a browser),
//! and line JSON over plain TCP (`nc`). See [`rustagent::server`]. `serve`
//! speaks the line protocol on a pipe, which is what shell one-liners use.
//! The one-shot forms are the same ops with a friendlier spelling.

use std::io::{BufRead, Write};

use serde_json::{json, Value};

use rustagent::proto::{Backend, OPS};

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let command = args.first().map(String::as_str).unwrap_or("serve");

    if matches!(command, "-h" | "--help" | "help") {
        print!("{USAGE}");
        return;
    }
    if command == "ops" {
        println!("{}", OPS.join("\n"));
        return;
    }

    let backend = match Backend::boot() {
        Ok(b) => b,
        Err(e) => {
            // Even a failure to open the space answers in the protocol, so the
            // client shows a sentence instead of an empty pipe.
            println!("{}", json!({ "ok": false, "error": e.to_string() }));
            std::process::exit(1);
        }
    };

    match command {
        "serve" => serve(&backend),
        "listen" => {
            let port = args
                .iter()
                .position(|a| a == "--port")
                .and_then(|i| args.get(i + 1))
                .and_then(|p| p.parse::<u16>().ok())
                .or_else(|| std::env::var("JARVIS_AGENT_PORT").ok()?.parse().ok())
                .unwrap_or(0);
            if let Err(e) = rustagent::server::listen(backend, port) {
                eprintln!("agentd: {e}");
                std::process::exit(1);
            }
        }
        _ => {
            let request = match parse(&args) {
                Ok(r) => r,
                Err(e) => {
                    println!("{}", json!({ "ok": false, "error": e }));
                    std::process::exit(2);
                }
            };
            let reply = backend.handle(&request);
            let pretty = std::env::var("AGENTD_PRETTY").is_ok() || atty_stdout();
            println!(
                "{}",
                if pretty {
                    serde_json::to_string_pretty(&reply).unwrap_or_default()
                } else {
                    reply.to_string()
                }
            );
            if reply["ok"] != json!(true) {
                std::process::exit(1);
            }
        }
    }
}

/// One request per line in, one reply per line out. A blank line is skipped
/// and a malformed one is answered rather than fatal, because the other end of
/// this pipe is a UI thread that must not be left waiting.
fn serve(backend: &Backend) {
    let stdin = std::io::stdin();
    let mut out = std::io::stdout();
    for line in stdin.lock().lines() {
        let Ok(line) = line else { break };
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        if line == "quit" || line == "exit" {
            break;
        }
        let reply = match serde_json::from_str::<Value>(line) {
            Ok(req) => backend.handle(&req),
            Err(e) => json!({ "ok": false, "error": format!("bad json: {e}") }),
        };
        let stopping = reply["ok"] == json!(true) && reply["op"] == json!("daemon.stop");
        if writeln!(out, "{reply}").is_err() || out.flush().is_err() {
            break;
        }
        if stopping {
            break;
        }
    }
}

/// Turn the friendly command line into the same JSON `serve` would receive.
fn parse(args: &[String]) -> std::result::Result<Value, String> {
    let command = args[0].as_str();
    let rest = &args[1..];

    if command == "call" {
        let raw = rest.first().ok_or("call needs a JSON object")?;
        return serde_json::from_str(raw).map_err(|e| format!("bad json: {e}"));
    }

    // --flag value pairs, and everything else joined as the positional.
    let mut flags: std::collections::HashMap<String, String> = Default::default();
    let mut positional: Vec<String> = Vec::new();
    let mut i = 0;
    while i < rest.len() {
        let a = &rest[i];
        if let Some(name) = a.strip_prefix("--") {
            let value = rest.get(i + 1).cloned().unwrap_or_else(|| "true".into());
            flags.insert(name.to_string(), value);
            i += 2;
        } else {
            positional.push(a.clone());
            i += 1;
        }
    }
    let text = positional.join(" ");

    let mut req = json!({ "op": command });
    for (k, v) in &flags {
        req[k] = match v.parse::<i64>() {
            Ok(n) => json!(n),
            Err(_) if v == "true" => json!(true),
            Err(_) if v == "false" => json!(false),
            Err(_) => json!(v),
        };
    }

    // The one positional argument means something different per command, which
    // is the whole point of the friendly form.
    match command {
        "chat" => req["text"] = json!(text),
        "route" => req["text"] = json!(text),
        "search" => req["query"] = json!(text),
        "page" | "agents.get" | "items" | "messages" | "messages.clear" | "reindex"
        | "agents.delete" => {
            if !text.is_empty() {
                req["agent"] = json!(text);
            }
        }
        "provider.set" => {
            if !text.is_empty() {
                req["provider"] = json!(text);
            }
        }
        // `agentd config.set ondevice.model qwen3.8:27b-mlx`, or with the
        // flags spelled out; a key alone clears it.
        "config.set" => {
            if let Some(key) = positional.first() {
                req["key"] = json!(key);
                req["value"] = json!(positional[1..].join(" "));
            }
        }
        "item.read" | "item.delete" => {
            if let Ok(n) = text.parse::<i64>() {
                req["id"] = json!(n);
            }
        }
        "add" => {
            req["op"] = json!("item.add");
            if !text.is_empty() {
                req["path"] = json!(text);
            }
        }
        _ => {
            if !text.is_empty() {
                req["text"] = json!(text);
            }
        }
    }
    Ok(req)
}

fn atty_stdout() -> bool {
    #[cfg(unix)]
    unsafe {
        extern "C" {
            fn isatty(fd: i32) -> i32;
        }
        isatty(1) == 1
    }
    #[cfg(not(unix))]
    false
}

const USAGE: &str = "\
agentd — the Causeway Bay robot backend

  agentd listen [--port N]              the server on 127.0.0.1, port written to
                                        <space>/agentd.port (0 = ephemeral):
                                        ws://…/ws, http://…/v1/<op> (+ SSE), line JSON
  agentd serve                          the same protocol on stdin
  agentd provider                       which brain answers: ondevice | cloud | auto
  agentd provider.set --provider cloud  change it (persists in the space)
  agentd config                         the AI setup: on-device engine, daemon, cloud
  agentd config.set ondevice.model qwen3.8:27b-mlx
                                        change one value (a key alone clears it)
  agentd health                         is there a model, and where does it run
  agentd prepare                        load the on-device brain now, not on the first turn
  agentd stats                          what the archive holds
  agentd agents.list                    the roster
  agentd page coding                    one robot's page: gallery, markdown, files
  agentd add ~/photo.png --agent food   file something into a robot's space
  agentd search \"pork belly\" --mode bm25|semantic|hybrid [--all]
  agentd route \"why won't this borrow?\" which robot would answer
  agentd chat --agent coding \"...\"       one turn
  agentd call '{\"op\":\"brain.chat\",\"messages\":[...]}'
                                        one raw model call, same brain choice
  agentd messages coding --limit 20     the transcript
  agentd reindex [robot]                give every row a vector
  agentd call '{\"op\":\"page\"}'           the raw protocol
  agentd ops                            every op there is

The space is ~/.causewaybayjarvis, or $JARVIS_HOME. The model comes from
OLLAMA_HOST / OLLAMA_API_KEY / OLLAMA_MODEL / OLLAMA_EMBED; with none of them
set, everything still runs offline against the local archive.
";
