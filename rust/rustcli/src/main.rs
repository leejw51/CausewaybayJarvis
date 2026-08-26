//! `rustcli` — the command line for Causewaybay Jarvis.
//!
//! Everything runs on this machine: `pull` fetches an MLX checkpoint from the
//! Hugging Face Hub once, and `chat` talks to it through Apple MLX. No network
//! is touched after the download.

mod repl;
mod ui;

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use anyhow::{Context, Result};
use clap::{Args, Parser, Subcommand};
use rustcore::config::Config;
use rustcore::engine::{Engine, Event, Flow, GenerationConfig};
use rustcore::hub::ModelFiles;
use rustcore::models::ModelSpec;
use rustcore::{hub, models, Message, RenderOptions};
use rustmlx::{memory, MlxEngine};

use ui::{bar, human_bytes, human_count, StatusLine, Style};

#[derive(Parser, Debug)]
#[command(
    name = "rustcli",
    version,
    about = "Causewaybay Jarvis — an on-device AI agent on Apple MLX",
    long_about = None,
)]
struct Cli {
    /// Model alias or Hugging Face repo, e.g. `qwen3.8:27b-mlx`.
    #[arg(short, long, global = true)]
    model: Option<String>,

    /// Path to `config.jsonl`.
    #[arg(long, global = true)]
    config: Option<PathBuf>,

    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Subcommand, Debug)]
enum Command {
    /// Interactive chat (the default).
    Chat(TurnArgs),
    /// Answer one prompt and exit.
    Run {
        #[command(flatten)]
        args: TurnArgs,
        /// The prompt. Reads stdin when omitted.
        prompt: Vec<String>,
    },
    /// Download the model without starting a chat.
    Pull,
    /// Show what is loaded and how big it is.
    Info,
    /// List the model aliases this build knows.
    Models,
    /// Measure prefill and decode throughput.
    Bench {
        /// Synthetic prompt length, in tokens.
        #[arg(long, default_value_t = 512)]
        prompt: usize,
        /// Tokens to generate.
        #[arg(long, default_value_t = 64)]
        tokens: usize,
    },
}

#[derive(Args, Debug, Clone, Default)]
struct TurnArgs {
    /// System prompt, overriding `config.jsonl`.
    #[arg(short, long)]
    system: Option<String>,
    /// Let the model reason in a `<think>` block first.
    #[arg(long)]
    think: bool,
    /// Answer immediately, with no reasoning block.
    #[arg(long, conflicts_with = "think")]
    no_think: bool,
    /// Reasoning effort: low, medium or xhigh.
    #[arg(long)]
    effort: Option<String>,
    /// Sampling temperature. 0 is greedy.
    #[arg(short, long)]
    temperature: Option<f32>,
    /// Cap on generated tokens.
    #[arg(long)]
    max_tokens: Option<usize>,
    /// Seed the sampler for a reproducible answer.
    #[arg(long)]
    seed: Option<u64>,
    /// Hide the reasoning stream.
    #[arg(long)]
    hide_thinking: bool,
}

/// Everything a turn needs, resolved from config plus the command line.
pub struct Settings {
    pub generation: GenerationConfig,
    pub render: RenderOptions,
    pub system: Option<String>,
    pub show_thinking: bool,
}

impl Settings {
    fn build(cfg: &Config, args: &TurnArgs) -> Result<Self> {
        let thinking = cfg.thinking();
        let mut generation: GenerationConfig = cfg.generation().into();
        if let Some(t) = args.temperature {
            generation.temperature = t;
        }
        if let Some(n) = args.max_tokens {
            generation.max_tokens = n;
        }
        if args.seed.is_some() {
            generation.seed = args.seed;
        }

        let enable_thinking = if args.no_think {
            false
        } else if args.think {
            true
        } else {
            thinking.enabled
        };
        let effort = args.effort.clone().unwrap_or(thinking.effort);
        // Fail here rather than inside the template on the first turn.
        rustcore::chat::reasoning_instructions(&effort)?;

        Ok(Self {
            generation,
            render: RenderOptions {
                add_generation_prompt: true,
                enable_thinking,
                reasoning_effort: effort,
                // Keeping earlier reasoning lets the cache be reused across
                // turns, which is worth far more than the tokens it costs.
                preserve_thinking: true,
                tools: None,
            },
            system: args.system.clone().or_else(|| cfg.system_prompt()),
            show_thinking: thinking.show && !args.hide_thinking,
        })
    }
}

fn main() {
    if let Err(err) = run() {
        let style = Style::detect();
        eprintln!("{} {err:#}", style.red("error:"));
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let cli = Cli::parse();
    let cfg = match &cli.config {
        Some(path) => Config::load(path)?,
        None => Config::discover(),
    };
    let style = Style::detect();

    let alias = cli
        .model
        .clone()
        .unwrap_or_else(|| cfg.model().alias.clone());
    let mut model_cfg = cfg.model();
    if cli.model.is_some() {
        model_cfg.alias = alias;
        // An explicit --model overrides the pinned repo too.
        model_cfg.repo = String::new();
    }
    let spec = models::from_config(&model_cfg)?;

    match cli.command.unwrap_or(Command::Chat(TurnArgs::default())) {
        Command::Models => {
            list_models(style);
            Ok(())
        }
        Command::Pull => {
            let files = ensure_model(&spec, style)?;
            println!(
                "{} {} ({} of weights)",
                style.green("ready:"),
                files.root.display(),
                human_bytes(files.weight_bytes())
            );
            Ok(())
        }
        Command::Info => info(&cfg, &spec, style),
        Command::Bench { prompt, tokens } => bench(&spec, style, prompt, tokens),
        Command::Run { args, prompt } => {
            let settings = Settings::build(&cfg, &args)?;
            let text = if prompt.is_empty() {
                std::io::read_to_string(std::io::stdin())?
            } else {
                prompt.join(" ")
            };
            let text = text.trim();
            anyhow::ensure!(
                !text.is_empty(),
                "nothing to answer — pass a prompt or pipe one in"
            );
            let mut engine = open(&spec, style)?;
            one_shot(&mut engine, &settings, text, style)
        }
        Command::Chat(args) => {
            let settings = Settings::build(&cfg, &args)?;
            let mut engine = open(&spec, style)?;
            repl::run(&mut engine, settings, &spec, style)
        }
    }
}

fn list_models(style: Style) {
    println!("{}", style.bold("aliases"));
    for (alias, repo) in models::known_aliases() {
        println!("  {:<24} {}", style.cyan(alias), style.dim(repo));
    }
    println!("\nAny Hugging Face `org/name` holding an MLX Qwen3.5 checkpoint also works.");
}

/// Download the checkpoint if it is not already in the Hugging Face cache.
fn ensure_model(spec: &ModelSpec, style: Style) -> Result<ModelFiles> {
    if let Ok(files) = hub::local(spec) {
        return Ok(files);
    }

    println!(
        "{} {} {}",
        style.yellow("pulling"),
        style.bold(&spec.repo),
        if spec.approx_gib > 0.0 {
            style.dim(&format!("(~{:.0} GiB)", spec.approx_gib))
        } else {
            String::new()
        }
    );
    if hub::token().is_none() {
        println!(
            "{}",
            style.dim("  no HF_TOKEN found — public repositories still work, gated ones do not")
        );
    }

    let line = Arc::new(Mutex::new(StatusLine::new(style)));
    let sink = Arc::clone(&line);
    let files = hub::fetch(spec, move |p| {
        let Ok(mut line) = sink.lock() else { return };
        let fraction = if p.bytes_total > 0 {
            p.bytes_done as f64 / p.bytes_total as f64
        } else {
            0.0
        };
        line.set(&format!(
            "  {} {:>6.1}%  {} / {}  {}",
            bar(fraction),
            fraction * 100.0,
            human_bytes(p.bytes_done),
            human_bytes(p.bytes_total),
            p.current.as_deref().unwrap_or("")
        ));
    })?;
    if let Ok(mut line) = line.lock() {
        line.clear();
    }
    Ok(files)
}

/// Resolve, download if needed, and load onto the GPU.
fn open(spec: &ModelSpec, style: Style) -> Result<MlxEngine> {
    let files = ensure_model(spec, style)?;
    let mut line = StatusLine::new(style);
    line.force(&format!("  loading {}…", style.bold(&spec.alias)));
    let started = std::time::Instant::now();
    let engine = MlxEngine::load_named(&files, Some(&spec.alias))
        .with_context(|| format!("loading {}", spec.repo))?;
    line.clear();

    let info = engine.info();
    println!(
        "{} {} · {} params · {} · loaded in {:.1}s",
        style.green("●"),
        style.bold(&info.model),
        human_count(info.parameters),
        info.quantization,
        started.elapsed().as_secs_f64()
    );
    Ok(engine)
}

fn info(cfg: &Config, spec: &ModelSpec, style: Style) -> Result<()> {
    let app = cfg.app();
    println!("{} {}", style.bold(&app.name), style.dim(&app.version));
    println!(
        "{:<18} {}",
        "config",
        cfg.source
            .as_ref()
            .map(|p| p.display().to_string())
            .unwrap_or_else(|| "<built in>".into())
    );
    println!("{:<18} {}", "alias", spec.alias);
    println!("{:<18} {}", "repository", spec.repo);
    println!("{:<18} {}", "revision", spec.revision);

    match hub::local(spec) {
        Ok(files) => {
            println!("{:<18} {}", "snapshot", files.root.display());
            println!("{:<18} {}", "shards", files.weights.len());
            println!("{:<18} {}", "on disk", human_bytes(files.weight_bytes()));

            let config = rustmlx::ModelConfig::load(&files.config)?;
            let text = &config.text;
            let full = (0..text.num_hidden_layers)
                .filter(|&i| text.layer_kind(i) == rustmlx::LayerKind::Full)
                .count();
            println!(
                "{:<18} {}",
                "architecture",
                config
                    .architectures
                    .first()
                    .map(String::as_str)
                    .unwrap_or("?")
            );
            println!(
                "{:<18} {}",
                "parameters",
                human_count(config.text_parameters())
            );
            println!(
                "{:<18} {} ({} full attention, {} gated DeltaNet)",
                "layers",
                text.num_hidden_layers,
                full,
                text.num_hidden_layers - full
            );
            println!("{:<18} {}", "hidden size", text.hidden_size);
            println!(
                "{:<18} {} heads / {} kv, head dim {}",
                "attention",
                text.num_attention_heads,
                text.num_key_value_heads,
                text.head_dim()
            );
            println!("{:<18} {}", "context", text.max_position_embeddings);
            println!("{:<18} {}", "vocabulary", text.vocab_size);
            match &config.quantization {
                Some(q) => println!(
                    "{:<18} {}-bit affine, group {}",
                    "quantization", q.bits, q.group_size
                ),
                None => println!("{:<18} none", "quantization"),
            }
        }
        Err(_) => println!(
            "{:<18} {}",
            "snapshot",
            style.yellow("not downloaded — run `rustcli pull`")
        ),
    }
    Ok(())
}

fn bench(spec: &ModelSpec, style: Style, prompt_tokens: usize, tokens: usize) -> Result<()> {
    let mut engine = open(spec, style)?;
    // A repetitive filler prompt: what matters is its length, not its content.
    let filler = "The quick brown fox jumps over the lazy dog. ".repeat(prompt_tokens);
    let ids = engine.tokenizer().encode(&filler)?;
    let prompt = engine
        .tokenizer()
        .decode(&ids[..prompt_tokens.min(ids.len())])?;

    let cfg = GenerationConfig {
        max_tokens: tokens,
        temperature: 0.0,
        ..Default::default()
    };
    let mut line = StatusLine::new(style);
    let completion = engine.generate(&prompt, &cfg, &mut |event| {
        match event {
            Event::Prefill { done, total } => line.set(&format!("  prefill {done}/{total}")),
            Event::Token(_) | Event::Reasoning(_) => line.set("  decoding…"),
            Event::ReasoningDone => {}
        }
        Flow::Continue
    })?;
    line.clear();

    let s = completion.stats;
    println!("{}", style.bold("throughput"));
    println!(
        "  prefill  {:>7.1} tok/s  ({} tokens in {:.2}s)",
        s.prefill_tps(),
        s.prompt_tokens,
        s.prefill_seconds
    );
    println!(
        "  decode   {:>7.1} tok/s  ({} tokens in {:.2}s)",
        s.decode_tps(),
        s.generated_tokens,
        s.decode_seconds
    );
    println!("  peak     {:>7}", human_bytes(s.peak_memory));
    println!(
        "  cache    {:>7}  for {} tokens",
        human_bytes(engine.cache_bytes()),
        engine.cached_tokens()
    );
    println!("  active   {:>7}", human_bytes(memory::active()));
    Ok(())
}

/// One prompt in, one answer out.
fn one_shot(engine: &mut MlxEngine, settings: &Settings, text: &str, style: Style) -> Result<()> {
    let mut messages = Vec::new();
    if let Some(system) = &settings.system {
        messages.push(Message::system(system.clone()));
    }
    messages.push(Message::user(text));

    let prompt = engine.template().render(&messages, &settings.render)?;
    let completion = repl::stream_turn(engine, &prompt, settings, style, None)?;
    if completion.stop_reason == rustcore::engine::StopReason::Length {
        eprintln!("{}", style.dim("(stopped at max_tokens)"));
    }
    Ok(())
}
