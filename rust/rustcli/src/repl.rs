//! The interactive chat loop and the streaming renderer both commands share.

use std::io::Write;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use anyhow::{Context, Result};
use rustcore::engine::{Completion, Engine, Event, Flow, StopReason};
use rustcore::models::ModelSpec;
use rustcore::{Message, Role};
use rustmlx::MlxEngine;
use rustyline::error::ReadlineError;
use rustyline::DefaultEditor;

use crate::ui::{human_bytes, StatusLine, Style};
use crate::Settings;

/// Run one turn, streaming it to stdout.
///
/// `interrupt` is polled between tokens so Ctrl-C stops a long answer without
/// killing the process.
pub fn stream_turn(
    engine: &mut MlxEngine,
    prompt: &str,
    settings: &Settings,
    style: Style,
    interrupt: Option<&Arc<AtomicBool>>,
) -> Result<Completion> {
    let mut line = StatusLine::new(style);
    let mut thinking_open = false;
    let mut wrote_answer = false;
    // Tracks how many newlines the reasoning stream already ended with, so the
    // gap before the answer is exactly one blank line however the model spaced it.
    let mut trailing_newlines = 0usize;

    let completion = engine.generate(prompt, &settings.generation, &mut |event| {
        if interrupt.is_some_and(|flag| flag.load(Ordering::Relaxed)) {
            return Flow::Stop;
        }
        match event {
            Event::Prefill { done, total } => {
                line.set(&format!(
                    "  {} reading {done}/{total} tokens",
                    style.dim("…")
                ));
            }
            Event::Reasoning(text) => {
                if !settings.show_thinking {
                    line.set(&format!("  {}", style.dim("thinking…")));
                    return Flow::Continue;
                }
                if !thinking_open {
                    line.clear();
                    print!("{}", style.dim("thinking\n"));
                    print!("{}", style.dim_on());
                    thinking_open = true;
                }
                print!("{text}");
                trailing_newlines = text.len() - text.trim_end_matches('\n').len();
                let _ = std::io::stdout().flush();
            }
            Event::ReasoningDone => {
                line.clear();
                if thinking_open {
                    print!(
                        "{}{}",
                        style.off(),
                        "\n".repeat(2usize.saturating_sub(trailing_newlines))
                    );
                    thinking_open = false;
                }
            }
            Event::Token(text) => {
                line.clear();
                if thinking_open {
                    print!(
                        "{}{}",
                        style.off(),
                        "\n".repeat(2usize.saturating_sub(trailing_newlines))
                    );
                    thinking_open = false;
                }
                print!("{text}");
                wrote_answer = true;
                let _ = std::io::stdout().flush();
            }
        }
        Flow::Continue
    })?;

    line.clear();
    if thinking_open {
        print!("{}", style.off());
    }
    if wrote_answer || thinking_open {
        println!();
    }
    let _ = std::io::stdout().flush();
    Ok(completion)
}

pub fn format_stats(c: &Completion, style: Style) -> String {
    let s = &c.stats;
    let mut parts = vec![format!(
        "{} prompt · {} generated · {:.1} tok/s",
        s.prompt_tokens,
        s.generated_tokens,
        s.decode_tps()
    )];
    if s.prefill_tokens() > 0 {
        parts.push(format!("prefill {:.0} tok/s", s.prefill_tps()));
    }
    if s.cached_prompt_tokens > 0 {
        parts.push(format!("{} cached", s.cached_prompt_tokens));
    }
    if s.reasoning_tokens > 0 {
        parts.push(format!("{} thinking", s.reasoning_tokens));
    }
    parts.push(human_bytes(s.peak_memory));
    if c.stop_reason != StopReason::EndOfTurn {
        parts.push(match c.stop_reason {
            StopReason::Length => "hit max_tokens".into(),
            StopReason::Interrupted => "interrupted".into(),
            StopReason::EndOfTurn => unreachable!(),
        });
    }
    style.dim(&format!("  {}", parts.join(" · ")))
}

const HELP: &str = "\
  /help              this list
  /reset             forget the conversation
  /think on|off      reasoning block on or off
  /effort low|medium|xhigh
  /temp <t>          sampling temperature (0 = greedy)
  /max <n>           cap on generated tokens
  /system <text>     replace the system prompt
  /show              show or hide the reasoning stream
  /stats             statistics for the last turn
  /save <path>       write the transcript as JSON
  /model             what is loaded
  /exit              quit (Ctrl-D also works)";

pub fn run(
    engine: &mut MlxEngine,
    mut settings: Settings,
    spec: &ModelSpec,
    style: Style,
) -> Result<()> {
    let interrupt = Arc::new(AtomicBool::new(false));
    {
        let flag = Arc::clone(&interrupt);
        // rustyline puts the terminal in raw mode while reading, so this only
        // fires during generation — which is exactly when we want it.
        let _ = ctrlc::set_handler(move || flag.store(true, Ordering::Relaxed));
    }

    let mut editor = DefaultEditor::new().context("starting the line editor")?;
    let history = dirs_history();
    if let Some(path) = &history {
        let _ = editor.load_history(path);
    }

    let mut messages: Vec<Message> = Vec::new();
    if let Some(system) = &settings.system {
        messages.push(Message::system(system.clone()));
    }
    let mut last: Option<Completion> = None;

    println!(
        "{}  {}",
        style.bold("Causewaybay Jarvis"),
        style.dim("/help for commands, Ctrl-D to quit")
    );

    loop {
        let prompt_label = if style.is_enabled() {
            "\x1b[36myou ›\x1b[0m "
        } else {
            "you > "
        };
        match editor.readline(prompt_label) {
            Ok(line) => {
                let line = line.trim();
                if line.is_empty() {
                    continue;
                }
                let _ = editor.add_history_entry(line);

                if let Some(rest) = line.strip_prefix('/') {
                    match command(
                        rest,
                        &mut settings,
                        &mut messages,
                        engine,
                        &last,
                        spec,
                        style,
                    ) {
                        Ok(true) => break,
                        Ok(false) => {}
                        Err(e) => println!("{} {e:#}", style.red("error:")),
                    }
                    continue;
                }

                messages.push(Message::user(line));
                let prompt = match engine.template().render(&messages, &settings.render) {
                    Ok(p) => p,
                    Err(e) => {
                        println!("{} {e:#}", style.red("error:"));
                        messages.pop();
                        continue;
                    }
                };

                interrupt.store(false, Ordering::Relaxed);
                match stream_turn(engine, &prompt, &settings, style, Some(&interrupt)) {
                    Ok(completion) => {
                        let mut reply = Message::assistant(completion.text.clone());
                        if let Some(r) = &completion.reasoning {
                            reply = reply.with_reasoning(r.clone());
                        }
                        messages.push(reply);
                        if completion.stop_reason == StopReason::Interrupted {
                            println!("{}", style.dim("  (interrupted)"));
                        }
                        last = Some(completion);
                        println!();
                    }
                    Err(e) => {
                        println!("{} {e:#}", style.red("error:"));
                        messages.pop();
                    }
                }
            }
            Err(ReadlineError::Interrupted) => {
                println!("{}", style.dim("  (Ctrl-D to quit)"));
            }
            Err(ReadlineError::Eof) => break,
            Err(e) => return Err(e).context("reading input"),
        }
    }

    if let Some(path) = &history {
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let _ = editor.save_history(path);
    }
    println!("{}", style.dim("bye"));
    Ok(())
}

/// Handle a `/command`. Returns `true` to quit.
#[allow(clippy::too_many_arguments)]
fn command(
    input: &str,
    settings: &mut Settings,
    messages: &mut Vec<Message>,
    engine: &mut MlxEngine,
    last: &Option<Completion>,
    spec: &ModelSpec,
    style: Style,
) -> Result<bool> {
    let (name, rest) = input.split_once(char::is_whitespace).unwrap_or((input, ""));
    let rest = rest.trim();

    match name {
        "help" | "?" => println!("{HELP}"),
        "exit" | "quit" | "q" => return Ok(true),
        "reset" => {
            let system = messages.first().filter(|m| m.role == Role::System).cloned();
            messages.clear();
            messages.extend(system);
            engine.reset();
            println!("{}", style.dim("  conversation cleared"));
        }
        "think" => {
            settings.render.enable_thinking = match rest {
                "on" | "" => true,
                "off" => false,
                other => anyhow::bail!("expected on or off, got `{other}`"),
            };
            println!(
                "{}",
                style.dim(&format!(
                    "  thinking {}",
                    on_off(settings.render.enable_thinking)
                ))
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
            rustcore::chat::reasoning_instructions(rest)?;
            settings.render.reasoning_effort = rest.to_string();
            println!("{}", style.dim(&format!("  reasoning effort {rest}")));
        }
        "temp" | "temperature" => {
            settings.generation.temperature =
                rest.parse().context("temperature must be a number")?;
            println!(
                "{}",
                style.dim(&format!(
                    "  temperature {}",
                    settings.generation.temperature
                ))
            );
        }
        "max" | "max_tokens" => {
            settings.generation.max_tokens =
                rest.parse().context("max tokens must be a whole number")?;
            println!(
                "{}",
                style.dim(&format!("  max tokens {}", settings.generation.max_tokens))
            );
        }
        "system" => {
            anyhow::ensure!(!rest.is_empty(), "give the system prompt after /system");
            settings.system = Some(rest.to_string());
            if messages.first().is_some_and(|m| m.role == Role::System) {
                messages[0] = Message::system(rest);
            } else {
                messages.insert(0, Message::system(rest));
            }
            engine.reset();
            println!("{}", style.dim("  system prompt replaced"));
        }
        "stats" => match last {
            Some(c) => println!("{}", format_stats(c, style)),
            None => println!("{}", style.dim("  nothing generated yet")),
        },
        "save" => {
            anyhow::ensure!(!rest.is_empty(), "give a path after /save");
            let json = serde_json::to_string_pretty(messages)?;
            std::fs::write(rest, json).with_context(|| format!("writing {rest}"))?;
            println!(
                "{}",
                style.dim(&format!("  {} messages written to {rest}", messages.len()))
            );
        }
        "model" => {
            let info = engine.info();
            println!("  {:<14} {}", "alias", spec.alias);
            println!("  {:<14} {}", "repository", spec.repo);
            println!("  {:<14} {}", "architecture", info.architecture);
            println!("  {:<14} {}", "quantization", info.quantization);
            println!("  {:<14} {}", "weights", human_bytes(info.weight_bytes));
            println!(
                "  {:<14} {} tokens, {}",
                "cache",
                engine.cached_tokens(),
                human_bytes(engine.cache_bytes())
            );
        }
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

/// `~/.config/jarvis/history` — best effort, absent is fine.
fn dirs_history() -> Option<std::path::PathBuf> {
    let home = std::env::var_os("HOME")?;
    Some(
        std::path::PathBuf::from(home)
            .join(".config")
            .join("jarvis")
            .join("history"),
    )
}
