//! `rusttui` — a full-screen terminal chat for Causewaybay Jarvis.
//!
//! Generation runs on the main thread and redraws from inside the streaming
//! callback. That keeps the whole program single-threaded — MLX would rather not
//! be driven from two — while still repainting on every token and staying
//! responsive to Esc.

mod app;
mod draw;

use std::time::Duration;

use anyhow::{Context, Result};
use app::{App, Kind};
use clap::Parser;
use ratatui::crossterm::event::{self, KeyCode, KeyEvent, KeyEventKind, KeyModifiers};
use ratatui::DefaultTerminal;
use rustcore::config::Config;
use rustcore::engine::{Engine, Event, Flow, GenerationConfig, StopReason};
use rustcore::{hub, models, Message, RenderOptions};
use rustmlx::MlxEngine;

#[derive(Parser, Debug)]
#[command(
    name = "rusttui",
    version,
    about = "Causewaybay Jarvis — full-screen chat"
)]
struct Cli {
    /// Model alias or Hugging Face repo.
    #[arg(short, long)]
    model: Option<String>,
    /// Path to `config.jsonl`.
    #[arg(long)]
    config: Option<std::path::PathBuf>,
    /// System prompt, overriding `config.jsonl`.
    #[arg(short, long)]
    system: Option<String>,
    /// Answer immediately, with no reasoning block.
    #[arg(long)]
    no_think: bool,
    /// Sampling temperature.
    #[arg(short, long)]
    temperature: Option<f32>,
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    let cfg = match &cli.config {
        Some(path) => Config::load(path)?,
        None => Config::discover(),
    };

    let mut model_cfg = cfg.model();
    if let Some(alias) = &cli.model {
        model_cfg.alias = alias.clone();
        model_cfg.repo = String::new();
    }
    let spec = models::from_config(&model_cfg)?;

    // Load before taking over the screen, so a download or an error is visible
    // as ordinary terminal output.
    let files = hub::local(&spec).with_context(|| {
        format!(
            "`{}` is not downloaded yet — run `rustcli pull` first",
            spec.repo
        )
    })?;
    eprintln!("loading {}…", spec.alias);
    let mut engine = MlxEngine::load_named(&files, Some(&spec.alias))?;

    let thinking = cfg.thinking();
    let mut generation: GenerationConfig = cfg.generation().into();
    if let Some(t) = cli.temperature {
        generation.temperature = t;
    }
    let render = RenderOptions {
        add_generation_prompt: true,
        enable_thinking: !cli.no_think && thinking.enabled,
        reasoning_effort: thinking.effort.clone(),
        preserve_thinking: true,
        tools: None,
    };
    rustcore::chat::reasoning_instructions(&render.reasoning_effort)?;

    let system = cli.system.or_else(|| cfg.system_prompt());
    let app = App::new(system, thinking.show);

    let mut terminal = ratatui::init();
    let result = event_loop(&mut terminal, &mut engine, app, render, generation);
    ratatui::restore();
    result
}

fn event_loop(
    terminal: &mut DefaultTerminal,
    engine: &mut MlxEngine,
    mut app: App,
    render: RenderOptions,
    generation: GenerationConfig,
) -> Result<()> {
    let info = engine.info();
    let mut render = render;

    while !app.should_quit {
        terminal.draw(|frame| draw::draw(frame, &mut app, &info))?;

        if !event::poll(Duration::from_millis(120))? {
            continue;
        }
        let event::Event::Key(key) = event::read()? else {
            continue;
        };
        if key.kind != KeyEventKind::Press {
            continue;
        }

        if let Some(text) = handle_key(&mut app, &mut render, key) {
            app.push_block(Kind::User, text.clone());
            app.messages.push(Message::user(text));
            let turn = run_turn(terminal, engine, &mut app, &render, &generation, &info);
            if let Err(e) = turn {
                app.push_block(Kind::Notice, format!("{e:#}"));
                app.messages.pop();
            }
            app.busy = false;
            app.status.clear();
        }
    }
    Ok(())
}

/// Handle one key. Returns the text to send when the user pressed Enter.
fn handle_key(app: &mut App, render: &mut RenderOptions, key: KeyEvent) -> Option<String> {
    let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
    match key.code {
        KeyCode::Char('c') if ctrl => app.should_quit = true,
        KeyCode::Char('d') if ctrl && app.input.is_empty() => app.should_quit = true,
        KeyCode::Char('r') if ctrl => {
            app.clear_conversation();
            app.status = "conversation cleared".into();
        }
        KeyCode::Char('t') if ctrl => {
            app.show_thinking = !app.show_thinking;
            app.status = format!(
                "reasoning {}",
                if app.show_thinking { "shown" } else { "hidden" }
            );
        }
        KeyCode::Char('k') if ctrl => {
            render.enable_thinking = !render.enable_thinking;
            app.status = format!(
                "thinking {}",
                if render.enable_thinking { "on" } else { "off" }
            );
        }
        KeyCode::Char('u') if ctrl => {
            app.input.clear();
            app.cursor = 0;
        }
        KeyCode::Char(c) if !ctrl => app.insert(c),
        KeyCode::Backspace => app.backspace(),
        KeyCode::Delete => app.delete(),
        KeyCode::Left => app.left(),
        KeyCode::Right => app.right(),
        KeyCode::Home => app.home(),
        KeyCode::End => app.end(),
        KeyCode::Up => app.history_prev(),
        KeyCode::Down => app.history_next(),
        KeyCode::PageUp => {
            let current = app.scroll.unwrap_or(u16::MAX);
            app.scroll = Some(current.saturating_sub(10));
        }
        // Scrolling down only means something once the user has scrolled up;
        // `None` is already pinned to the newest output.
        KeyCode::PageDown => {
            if let Some(v) = app.scroll {
                app.scroll = Some(v.saturating_add(10));
            }
        }
        KeyCode::Esc => app.scroll = None,
        KeyCode::Enter => {
            let text = app.take_input();
            if !text.is_empty() {
                app.status.clear();
                return Some(text);
            }
        }
        _ => {}
    }
    None
}

/// Stream one assistant turn, repainting as tokens arrive.
fn run_turn(
    terminal: &mut DefaultTerminal,
    engine: &mut MlxEngine,
    app: &mut App,
    render: &RenderOptions,
    generation: &GenerationConfig,
    info: &rustcore::engine::EngineInfo,
) -> Result<()> {
    let prompt = engine.template().render(&app.messages, render)?;
    app.busy = true;
    app.interrupt = false;
    app.status = "reading the prompt".into();

    let mut draw_error = None;
    let completion = engine.generate(&prompt, generation, &mut |event| {
        match event {
            Event::Prefill { done, total } => {
                app.status = format!("reading {done}/{total} tokens");
            }
            Event::Reasoning(text) => {
                app.status = "thinking".into();
                app.stream(Kind::Reasoning, &text);
            }
            Event::ReasoningDone => {
                app.trim_empty_tail();
                app.status = "answering".into();
            }
            Event::Token(text) => {
                app.status = "answering".into();
                app.stream(Kind::Answer, &text);
            }
        }

        if let Err(e) = terminal.draw(|frame| draw::draw(frame, app, info)) {
            draw_error = Some(e);
            return Flow::Stop;
        }
        // Esc interrupts; everything else waits its turn.
        if matches!(event::poll(Duration::from_millis(0)), Ok(true)) {
            if let Ok(event::Event::Key(key)) = event::read() {
                let quit =
                    key.modifiers.contains(KeyModifiers::CONTROL) && key.code == KeyCode::Char('c');
                if key.code == KeyCode::Esc || quit {
                    app.should_quit |= quit;
                    return Flow::Stop;
                }
            }
        }
        Flow::Continue
    })?;

    if let Some(e) = draw_error {
        return Err(e.into());
    }

    app.trim_empty_tail();
    let mut reply = Message::assistant(completion.text.clone());
    if let Some(reasoning) = &completion.reasoning {
        reply = reply.with_reasoning(reasoning.clone());
    }
    app.messages.push(reply);
    app.last_stats = Some(completion.stats);

    if completion.stop_reason == StopReason::Interrupted {
        app.push_block(Kind::Notice, "interrupted");
    } else if completion.stop_reason == StopReason::Length {
        app.push_block(Kind::Notice, "stopped at max_tokens");
    }
    Ok(())
}
