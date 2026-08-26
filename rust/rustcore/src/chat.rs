//! Turning a conversation into the exact string the model was trained on.
//!
//! Two renderers live here. The default one runs the checkpoint's own
//! `chat_template.jinja` through minijinja, so we follow whatever the model
//! authors shipped. The second is a hand-written ChatML renderer for the Qwen3.5
//! family, used when a checkpoint has no template (or its template uses Jinja we
//! cannot evaluate). Both agree on the parts that matter — the tests pin that.

use std::path::Path;

use anyhow::{anyhow, Context, Result};
use minijinja::value::Value as JValue;
use minijinja::{context, Environment, Error as JError, ErrorKind};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    System,
    User,
    Assistant,
    Tool,
}

impl Role {
    pub fn as_str(self) -> &'static str {
        match self {
            Role::System => "system",
            Role::User => "user",
            Role::Assistant => "assistant",
            Role::Tool => "tool",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Message {
    pub role: Role,
    pub content: String,
    /// The `<think>` block, kept separate so it can be dropped from history.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reasoning_content: Option<String>,
}

impl Message {
    pub fn system(content: impl Into<String>) -> Self {
        Self {
            role: Role::System,
            content: content.into(),
            reasoning_content: None,
        }
    }
    pub fn user(content: impl Into<String>) -> Self {
        Self {
            role: Role::User,
            content: content.into(),
            reasoning_content: None,
        }
    }
    pub fn assistant(content: impl Into<String>) -> Self {
        Self {
            role: Role::Assistant,
            content: content.into(),
            reasoning_content: None,
        }
    }
    pub fn with_reasoning(mut self, reasoning: impl Into<String>) -> Self {
        self.reasoning_content = Some(reasoning.into());
        self
    }
}

#[derive(Debug, Clone)]
pub struct RenderOptions {
    /// Append `<|im_start|>assistant\n…` so the model continues as the assistant.
    pub add_generation_prompt: bool,
    /// Allow a `<think>` block. When false the template closes it immediately.
    pub enable_thinking: bool,
    /// `low` | `medium` | `xhigh`.
    pub reasoning_effort: String,
    /// Keep `<think>` blocks from earlier turns in the prompt.
    pub preserve_thinking: bool,
    /// OpenAI-style tool schemas, injected into the system block.
    pub tools: Option<serde_json::Value>,
}

impl Default for RenderOptions {
    fn default() -> Self {
        Self {
            add_generation_prompt: true,
            enable_thinking: true,
            reasoning_effort: "low".into(),
            preserve_thinking: false,
            tools: None,
        }
    }
}

/// Which renderer a [`ChatTemplate`] ended up using.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TemplateKind {
    /// The checkpoint's own Jinja template.
    Jinja,
    /// The built-in Qwen3.5 ChatML renderer.
    Builtin,
}

pub struct ChatTemplate {
    env: Option<Environment<'static>>,
    pub kind: TemplateKind,
}

impl std::fmt::Debug for ChatTemplate {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ChatTemplate")
            .field("kind", &self.kind)
            .finish()
    }
}

impl ChatTemplate {
    /// Load `chat_template.jinja`, or the `chat_template` field of
    /// `tokenizer_config.json`, from a model directory.
    pub fn from_model_dir(dir: &Path) -> Result<Self> {
        if let Some(src) = read_template_source(dir)? {
            match Self::from_source(src) {
                Ok(t) => return Ok(t),
                Err(e) => {
                    // A template we cannot evaluate is not fatal: ChatML is the
                    // format either way, and the built-in renderer knows it.
                    eprintln!("jarvis: chat template unusable ({e:?}); using the built-in ChatML renderer");
                }
            }
        }
        Ok(Self::builtin())
    }

    pub fn from_source(source: String) -> Result<Self> {
        let mut env = Environment::new();
        env.add_function(
            "raise_exception",
            |msg: String| -> std::result::Result<JValue, JError> {
                Err(JError::new(ErrorKind::InvalidOperation, msg))
            },
        );
        // Hugging Face templates are written against Python's `str`, so they
        // reach for `.startswith()`, `.strip()` and friends that Jinja has no
        // notion of. This callback provides them.
        env.set_unknown_method_callback(minijinja_contrib::pycompat::unknown_method_callback);
        env.set_keep_trailing_newline(true);
        env.add_template_owned("chat", source)
            .context("compiling the chat template")?;

        let tpl = Self {
            env: Some(env),
            kind: TemplateKind::Jinja,
        };
        // Smoke-render so a template we cannot evaluate is caught at load time,
        // not in the middle of the first turn.
        tpl.render(&[Message::user("hi")], &RenderOptions::default())
            .context("smoke-rendering the chat template")?;
        Ok(tpl)
    }

    pub fn builtin() -> Self {
        Self {
            env: None,
            kind: TemplateKind::Builtin,
        }
    }

    pub fn render(&self, messages: &[Message], opts: &RenderOptions) -> Result<String> {
        match &self.env {
            Some(env) => self.render_jinja(env, messages, opts),
            None => Ok(render_builtin(messages, opts)),
        }
    }

    fn render_jinja(
        &self,
        env: &Environment<'static>,
        messages: &[Message],
        opts: &RenderOptions,
    ) -> Result<String> {
        let msgs: Vec<serde_json::Value> = messages
            .iter()
            .map(|m| {
                let mut o = serde_json::Map::new();
                o.insert("role".into(), m.role.as_str().into());
                o.insert("content".into(), m.content.clone().into());
                if let Some(r) = &m.reasoning_content {
                    o.insert("reasoning_content".into(), r.clone().into());
                }
                serde_json::Value::Object(o)
            })
            .collect();

        let tmpl = env.get_template("chat")?;
        let out = tmpl.render(context! {
            messages => msgs,
            tools => opts.tools,
            add_generation_prompt => opts.add_generation_prompt,
            enable_thinking => opts.enable_thinking,
            reasoning_effort => opts.reasoning_effort,
            preserve_thinking => opts.preserve_thinking,
            add_vision_id => false,
        })?;
        Ok(out)
    }
}

fn read_template_source(dir: &Path) -> Result<Option<String>> {
    let jinja = dir.join("chat_template.jinja");
    if jinja.is_file() {
        return Ok(Some(std::fs::read_to_string(jinja)?));
    }
    let cfg = dir.join("tokenizer_config.json");
    if cfg.is_file() {
        let json: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(cfg)?)?;
        if let Some(s) = json.get("chat_template").and_then(|v| v.as_str()) {
            return Ok(Some(s.to_string()));
        }
    }
    Ok(None)
}

/// The reasoning-effort preamble Qwen3.5's own template injects.
pub fn reasoning_instructions(effort: &str) -> Result<&'static str> {
    match effort {
        "xhigh" => Ok("Reasoning effort is set to xhigh. Please think carefully through the task, validate key assumptions, consider plausible alternatives, and prioritize correctness, consistency, and clarity in the final answer."),
        "medium" => Ok(""),
        "low" => Ok("Reasoning effort is set to low. Keep your thinking brief and focused, moving directly to the conclusion without unnecessary elaboration."),
        other => Err(anyhow!("unexpected reasoning effort `{other}` (want low, medium or xhigh)")),
    }
}

/// Hand-written ChatML for the Qwen3.5 family. Mirrors the shipped template for
/// system/user/assistant turns; it does not implement the tool-call syntax.
fn render_builtin(messages: &[Message], opts: &RenderOptions) -> String {
    let preamble = if opts.enable_thinking {
        reasoning_instructions(&opts.reasoning_effort).unwrap_or("")
    } else {
        ""
    };

    let mut out = String::new();
    let mut rest = messages;

    // System block first, carrying the reasoning preamble.
    let sys = messages.first().filter(|m| m.role == Role::System);
    if let Some(sys) = sys {
        rest = &messages[1..];
        let content = sys.content.trim();
        if !content.is_empty() || !preamble.is_empty() {
            out.push_str("<|im_start|>system\n");
            if !preamble.is_empty() {
                out.push_str(preamble);
                if !content.is_empty() {
                    out.push_str("\n\n");
                }
            }
            out.push_str(content);
            out.push_str("<|im_end|>\n");
        }
    } else if !preamble.is_empty() {
        out.push_str("<|im_start|>system\n");
        out.push_str(preamble);
        out.push_str("<|im_end|>\n");
    }

    // Index of the last real user turn — reasoning from turns before it is
    // dropped unless the caller asked to keep it.
    let last_user = rest.iter().rposition(|m| m.role == Role::User).unwrap_or(0);

    for (i, m) in rest.iter().enumerate() {
        let content = m.content.trim();
        match m.role {
            Role::System => {} // only valid in first position; ignore strays
            Role::User => {
                out.push_str("<|im_start|>user\n");
                out.push_str(content);
                out.push_str("<|im_end|>\n");
            }
            Role::Assistant => {
                out.push_str("<|im_start|>assistant\n");
                let keep = opts.preserve_thinking || i > last_user;
                if keep {
                    out.push_str("<think>\n");
                    out.push_str(m.reasoning_content.as_deref().unwrap_or("").trim());
                    out.push_str("\n</think>\n\n");
                }
                out.push_str(content);
                out.push_str("<|im_end|>\n");
            }
            Role::Tool => {
                out.push_str("<|im_start|>user\n<tool_response>\n");
                out.push_str(content);
                out.push_str("\n</tool_response><|im_end|>\n");
            }
        }
    }

    if opts.add_generation_prompt {
        out.push_str("<|im_start|>assistant\n");
        out.push_str(if opts.enable_thinking {
            "<think>\n"
        } else {
            "<think>\n\n</think>\n\n"
        });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn convo() -> Vec<Message> {
        vec![
            Message::system("You are Jarvis."),
            Message::user("hello"),
            Message::assistant("hi there").with_reasoning("they greeted me"),
            Message::user("what is 2+2?"),
        ]
    }

    #[test]
    fn builtin_renders_chatml_with_a_generation_prompt() {
        let out = render_builtin(&convo(), &RenderOptions::default());
        assert!(out.starts_with("<|im_start|>system\n"));
        assert!(out.contains("You are Jarvis."));
        assert!(out.contains("<|im_start|>user\nwhat is 2+2?<|im_end|>\n"));
        assert!(out.ends_with("<|im_start|>assistant\n<think>\n"));
    }

    #[test]
    fn stale_reasoning_is_dropped_but_can_be_kept() {
        let dropped = render_builtin(&convo(), &RenderOptions::default());
        assert!(!dropped.contains("they greeted me"));

        let kept = render_builtin(
            &convo(),
            &RenderOptions {
                preserve_thinking: true,
                ..Default::default()
            },
        );
        assert!(kept.contains("they greeted me"));
    }

    #[test]
    fn thinking_off_closes_the_block_immediately() {
        let out = render_builtin(
            &convo(),
            &RenderOptions {
                enable_thinking: false,
                ..Default::default()
            },
        );
        assert!(out.ends_with("<|im_start|>assistant\n<think>\n\n</think>\n\n"));
        assert!(!out.contains("Reasoning effort"));
    }

    #[test]
    fn reasoning_effort_must_be_one_the_model_knows() {
        assert!(reasoning_instructions("low").is_ok());
        assert!(reasoning_instructions("turbo").is_err());
    }
}
