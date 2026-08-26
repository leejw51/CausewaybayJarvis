//! End-to-end checks against the real 27B checkpoint.
//!
//! These load 15 GiB of weights, so they run under a custom harness: one load,
//! many checks, and a clean skip when the model is not on disk. Run them with
//!
//!     make test-model
//!
//! `JARVIS_TEST_MODEL=1` opts in; without it the file exits successfully after
//! saying why, so `cargo test` stays usable on a machine with no weights.

use std::time::Instant;

use rustcore::engine::{Engine, Event, Flow, GenerationConfig, StopReason};
use rustcore::{Message, RenderOptions};
use rustmlx::MlxEngine;

fn main() {
    if std::env::var("JARVIS_TEST_MODEL").is_err() {
        println!("skipping: set JARVIS_TEST_MODEL=1 (or run `make test-model`) to test against the real checkpoint");
        return;
    }

    let spec = match rustcore::models::resolve(
        &std::env::var("JARVIS_TEST_ALIAS").unwrap_or_else(|_| "qwen3.8:27b-mlx".into()),
        "main",
    ) {
        Ok(spec) => spec,
        Err(e) => {
            eprintln!("cannot resolve the model: {e:#}");
            std::process::exit(1);
        }
    };
    let files = match rustcore::hub::local(&spec) {
        Ok(files) => files,
        Err(_) => {
            println!(
                "skipping: {} is not downloaded — run `make model`",
                spec.repo
            );
            return;
        }
    };

    let started = Instant::now();
    let mut engine = MlxEngine::load_named(&files, Some(&spec.alias)).expect("loading the model");
    println!(
        "loaded {} in {:.1}s\n",
        spec.alias,
        started.elapsed().as_secs_f64()
    );

    /// One named check against the loaded engine.
    type Check = (&'static str, fn(&mut MlxEngine));

    let checks: &[Check] = &[
        ("reports what it loaded", reports_what_it_loaded),
        ("answers a factual question", answers_a_factual_question),
        (
            "greedy decoding is deterministic",
            greedy_decoding_is_deterministic,
        ),
        (
            "a seed makes sampling reproducible",
            a_seed_makes_sampling_reproducible,
        ),
        ("stops at the end of the turn", stops_at_the_end_of_the_turn),
        ("respects max_tokens", respects_max_tokens),
        ("the caller can interrupt", the_caller_can_interrupt),
        (
            "a follow-up turn reuses the cache",
            a_follow_up_turn_reuses_the_cache,
        ),
        ("reset clears the cache", reset_clears_the_cache),
        (
            "thinking is separated from the answer",
            thinking_is_separated_from_the_answer,
        ),
        (
            "the kernel matches the ops path",
            the_kernel_matches_the_ops_path,
        ),
    ];

    let mut failed = 0;
    for (name, check) in checks {
        let started = Instant::now();
        match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            engine.reset();
            check(&mut engine);
        })) {
            Ok(()) => println!("ok    {name}  ({:.1}s)", started.elapsed().as_secs_f64()),
            Err(_) => {
                failed += 1;
                println!("FAIL  {name}");
            }
        }
    }

    println!("\n{} checks, {failed} failed", checks.len());
    if failed > 0 {
        std::process::exit(1);
    }
}

// ---------------------------------------------------------------- helpers ---

/// Fast, quiet defaults: greedy, no reasoning block, short answers.
fn quick() -> GenerationConfig {
    GenerationConfig {
        max_tokens: 40,
        temperature: 0.0,
        ..Default::default()
    }
}

fn plain() -> RenderOptions {
    RenderOptions {
        enable_thinking: false,
        ..Default::default()
    }
}

fn ask(
    engine: &mut MlxEngine,
    question: &str,
    cfg: &GenerationConfig,
    opts: &RenderOptions,
) -> String {
    let prompt = engine
        .template()
        .render(&[Message::user(question)], opts)
        .expect("rendering the prompt");
    engine
        .generate(&prompt, cfg, &mut |_| Flow::Continue)
        .expect("generating")
        .text
}

// ----------------------------------------------------------------- checks ---

fn reports_what_it_loaded(engine: &mut MlxEngine) {
    let info = engine.info();
    assert!(
        info.architecture.contains("Qwen3_5"),
        "architecture: {}",
        info.architecture
    );
    assert!(
        info.quantization.contains("4-bit"),
        "quantization: {}",
        info.quantization
    );
    assert!(
        (24e9..32e9).contains(&(info.parameters as f64)),
        "parameter count looks wrong: {}",
        info.parameters
    );
    assert!(
        info.weight_bytes > 10 << 30,
        "weights: {}",
        info.weight_bytes
    );
    assert_eq!(engine.cached_tokens(), 0, "a fresh engine holds no cache");
}

fn answers_a_factual_question(engine: &mut MlxEngine) {
    let text = ask(
        engine,
        "What is the capital of France? Answer in one word.",
        &quick(),
        &plain(),
    );
    assert!(
        text.to_lowercase().contains("paris"),
        "unexpected answer: {text:?}"
    );
}

fn greedy_decoding_is_deterministic(engine: &mut MlxEngine) {
    let question = "Name the three primary colours.";
    let first = ask(engine, question, &quick(), &plain());
    engine.reset();
    let second = ask(engine, question, &quick(), &plain());
    assert_eq!(first, second, "temperature 0 must be reproducible");
}

fn a_seed_makes_sampling_reproducible(engine: &mut MlxEngine) {
    let cfg = GenerationConfig {
        temperature: 0.9,
        seed: Some(1234),
        max_tokens: 32,
        ..Default::default()
    };
    let question = "Invent a name for a coffee shop.";
    let first = ask(engine, question, &cfg, &plain());
    engine.reset();
    let second = ask(engine, question, &cfg, &plain());
    assert_eq!(first, second, "the same seed must give the same answer");

    engine.reset();
    let other = ask(
        engine,
        question,
        &GenerationConfig {
            seed: Some(4321),
            ..cfg
        },
        &plain(),
    );
    assert_ne!(first, other, "a different seed should explore differently");
}

fn stops_at_the_end_of_the_turn(engine: &mut MlxEngine) {
    let prompt = engine
        .template()
        .render(&[Message::user("Say the single word: done")], &plain())
        .unwrap();
    let cfg = GenerationConfig {
        max_tokens: 64,
        ..quick()
    };
    let completion = engine
        .generate(&prompt, &cfg, &mut |_| Flow::Continue)
        .expect("generating");
    assert_eq!(
        completion.stop_reason,
        StopReason::EndOfTurn,
        "got {:?}",
        completion.stop_reason
    );
    assert!(completion.stats.generated_tokens < 64);
}

fn respects_max_tokens(engine: &mut MlxEngine) {
    let cfg = GenerationConfig {
        max_tokens: 8,
        ..quick()
    };
    let prompt = engine
        .template()
        .render(
            &[Message::user("Count slowly from one to one hundred.")],
            &plain(),
        )
        .unwrap();
    let completion = engine
        .generate(&prompt, &cfg, &mut |_| Flow::Continue)
        .unwrap();
    assert_eq!(completion.stats.generated_tokens, 8);
    assert_eq!(completion.stop_reason, StopReason::Length);
}

fn the_caller_can_interrupt(engine: &mut MlxEngine) {
    let prompt = engine
        .template()
        .render(
            &[Message::user("Write a long essay about the sea.")],
            &plain(),
        )
        .unwrap();
    let mut seen = 0;
    let completion = engine
        .generate(
            &prompt,
            &GenerationConfig {
                max_tokens: 200,
                ..quick()
            },
            &mut |event| {
                if matches!(event, Event::Token(_)) {
                    seen += 1;
                    if seen >= 5 {
                        return Flow::Stop;
                    }
                }
                Flow::Continue
            },
        )
        .unwrap();
    assert_eq!(completion.stop_reason, StopReason::Interrupted);
    assert!(
        completion.stats.generated_tokens < 200,
        "stopped early, not at the cap"
    );
}

fn a_follow_up_turn_reuses_the_cache(engine: &mut MlxEngine) {
    // Keeping the reasoning block makes the second prompt a strict extension of
    // the first, which is the case the cache can reuse.
    let opts = RenderOptions {
        enable_thinking: false,
        preserve_thinking: true,
        ..Default::default()
    };
    let mut messages = vec![Message::user(
        "My favourite colour is teal. Acknowledge in three words.",
    )];

    let prompt = engine.template().render(&messages, &opts).unwrap();
    let first = engine
        .generate(&prompt, &quick(), &mut |_| Flow::Continue)
        .unwrap();
    messages.push(Message::assistant(first.text.clone()));
    messages.push(Message::user("What is my favourite colour? One word."));

    let cached_before = engine.cached_tokens();
    assert!(cached_before > 0, "the first turn should have left a cache");

    let prompt = engine.template().render(&messages, &opts).unwrap();
    let second = engine
        .generate(&prompt, &quick(), &mut |_| Flow::Continue)
        .unwrap();

    // The second prompt is longer, yet only its tail had to be read. Assert on
    // the token counts rather than on the clock: both turns are short enough
    // that wall time is mostly noise.
    assert_eq!(
        first.stats.cached_prompt_tokens, 0,
        "nothing to reuse on the first turn"
    );
    assert!(second.stats.prompt_tokens > first.stats.prompt_tokens);
    assert_eq!(
        second.stats.cached_prompt_tokens, cached_before,
        "the whole previous turn should have been reusable"
    );
    assert!(
        second.stats.prefill_tokens() * 2 < second.stats.prompt_tokens,
        "only {} of {} prompt tokens were reused",
        second.stats.cached_prompt_tokens,
        second.stats.prompt_tokens
    );
    assert!(
        second.text.to_lowercase().contains("teal"),
        "the model lost the conversation: {:?}",
        second.text
    );
}

fn reset_clears_the_cache(engine: &mut MlxEngine) {
    ask(
        engine,
        "Hello.",
        &GenerationConfig {
            max_tokens: 8,
            ..quick()
        },
        &plain(),
    );
    assert!(engine.cached_tokens() > 0);
    assert!(engine.cache_bytes() > 0);
    engine.reset();
    assert_eq!(engine.cached_tokens(), 0);
    assert_eq!(engine.cache_bytes(), 0);
}

fn thinking_is_separated_from_the_answer(engine: &mut MlxEngine) {
    let opts = RenderOptions {
        enable_thinking: true,
        reasoning_effort: "low".into(),
        ..Default::default()
    };
    let prompt = engine
        .template()
        .render(
            &[Message::user(
                "What is 17 times 3? Think briefly, then answer.",
            )],
            &opts,
        )
        .unwrap();

    let mut reasoning_chunks = 0;
    let mut answer_chunks = 0;
    let completion = engine
        .generate(
            &prompt,
            &GenerationConfig {
                max_tokens: 400,
                ..quick()
            },
            &mut |event| {
                match event {
                    Event::Reasoning(_) => reasoning_chunks += 1,
                    Event::Token(_) => answer_chunks += 1,
                    _ => {}
                }
                Flow::Continue
            },
        )
        .unwrap();

    assert!(reasoning_chunks > 0, "no reasoning was streamed");
    assert!(answer_chunks > 0, "no answer was streamed");
    assert!(
        completion.reasoning.is_some(),
        "the think block was not captured"
    );
    assert!(
        !completion.text.contains("<think>"),
        "tags leaked into the answer: {:?}",
        completion.text
    );
    assert!(
        !completion.text.contains("</think>"),
        "tags leaked into the answer: {:?}",
        completion.text
    );
    assert!(
        completion.text.contains("51"),
        "wrong answer: {:?}",
        completion.text
    );
}

fn the_kernel_matches_the_ops_path(engine: &mut MlxEngine) {
    let question = "List three prime numbers.";
    std::env::remove_var("JARVIS_DELTA_KERNEL");
    let with_kernel = ask(engine, question, &quick(), &plain());

    engine.reset();
    std::env::set_var("JARVIS_DELTA_KERNEL", "0");
    let with_ops = ask(engine, question, &quick(), &plain());
    std::env::remove_var("JARVIS_DELTA_KERNEL");

    // The two are not bit-identical and should not be asked to be: the kernel
    // accumulates the state in registers while the fallback rounds through
    // bfloat16 arrays between steps. Over a long greedy run that eventually
    // flips a near-tie, so what is checked is that they track each other for
    // essentially the whole answer.
    let shared = with_kernel
        .chars()
        .zip(with_ops.chars())
        .take_while(|(a, b)| a == b)
        .count();
    let shorter = with_kernel.chars().count().min(with_ops.chars().count());
    assert!(
        shorter > 0 && shared * 4 >= shorter * 3,
        "the Metal kernel and the array-ops fallback diverge after {shared} of {shorter} characters\n  kernel: {with_kernel:?}\n  ops:    {with_ops:?}"
    );
}
