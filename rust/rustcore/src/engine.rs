//! The contract between a front end and an inference backend.
//!
//! A backend streams [`Event`]s; the caller returns a [`Flow`] to keep going or
//! stop early (Ctrl-C in the REPL, `q` in the TUI).

use std::time::Duration;

use serde::{Deserialize, Serialize};

use crate::config::{GenerationSettings, ThinkingConfig};

#[derive(Debug, Clone)]
pub struct GenerationConfig {
    pub max_tokens: usize,
    pub temperature: f32,
    pub top_p: f32,
    pub top_k: usize,
    pub min_p: f32,
    pub repetition_penalty: f32,
    pub repetition_context: usize,
    pub seed: Option<u64>,
}

impl Default for GenerationConfig {
    fn default() -> Self {
        GenerationSettings::default().into()
    }
}

impl From<GenerationSettings> for GenerationConfig {
    fn from(g: GenerationSettings) -> Self {
        Self {
            max_tokens: g.max_tokens,
            temperature: g.temperature,
            top_p: g.top_p,
            top_k: g.top_k,
            min_p: g.min_p,
            repetition_penalty: g.repetition_penalty,
            repetition_context: g.repetition_context,
            seed: g.seed,
        }
    }
}

/// What the caller wants after handling an event.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Flow {
    Continue,
    Stop,
}

#[derive(Debug, Clone)]
pub enum Event {
    /// Prompt processing: `done` of `total` tokens ingested.
    Prefill { done: usize, total: usize },
    /// A chunk of the `<think>` block.
    Reasoning(String),
    /// A chunk of the visible answer.
    Token(String),
    /// Emitted once, when `</think>` closes.
    ReasoningDone,
}

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize)]
pub struct Stats {
    pub prompt_tokens: usize,
    /// How many of `prompt_tokens` were already in the cache from an earlier
    /// turn and did not have to be read again.
    pub cached_prompt_tokens: usize,
    pub generated_tokens: usize,
    pub reasoning_tokens: usize,
    pub prefill_seconds: f64,
    pub decode_seconds: f64,
    /// Peak MLX allocation during the turn, in bytes.
    pub peak_memory: u64,
}

impl Stats {
    /// Prompt tokens that actually went through the model this turn.
    pub fn prefill_tokens(&self) -> usize {
        self.prompt_tokens.saturating_sub(self.cached_prompt_tokens)
    }

    pub fn prefill_tps(&self) -> f64 {
        if self.prefill_seconds > 0.0 {
            self.prefill_tokens() as f64 / self.prefill_seconds
        } else {
            0.0
        }
    }
    pub fn decode_tps(&self) -> f64 {
        if self.decode_seconds > 0.0 {
            self.generated_tokens as f64 / self.decode_seconds
        } else {
            0.0
        }
    }
    pub fn total(&self) -> Duration {
        Duration::from_secs_f64(self.prefill_seconds + self.decode_seconds)
    }
}

/// Why generation ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StopReason {
    /// The model emitted an end-of-sequence token.
    EndOfTurn,
    /// `max_tokens` was reached.
    Length,
    /// The caller returned [`Flow::Stop`].
    Interrupted,
}

#[derive(Debug, Clone)]
pub struct Completion {
    /// The visible answer, with the `<think>` block stripped out.
    pub text: String,
    /// The contents of the `<think>` block, if there was one.
    pub reasoning: Option<String>,
    pub stats: Stats,
    pub stop_reason: StopReason,
}

#[derive(Debug, Clone)]
pub struct EngineInfo {
    pub model: String,
    pub architecture: String,
    pub quantization: String,
    pub parameters: u64,
    pub context_length: usize,
    /// Resident weight size in bytes.
    pub weight_bytes: u64,
}

/// An inference backend.
pub trait Engine {
    fn info(&self) -> EngineInfo;

    /// Run one turn against an already-templated prompt string.
    fn generate(
        &mut self,
        prompt: &str,
        cfg: &GenerationConfig,
        on_event: &mut dyn FnMut(Event) -> Flow,
    ) -> anyhow::Result<Completion>;

    /// Drop any cached state so the next `generate` starts clean.
    fn reset(&mut self);
}

/// Splits a stream that starts inside a `<think>` block into reasoning and
/// answer, tolerating the tag arriving across several chunks.
#[derive(Debug)]
pub struct ThinkingSplitter {
    in_think: bool,
    /// Text held back because it might be a prefix of `</think>`.
    pending: String,
    pub reasoning: String,
    pub answer: String,
}

const CLOSE: &str = "</think>";

impl ThinkingSplitter {
    /// `in_think` mirrors whether the prompt ended with an open `<think>`.
    pub fn new(in_think: bool) -> Self {
        Self {
            in_think,
            pending: String::new(),
            reasoning: String::new(),
            answer: String::new(),
        }
    }

    pub fn from_thinking_config(t: &ThinkingConfig) -> Self {
        Self::new(t.enabled)
    }

    /// Feed a chunk; returns `(reasoning_chunk, answer_chunk, just_closed)`.
    pub fn push(&mut self, chunk: &str) -> (String, String, bool) {
        if !self.in_think {
            self.answer.push_str(chunk);
            return (String::new(), chunk.to_string(), false);
        }

        self.pending.push_str(chunk);
        if let Some(at) = self.pending.find(CLOSE) {
            let before = self.pending[..at].to_string();
            let after = self.pending[at + CLOSE.len()..].to_string();
            self.pending.clear();
            self.in_think = false;
            self.reasoning.push_str(&before);
            let after = after.trim_start_matches('\n').to_string();
            self.answer.push_str(&after);
            return (before, after, true);
        }

        // Hold back a tail that could still grow into `</think>`.
        let keep = longest_prefix_suffix(&self.pending, CLOSE);
        let emit_to = self.pending.len() - keep;
        let emit = self.pending[..emit_to].to_string();
        self.pending.drain(..emit_to);
        self.reasoning.push_str(&emit);
        (emit, String::new(), false)
    }

    /// Flush whatever was held back. Call once generation ends.
    pub fn finish(&mut self) -> (String, String) {
        let tail = std::mem::take(&mut self.pending);
        if self.in_think {
            self.reasoning.push_str(&tail);
            (tail, String::new())
        } else {
            self.answer.push_str(&tail);
            (String::new(), tail)
        }
    }

    pub fn into_parts(self) -> (Option<String>, String) {
        let reasoning = self.reasoning.trim();
        let reasoning = (!reasoning.is_empty()).then(|| reasoning.to_string());
        (reasoning, self.answer.trim().to_string())
    }
}

/// Length of the longest suffix of `text` that is a proper prefix of `needle`.
fn longest_prefix_suffix(text: &str, needle: &str) -> usize {
    // A held-back tail can be as long as the text itself, but never the whole
    // needle — a complete match is found by `find` before we get here.
    let max = text.len().min(needle.len() - 1);
    (1..=max)
        .rev()
        .find(|&n| text.is_char_boundary(text.len() - n) && text.ends_with(&needle[..n]))
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_close_tag_split_across_chunks_is_still_found() {
        let mut s = ThinkingSplitter::new(true);
        assert_eq!(s.push("let me think").0, "let me think");
        // `</th` must be held back, not printed as reasoning.
        assert_eq!(s.push("</th"), (String::new(), String::new(), false));
        let (reasoning, answer, closed) = s.push("ink>\n\n4");
        assert_eq!(reasoning, "");
        assert_eq!(answer, "4");
        assert!(closed);

        s.finish();
        let (reasoning, answer) = s.into_parts();
        assert_eq!(reasoning.as_deref(), Some("let me think"));
        assert_eq!(answer, "4");
    }

    #[test]
    fn without_thinking_everything_is_the_answer() {
        let mut s = ThinkingSplitter::new(false);
        assert_eq!(s.push("hello").1, "hello");
        s.finish();
        let (reasoning, answer) = s.into_parts();
        assert!(reasoning.is_none());
        assert_eq!(answer, "hello");
    }

    #[test]
    fn an_unterminated_think_block_is_all_reasoning() {
        let mut s = ThinkingSplitter::new(true);
        s.push("still going</th");
        s.finish();
        let (reasoning, answer) = s.into_parts();
        assert_eq!(reasoning.as_deref(), Some("still going</th"));
        assert_eq!(answer, "");
    }

    #[test]
    fn throughput_counts_only_the_tokens_that_were_actually_read() {
        let stats = Stats {
            prompt_tokens: 100,
            cached_prompt_tokens: 80,
            prefill_seconds: 0.2,
            generated_tokens: 10,
            decode_seconds: 1.0,
            ..Default::default()
        };
        assert_eq!(stats.prefill_tokens(), 20);
        assert!(
            (stats.prefill_tps() - 100.0).abs() < 1e-6,
            "{}",
            stats.prefill_tps()
        );
        assert!((stats.decode_tps() - 10.0).abs() < 1e-6);
    }

    #[test]
    fn rates_are_zero_rather_than_infinite_when_no_time_passed() {
        let stats = Stats {
            prompt_tokens: 5,
            ..Default::default()
        };
        assert_eq!(stats.prefill_tps(), 0.0);
        assert_eq!(stats.decode_tps(), 0.0);
    }

    #[test]
    fn prefix_suffix_overlap() {
        assert_eq!(longest_prefix_suffix("abc</th", CLOSE), 4);
        assert_eq!(longest_prefix_suffix("abc", CLOSE), 0);
    }
}
