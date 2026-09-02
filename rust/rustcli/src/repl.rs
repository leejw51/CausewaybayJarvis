//! The interactive chat loop and the streaming renderer both commands share.
//!
//! Both talk to the server: a turn is a `brain.chat` request carrying the
//! whole conversation so far, answered as `token` and `reasoning` frames
//! and then the reply. The conversation lives here, in the client, which is
//! what makes `/reset`, `/save` and `/load` plain list operations.

use std::io::Write;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use anyhow::{Context, Result};
use rustyline::error::ReadlineError;
use rustyline::DefaultEditor;
use serde_json::{json, Value};

use crate::client::Client;
use crate::ui::{StatusLine, Style};
use crate::Settings;

/// What a turn came back with, for the caller to judge.
pub struct Turn {
    pub text: String,
    pub reasoning: String,
    pub interrupted: bool,
    pub model: String,
    pub chunks: usize,
    pub seconds: f64,
}

/// Run one turn against the server, streaming it to stdout.
///
/// `interrupt` is polled between frames so Ctrl-C stops a long answer
/// without killing the process: the client sends a `stop`, and the turn
/// comes back with what had arrived.
pub fn stream_turn(
    client: &mut Client,
    messages: &[Value],
    settings: &Settings,
    style: Style,
    interrupt: Option<&Arc<AtomicBool>>,
) -> Result<Turn> {
    let mut line = StatusLine::new(style);
    let mut thinking_open = false;
    let mut wrote_answer = false;
    // Tracks how many newlines the reasoning stream already ended with, so the
    // gap before the answer is exactly one blank line however the model spaced it.
    let mut trailing_newlines = 0usize;
    let mut text = String::new();
    let mut reasoning = String::new();
    let mut chunks = 0usize;
    let started = std::time::Instant::now();

    let request = json!({
        "op": "brain.chat",
        "messages": messages,
        "tools": [],
        "options": settings.options(),
    });
    let cancel = interrupt.map(|flag| flag.as_ref());
    let reply = client.stream(request, cancel, &mut |frame| {
        chunks += 1;
        match frame["chunk"].as_str().unwrap_or("") {
            "prefill" => {
                line.set(&format!(
                    "  {} reading {}/{} tokens",
                    style.dim("…"),
                    frame["done"],
                    frame["total"]
                ));
            }
            "reasoning" => {
                let piece = frame["text"].as_str().unwrap_or("");
                reasoning.push_str(piece);
                if !settings.show_thinking {
                    line.set(&format!("  {}", style.dim("thinking…")));
                    return;
                }
                if !thinking_open {
                    line.clear();
                    print!("{}", style.dim("thinking\n"));
                    print!("{}", style.dim_on());
                    thinking_open = true;
                }
                print!("{piece}");
                trailing_newlines = piece.len() - piece.trim_end_matches('\n').len();
                let _ = std::io::stdout().flush();
            }
            "token" => {
                let piece = frame["text"].as_str().unwrap_or("");
                line.clear();
                if thinking_open {
                    print!(
                        "{}{}",
                        style.off(),
                        "\n".repeat(2usize.saturating_sub(trailing_newlines))
                    );
                    thinking_open = false;
                }
                print!("{piece}");
                text.push_str(piece);
                wrote_answer = true;
                let _ = std::io::stdout().flush();
            }
            "tool" => {
                line.set(&format!(
                    "  {}",
                    style.dim(frame["text"].as_str().unwrap_or(""))
                ));
            }
            _ => {}
        }
    })?;
    line.clear();
    if thinking_open {
        print!("{}", style.off());
    }
    if wrote_answer || thinking_open {
        println!();
    }
    let _ = std::io::stdout().flush();

    let data = Client::data(reply)?;
    // The reply is the truth; the pieces were a preview of it. They agree
    // when the stream was complete, and when it was not the reply is right.
    let whole = data["message"]["content"]
        .as_str()
        .unwrap_or("")
        .to_string();
    if !whole.is_empty() {
        text = whole;
    }
    let interrupted = data["done_reason"].as_str() == Some("interrupted")
        || interrupt.is_some_and(|f| f.load(Ordering::Relaxed));
    Ok(Turn {
        text,
        reasoning,
        interrupted,
        model: data["model"].as_str().unwrap_or("?").to_string(),
        chunks,
        seconds: started.elapsed().as_secs_f64(),
    })
}

/// One line about the last turn.
pub fn format_stats(turn: &Turn, style: Style) -> String {
    let mut parts = vec![
        format!("{} chunks", turn.chunks),
        format!("{:.1}s", turn.seconds),
        turn.model.clone(),
    ];
    if !turn.reasoning.is_empty() {
        parts.push(format!("{} chars thinking", turn.reasoning.len()));
    }
    if turn.interrupted {
        parts.push("interrupted".into());
    }
    style.dim(&format!("  {}", parts.join(" · ")))
}

/// The interactive loop.
pub fn run(client: &mut Client, mut settings: Settings, style: Style) -> Result<()> {
    let interrupt = Arc::new(AtomicBool::new(false));
    {
        let flag = interrupt.clone();
        // Ctrl-C stops the running answer rather than the process. Installed
        // once; a second REPL in the same process would be a bug elsewhere.
        let _ = ctrlc::set_handler(move || flag.store(true, Ordering::Relaxed));
    }

    let mut editor = DefaultEditor::new()?;
    let history = dirs_history();
    if let Some(path) = &history {
        let _ = editor.load_history(path);
    }

    let mut messages: Vec<Value> = Vec::new();
    if let Some(system) = &settings.system {
        messages.push(json!({ "role": "system", "content": system }));
    }
    let mut last: Option<Turn> = None;

    println!(
        "{}  {}  {}",
        style.bold("Causewaybay Jarvis"),
        style.dim("/help for commands, Ctrl-D to quit"),
        style.dim(&format!("[{}]", client.addr))
    );

    loop {
        let prompt = if style.is_enabled() {
            "\x1b[36myou ›\x1b[0m "
        } else {
            "you > "
        };
        let line = match editor.readline(prompt) {
            Ok(line) => line,
            Err(ReadlineError::Interrupted) => {
                println!("{}", style.dim("  (Ctrl-D to quit)"));
                continue;
            }
            Err(ReadlineError::Eof) => break,
            Err(e) => return Err(e.into()),
        };
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let _ = editor.add_history_entry(line);

        if let Some(rest) = line.strip_prefix('/') {
            match command(rest, &mut messages, &mut settings, last.as_ref(), style) {
                Ok(true) => break,
                Ok(false) => {}
                Err(e) => println!("{} {e}", style.red("error:")),
            }
            continue;
        }

        messages.push(json!({ "role": "user", "content": line }));
        interrupt.store(false, Ordering::Relaxed);
        match stream_turn(client, &messages, &settings, style, Some(&interrupt)) {
            Ok(turn) => {
                if turn.interrupted {
                    interrupt.store(false, Ordering::Relaxed);
                    println!("{}", style.dim("  (interrupted)"));
                }
                messages.push(json!({ "role": "assistant", "content": turn.text }));
                last = Some(turn);
                println!();
            }
            Err(e) => {
                // The user's line stays out of the transcript: a turn that
                // never happened should not be remembered as one.
                messages.pop();
                println!("{} {e}", style.red("error:"));
            }
        }
    }

    if let Some(path) = &history {
        let _ = editor.save_history(path);
    }
    println!("{}", style.dim("bye"));
    Ok(())
}

const HELP: &str = "\
  /help              this list
  /reset             forget the conversation
  /think on|off      ask the server for a reasoning block, or not
  /effort low|medium|xhigh
  /temp <t>          sampling temperature (0 = greedy)
  /max <n>           cap on generated tokens
  /system <text>     replace the system prompt
  /show              show or hide the reasoning stream
  /stats             the last turn: pieces, time, model
  /save <path>       write the transcript as JSON
  /load <path>       read one back
  /model             which brain the server is answering with
  /exit              quit (Ctrl-D also works)";

/// Handle a `/command`. Returns true to quit.
fn command(
    input: &str,
    messages: &mut Vec<Value>,
    settings: &mut Settings,
    last: Option<&Turn>,
    style: Style,
) -> Result<bool> {
    let (name, rest) = input.split_once(' ').unwrap_or((input, ""));
    let rest = rest.trim();
    match name {
        "help" | "?" => println!("{HELP}"),
        "exit" | "quit" | "q" => return Ok(true),
        "reset" => {
            messages.retain(|m| m["role"] == "system");
            println!("{}", style.dim("  conversation cleared"));
        }
        "think" => {
            settings.think = match rest {
                "on" | "" => true,
                "off" => false,
                other => anyhow::bail!("expected on or off, got `{other}`"),
            };
            println!(
                "{}",
                style.dim(&format!("  thinking {}", on_off(settings.think)))
            );
        }
        "show" => {
            settings.show_thinking = !settings.show_thinking;
            println!(
                "{}",
                style.dim(&format!(
                    "  reasoning stream {}",
                    on_off(settings.show_thinking)
                ))
            );
        }
        "effort" => {
            anyhow::ensure!(
                matches!(rest, "low" | "medium" | "xhigh"),
                "want low, medium or xhigh"
            );
            settings.effort = rest.to_string();
            println!("{}", style.dim(&format!("  reasoning effort {rest}")));
        }
        "temp" | "temperature" => {
            let value: f32 = rest.parse().context("temperature must be a number")?;
            settings.temperature = Some(value);
            println!("{}", style.dim(&format!("  temperature {value}")));
        }
        "max" | "max_tokens" => {
            let value: usize = rest.parse().context("max tokens must be a whole number")?;
            anyhow::ensure!(value >= 1, "max tokens must be at least 1");
            settings.max_tokens = Some(value);
            println!("{}", style.dim(&format!("  max tokens {value}")));
        }
        "system" => {
            anyhow::ensure!(!rest.is_empty(), "give the system prompt after /system");
            messages.retain(|m| m["role"] != "system");
            messages.insert(0, json!({ "role": "system", "content": rest }));
            settings.system = Some(rest.to_string());
            println!("{}", style.dim("  system prompt replaced"));
        }
        "stats" => match last {
            Some(turn) => println!("{}", format_stats(turn, style)),
            None => println!("{}", style.dim("  nothing generated yet")),
        },
        "save" => {
            anyhow::ensure!(!rest.is_empty(), "give a path after /save");
            std::fs::write(rest, serde_json::to_string_pretty(messages)?)?;
            println!(
                "{}",
                style.dim(&format!("  {} messages written to {rest}", messages.len()))
            );
        }
        "load" => {
            anyhow::ensure!(!rest.is_empty(), "give a path after /load");
            let text = std::fs::read_to_string(rest)?;
            let loaded: Vec<Value> = serde_json::from_str(&text)?;
            *messages = loaded;
            println!(
                "{}",
                style.dim(&format!("  {} messages read from {rest}", messages.len()))
            );
        }
        "model" => println!(
            "{}",
            style.dim("  the server decides: `rustcli agent provider`, or F9 in the client")
        ),
        other => anyhow::bail!("unknown command `/{other}` — try /help"),
    }
    Ok(false)
}

fn on_off(value: bool) -> &'static str {
    if value {
        "on"
    } else {
        "off"
    }
}

fn dirs_history() -> Option<std::path::PathBuf> {
    let home = std::env::var("HOME").ok()?;
    let dir = std::path::PathBuf::from(home).join(".causewaybayjarvis");
    std::fs::create_dir_all(&dir).ok()?;
    Some(dir.join("rustcli_history"))
}
