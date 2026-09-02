//! The on-device brain: Qwen3.8-27B on Apple MLX, behind the harness.
//!
//! This is the other half of "local AI agent". The cloud path rents somebody
//! else's weights; this one runs the same checkpoint `rustcli` runs, on this
//! machine, and nothing about the pipeline changes — the harness routes,
//! retrieves, loops tools and remembers exactly as it does against ollama,
//! because the model sits behind the same [`crate::harness::Brain`] trait.
//!
//! Everything except the engine itself compiles unconditionally: the
//! `<tool_call>` parser and the message mapping are plain string work, and the
//! tests cover them on machines with no Metal at all. Only [`MlxBrain`] is
//! behind the `mlx` feature, because it drags in the whole MLX build.

use serde_json::Value;

#[cfg(feature = "mlx")]
use crate::ollama::Message;
use crate::ollama::{ToolCall, ToolCallFunction};

/// Was this binary built with the on-device engine at all?
pub const COMPILED: bool = cfg!(feature = "mlx");

/// Pull tool calls out of generated text.
///
/// The Qwen3.5 template instructs the model to ask for a function like this —
/// prose allowed before the block, nothing after:
///
/// ```text
/// <tool_call>
/// <function=write_note>
/// <parameter=title>
/// Reginald
/// </parameter>
/// </function>
/// </tool_call>
/// ```
///
/// Older checkpoints (and most cloud models) put a JSON object inside the
/// same `<tool_call>` tags instead, so both shapes are read. A block that
/// parses as neither is left in the text rather than half-obeyed — the
/// operator seeing a mangled tag is better than a tool running on arguments
/// the model did not quite say.
/// Is the text so far inside an unclosed tool-call block? A streaming
/// caller holds its tokens back while this is true, because what is
/// arriving is a call the harness will run, not prose for a reader.
pub fn in_tool_call(seen: &str) -> bool {
    for (open, close) in [
        ("<tool_call>", "</tool_call>"),
        ("<function=", "</function>"),
    ] {
        let opens = seen.matches(open).count();
        if opens > seen.matches(close).count() {
            return true;
        }
    }
    // A tag that is still being typed: `<tool_c` is not yet `<tool_call>`,
    // but it is not prose either.
    if let Some(tail) = seen.rsplit('<').next() {
        if seen.ends_with(&format!("<{tail}")) && !tail.contains('>') {
            for open in ["tool_call>", "function="] {
                if open.starts_with(tail) && !tail.is_empty() {
                    return true;
                }
            }
        }
    }
    false
}

pub fn parse_tool_calls(text: &str) -> (String, Vec<ToolCall>) {
    const OPEN: &str = "<tool_call>";
    const CLOSE: &str = "</tool_call>";

    let mut clean = String::with_capacity(text.len());
    let mut calls = Vec::new();
    let mut rest = text;

    while let Some(start) = rest.find(OPEN) {
        let Some(end) = rest[start..].find(CLOSE) else {
            break;
        };
        let inner = rest[start + OPEN.len()..start + end].trim();
        let parsed = if inner.starts_with("<function=") {
            parse_function_block(inner)
        } else {
            parse_json_block(inner)
        };
        match parsed {
            Some(call) => {
                clean.push_str(&rest[..start]);
                calls.push(call);
            }
            None => {
                // Not a call after all: keep the text, tags included.
                clean.push_str(&rest[..start + end + CLOSE.len()]);
            }
        }
        rest = &rest[start + end + CLOSE.len()..];
    }
    clean.push_str(rest);
    (clean.trim().to_string(), calls)
}

/// The template's own format: `<function=name>` holding `<parameter=key>`
/// blocks. Every value arrives as a string — a multi-line note body is the
/// normal case, not an escape problem — and the tools coerce numbers on
/// their side.
fn parse_function_block(inner: &str) -> Option<ToolCall> {
    let rest = inner.strip_prefix("<function=")?;
    let (name, mut rest) = rest.split_once('>')?;
    if name.is_empty() {
        return None;
    }
    let mut args = serde_json::Map::new();
    loop {
        rest = rest.trim_start();
        let Some(after) = rest.strip_prefix("<parameter=") else {
            break;
        };
        let (key, after) = after.split_once('>')?;
        let (value, after) = after.split_once("</parameter>")?;
        // The value owns the lines between the tags, not the newlines that
        // *are* the tags' own line breaks.
        let value = value.strip_prefix('\n').unwrap_or(value);
        let value = value.strip_suffix('\n').unwrap_or(value);
        args.insert(key.to_string(), Value::String(value.to_string()));
        rest = after;
    }
    if rest.trim() != "</function>" {
        return None;
    }
    Some(ToolCall {
        function: ToolCallFunction {
            name: name.to_string(),
            arguments: Value::Object(args),
        },
    })
}

/// The older shape: `{"name": …, "arguments": {…}}` between the tags.
fn parse_json_block(inner: &str) -> Option<ToolCall> {
    let obj = serde_json::from_str::<Value>(inner).ok()?;
    let name = obj.get("name")?.as_str()?.to_string();
    Some(ToolCall {
        function: ToolCallFunction {
            name,
            arguments: obj.get("arguments").cloned().unwrap_or(Value::Null),
        },
    })
}

/// One turn of our wire format, as the chat template wants it.
///
/// An assistant message that carried `tool_calls` is replayed with the same
/// `<tool_call>` blocks the model originally emitted, so the transcript the
/// template renders is the transcript the model actually produced.
#[cfg(feature = "mlx")]
fn to_core(messages: &[Message]) -> Vec<rustcore::Message> {
    use rustcore::chat::Role;
    messages
        .iter()
        .map(|m| {
            let role = match m.role.as_str() {
                "system" => Role::System,
                "assistant" => Role::Assistant,
                "tool" => Role::Tool,
                _ => Role::User,
            };
            let mut content = m.content.clone();
            for call in m.tool_calls.as_deref().unwrap_or(&[]) {
                if !content.is_empty() {
                    content.push_str("\n\n");
                }
                content.push_str(&format!("<tool_call>\n<function={}>\n", call.function.name));
                if let Value::Object(args) = call.function.args() {
                    for (key, value) in args {
                        let value = match value {
                            Value::String(s) => s,
                            other => other.to_string(),
                        };
                        content.push_str(&format!("<parameter={key}>\n{value}\n</parameter>\n"));
                    }
                }
                content.push_str("</function>\n</tool_call>");
            }
            rustcore::Message {
                role,
                content,
                reasoning_content: None,
            }
        })
        .collect()
}

#[cfg(feature = "mlx")]
pub use engine::MlxBrain;

#[cfg(feature = "mlx")]
mod engine {
    use std::sync::Mutex;

    use anyhow::{Context, Result};
    use serde_json::Value;

    use rustcore::engine::{Engine, Flow, GenerationConfig};
    use rustcore::{ModelSpec, RenderOptions};
    use rustmlx::MlxEngine;

    use crate::harness::Brain;
    use crate::ollama::{Message, Reply};

    /// The MLX engine, loaded once and kept.
    ///
    /// Loading is fifteen gigabytes onto the GPU and takes tens of seconds, so
    /// it happens on the first on-device turn rather than at boot — a session
    /// that stays on the cloud never pays for it. The engine lives for the
    /// life of the daemon, which is the whole reason `agentd listen` exists.
    pub struct MlxBrain {
        spec: ModelSpec,
        engine: Mutex<Option<MlxEngine>>,
    }

    impl MlxBrain {
        /// `alias` is an ollama-style name like `qwen3.8:27b-mlx`; empty
        /// picks the workspace default.
        pub fn new(alias: &str) -> Result<Self> {
            let alias = if alias.trim().is_empty() {
                rustcore::models::DEFAULT_ALIAS
            } else {
                alias.trim()
            };
            let spec = rustcore::models::resolve(alias, "main")?;
            Ok(Self {
                spec,
                engine: Mutex::new(None),
            })
        }

        pub fn alias(&self) -> &str {
            &self.spec.alias
        }

        /// Are the weights already on disk? This never downloads: a turn is
        /// not the moment to start a fifteen-gigabyte fetch, and `make model`
        /// is one command.
        pub fn weights_ready(&self) -> std::result::Result<(), String> {
            match rustcore::hub::local(&self.spec) {
                Ok(_) => Ok(()),
                Err(_) => Err(format!(
                    "weights for {} are not on disk — run `make model`",
                    self.spec.alias
                )),
            }
        }

        pub fn loaded(&self) -> bool {
            self.engine.lock().map(|e| e.is_some()).unwrap_or(false)
        }

        /// Load the engine now rather than on the first turn — what the
        /// client asks for at boot, so the wait is spent behind a boot
        /// screen instead of behind the first question. A no-op once loaded.
        pub fn warm(&self) -> Result<()> {
            let mut slot = self
                .engine
                .lock()
                .map_err(|_| anyhow::anyhow!("the engine mutex was poisoned"))?;
            self.ensure_loaded(&mut slot).map(|_| ())
        }

        fn ensure_loaded<'a>(&self, slot: &'a mut Option<MlxEngine>) -> Result<&'a mut MlxEngine> {
            if slot.is_none() {
                let files = rustcore::hub::local(&self.spec)
                    .with_context(|| self.weights_ready().err().unwrap_or_default())?;
                let engine = MlxEngine::load_named(&files, Some(&self.spec.alias))
                    .with_context(|| format!("loading {}", self.spec.repo))?;
                *slot = Some(engine);
            }
            Ok(slot.as_mut().expect("just filled"))
        }
    }

    impl MlxBrain {
        /// The one generation path, with an optional sink.
        ///
        /// `chat` and `chat_stream` differ only in whether anybody is
        /// listening, so they share this: the engine reports every token
        /// through a callback either way, and the callback is where a
        /// stream is fed and a stop is honoured.
        fn generate(
            &self,
            messages: &[Message],
            tools: &[Value],
            mut sink: Option<&mut crate::harness::Sink<'_>>,
        ) -> Result<Reply> {
            use crate::harness::Chunk;
            use rustcore::engine::Event;

            let mut slot = self
                .engine
                .lock()
                .map_err(|_| anyhow::anyhow!("the engine mutex was poisoned"))?;
            let engine = self.ensure_loaded(&mut slot)?;

            let core = super::to_core(messages);
            let opts = RenderOptions {
                add_generation_prompt: true,
                // Thinking off: an agent turn spends its budget on the answer
                // and the tools, the same trade the cloud path makes with
                // OLLAMA_THINK=low.
                enable_thinking: false,
                tools: (!tools.is_empty()).then(|| serde_json::json!(tools)),
                ..Default::default()
            };
            let prompt = engine.template().render(&core, &opts)?;

            let cfg = GenerationConfig {
                max_tokens: 700,
                ..Default::default()
            };
            // A tool call arrives as ordinary text that only means something
            // once its closing tag is in, so a token inside one is held back
            // rather than shown: the operator should never watch a raw
            // `<tool_call>` block type itself out across the screen.
            let mut seen = String::new();
            let completion = engine.generate(&prompt, &cfg, &mut |event| {
                let Some(sink) = sink.as_deref_mut() else {
                    return Flow::Continue;
                };
                let go = match &event {
                    Event::Token(text) => {
                        seen.push_str(text);
                        if super::in_tool_call(&seen) {
                            true
                        } else {
                            sink(Chunk::Token(text))
                        }
                    }
                    Event::Reasoning(text) => sink(Chunk::Reasoning(text)),
                    Event::Prefill { done, total } => sink(Chunk::Prefill {
                        done: *done,
                        total: *total,
                    }),
                    _ => true,
                };
                if go {
                    Flow::Continue
                } else {
                    Flow::Stop
                }
            })?;

            let (text, calls) = super::parse_tool_calls(&completion.text);
            let mut message = Message::assistant(text);
            if !calls.is_empty() {
                message.tool_calls = Some(calls);
            }
            Ok(Reply {
                message,
                done_reason: match completion.stop_reason {
                    rustcore::engine::StopReason::Length => "length".into(),
                    rustcore::engine::StopReason::Interrupted => "interrupted".into(),
                    _ => "stop".into(),
                },
            })
        }
    }

    impl Brain for MlxBrain {
        fn chat(&self, messages: &[Message], tools: &[Value]) -> Result<Reply> {
            self.generate(messages, tools, None)
        }

        fn chat_stream(
            &self,
            messages: &[Message],
            tools: &[Value],
            sink: &mut crate::harness::Sink<'_>,
        ) -> Result<Reply> {
            self.generate(messages, tools, Some(sink))
        }

        fn streams(&self) -> bool {
            true
        }

        fn label(&self) -> String {
            format!("{} (on-device)", self.spec.alias)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_templates_own_function_format_is_read() {
        let text = "I'll write that down.\n<tool_call>\n<function=write_note>\n\
                    <parameter=title>\nReginald\n</parameter>\n\
                    <parameter=body>\nThe starter.\nFed on Sundays.\n</parameter>\n\
                    </function>\n</tool_call>";
        let (clean, calls) = parse_tool_calls(text);
        assert_eq!(clean, "I'll write that down.");
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0].function.name, "write_note");
        let args = calls[0].function.args();
        assert_eq!(args["title"], "Reginald");
        // A multi-line value keeps its inner newlines and loses the tags' own.
        assert_eq!(args["body"], "The starter.\nFed on Sundays.");
    }

    #[test]
    fn a_function_block_missing_its_closing_tag_is_left_alone() {
        let text =
            "<tool_call>\n<function=write_note>\n<parameter=title>\nx\n</parameter>\n</tool_call>";
        let (clean, calls) = parse_tool_calls(text);
        assert!(calls.is_empty());
        assert_eq!(clean, text);
    }

    #[test]
    fn a_tool_call_block_becomes_a_call_and_leaves_the_prose() {
        let text = "Let me check.\n<tool_call>\n{\"name\": \"search_context\", \
                    \"arguments\": {\"query\": \"bones\"}}\n</tool_call>";
        let (clean, calls) = parse_tool_calls(text);
        assert_eq!(clean, "Let me check.");
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0].function.name, "search_context");
        assert_eq!(calls[0].function.args()["query"], "bones");
    }

    #[test]
    fn several_calls_in_one_answer_all_come_out_in_order() {
        let text = "<tool_call>{\"name\":\"a\",\"arguments\":{}}</tool_call>\
                    <tool_call>{\"name\":\"b\",\"arguments\":{\"n\":1}}</tool_call>done";
        let (clean, calls) = parse_tool_calls(text);
        assert_eq!(clean, "done");
        assert_eq!(calls.len(), 2);
        assert_eq!(calls[0].function.name, "a");
        assert_eq!(calls[1].function.name, "b");
    }

    #[test]
    fn a_mangled_block_stays_in_the_text_instead_of_half_running() {
        let text = "<tool_call>{not json}</tool_call> and on";
        let (clean, calls) = parse_tool_calls(text);
        assert!(calls.is_empty());
        assert_eq!(clean, "<tool_call>{not json}</tool_call> and on");

        let unclosed = "an answer <tool_call>{\"name\":\"x\"";
        let (clean2, calls2) = parse_tool_calls(unclosed);
        assert!(calls2.is_empty());
        assert_eq!(clean2, unclosed);
    }

    #[test]
    fn plain_prose_passes_through_untouched() {
        let (clean, calls) = parse_tool_calls("Simmer the bones for six hours.");
        assert!(calls.is_empty());
        assert_eq!(clean, "Simmer the bones for six hours.");
    }
}
