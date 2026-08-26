//! The checkpoint's own Jinja chat template, checked against the built-in
//! ChatML renderer.
//!
//! These need a downloaded model, so each one returns early with a note when
//! the weights are not in the Hugging Face cache.

use rustcore::chat::{ChatTemplate, Message, RenderOptions, TemplateKind};
use rustcore::{hub, models};

/// The snapshot directory, or `None` when nothing is downloaded.
fn model_dir() -> Option<std::path::PathBuf> {
    let spec = models::resolve("qwen3.8:27b-mlx", "main").ok()?;
    hub::local(&spec).ok().map(|files| files.root)
}

macro_rules! model_dir_or_skip {
    () => {
        match model_dir() {
            Some(dir) => dir,
            None => {
                println!("skipping: no checkpoint in the Hugging Face cache — run `make model`");
                return;
            }
        }
    };
}

fn conversation() -> Vec<Message> {
    vec![
        Message::system("You are Jarvis."),
        Message::user("hello"),
        Message::assistant("hi there").with_reasoning("they greeted me"),
        Message::user("what is 2+2?"),
    ]
}

#[test]
fn the_shipped_template_loads_and_is_the_one_used() {
    let dir = model_dir_or_skip!();
    let template = ChatTemplate::from_model_dir(&dir).expect("loading the template");
    assert_eq!(
        template.kind,
        TemplateKind::Jinja,
        "the checkpoint ships a template, so the Jinja renderer should win"
    );
}

/// The built-in renderer exists so a checkpoint without a template still works.
/// It is only trustworthy while it agrees with the real one.
#[test]
fn the_builtin_renderer_matches_the_shipped_template() {
    let dir = model_dir_or_skip!();
    let jinja = ChatTemplate::from_model_dir(&dir).unwrap();
    let builtin = ChatTemplate::builtin();

    for effort in ["low", "medium", "xhigh"] {
        for thinking in [true, false] {
            for preserve in [true, false] {
                let opts = RenderOptions {
                    add_generation_prompt: true,
                    enable_thinking: thinking,
                    reasoning_effort: effort.into(),
                    preserve_thinking: preserve,
                    tools: None,
                };
                let a = jinja.render(&conversation(), &opts).unwrap();
                let b = builtin.render(&conversation(), &opts).unwrap();
                assert_eq!(
                    a, b,
                    "effort={effort} thinking={thinking} preserve={preserve}"
                );
            }
        }
    }
}

#[test]
fn a_generation_prompt_leaves_the_assistant_turn_open() {
    let dir = model_dir_or_skip!();
    let template = ChatTemplate::from_model_dir(&dir).unwrap();

    let thinking = template
        .render(&conversation(), &RenderOptions::default())
        .unwrap();
    assert!(
        thinking.ends_with("<|im_start|>assistant\n<think>\n"),
        "tail: {:?}",
        &thinking[thinking.len().saturating_sub(60)..]
    );

    let direct = template
        .render(
            &conversation(),
            &RenderOptions {
                enable_thinking: false,
                ..Default::default()
            },
        )
        .unwrap();
    assert!(
        direct.ends_with("<|im_start|>assistant\n<think>\n\n</think>\n\n"),
        "tail: {:?}",
        &direct[direct.len().saturating_sub(60)..]
    );
}

#[test]
fn the_effort_setting_reaches_the_system_block() {
    let dir = model_dir_or_skip!();
    let template = ChatTemplate::from_model_dir(&dir).unwrap();

    let low = template
        .render(
            &conversation(),
            &RenderOptions {
                reasoning_effort: "low".into(),
                ..Default::default()
            },
        )
        .unwrap();
    assert!(low.contains("Reasoning effort is set to low"), "{low}");

    let high = template
        .render(
            &conversation(),
            &RenderOptions {
                reasoning_effort: "xhigh".into(),
                ..Default::default()
            },
        )
        .unwrap();
    assert!(high.contains("Reasoning effort is set to xhigh"), "{high}");

    // With thinking off there is no reasoning instruction at all.
    let none = template
        .render(
            &conversation(),
            &RenderOptions {
                enable_thinking: false,
                ..Default::default()
            },
        )
        .unwrap();
    assert!(!none.contains("Reasoning effort"), "{none}");
}

#[test]
fn the_rendered_prompt_tokenizes_into_the_special_tokens() {
    let dir = model_dir_or_skip!();
    let spec = models::resolve("qwen3.8:27b-mlx", "main").unwrap();
    let files = hub::local(&spec).unwrap();
    let tokenizer = rustcore::Tokenizer::load(&files.tokenizer, &files.root).unwrap();
    let template = ChatTemplate::from_model_dir(&dir).unwrap();

    let prompt = template
        .render(&conversation(), &RenderOptions::default())
        .unwrap();
    let ids = tokenizer.encode(&prompt).unwrap();
    assert!(!ids.is_empty());

    // `<|im_start|>` must come through as one token, not as punctuation.
    let im_start = tokenizer
        .token_to_id("<|im_start|>")
        .expect("<|im_start|> in the vocabulary");
    assert!(
        ids.contains(&im_start),
        "the chat markers were not tokenized as special tokens"
    );

    // Round-tripping must give the prompt back unchanged.
    assert_eq!(tokenizer.decode(&ids).unwrap(), prompt);

    // The stop tokens the engine watches for have to exist.
    assert!(!tokenizer.eos_ids().is_empty());
    let im_end = tokenizer.token_to_id("<|im_end|>").unwrap();
    assert!(tokenizer.is_eos(im_end), "<|im_end|> should end a turn");
}

#[test]
fn a_tool_schema_reaches_the_prompt() {
    let dir = model_dir_or_skip!();
    let template = ChatTemplate::from_model_dir(&dir).unwrap();
    let tools = serde_json::json!([{
        "type": "function",
        "function": {
            "name": "get_balance",
            "description": "Read the wallet balance",
            "parameters": {"type": "object", "properties": {}}
        }
    }]);

    let prompt = template
        .render(
            &[Message::user("what is my balance?")],
            &RenderOptions {
                tools: Some(tools),
                ..Default::default()
            },
        )
        .unwrap();
    assert!(prompt.contains("<tools>"), "{prompt}");
    assert!(prompt.contains("get_balance"), "{prompt}");
    assert!(
        prompt.contains("<tool_call>"),
        "the calling convention is explained: {prompt}"
    );
}
