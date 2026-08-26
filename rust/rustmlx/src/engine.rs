//! The MLX backend: loads a checkpoint and runs turns against it.

use std::path::Path;
use std::time::Instant;

use anyhow::{anyhow, Context, Result};
use mlx_rs::{transforms, Array, Dtype};
use rustcore::chat::ChatTemplate;
use rustcore::engine::{
    Completion, Engine, EngineInfo, Event, Flow, GenerationConfig, Stats, StopReason,
    ThinkingSplitter,
};
use rustcore::hub::ModelFiles;
use rustcore::tokenizer::{StreamDecoder, Tokenizer};

use crate::cache::LayerCache;
use crate::memory;
use crate::model::{tokens_to_array, Model};
use crate::sample::Sampler;

pub struct MlxEngine {
    model: Model,
    tokenizer: Tokenizer,
    template: ChatTemplate,
    cache: Vec<LayerCache>,
    /// Token ids already pushed through `cache`, so a follow-up turn that
    /// extends the same prompt does not re-run prefill from scratch.
    fed: Vec<u32>,
    info: EngineInfo,
}

impl std::fmt::Debug for MlxEngine {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("MlxEngine")
            .field("info", &self.info)
            .finish()
    }
}

impl MlxEngine {
    /// Load a checkpoint that is already on disk.
    pub fn load(files: &ModelFiles) -> Result<Self> {
        Self::load_named(files, None)
    }

    pub fn load_named(files: &ModelFiles, name: Option<&str>) -> Result<Self> {
        let model = Model::load(&files.config, &files.weights)?;
        let tokenizer = Tokenizer::load(&files.tokenizer, &files.root)?;
        let template = ChatTemplate::from_model_dir(&files.root)?;
        let cache = model.make_cache();

        let cfg = &model.config;
        let info = EngineInfo {
            model: name.unwrap_or(&cfg.model_type).to_string(),
            architecture: cfg
                .architectures
                .first()
                .cloned()
                .unwrap_or_else(|| cfg.model_type.clone()),
            quantization: match &cfg.quantization {
                Some(q) => format!("{}-bit affine (group {})", q.bits, q.group_size),
                None => "unquantized".to_string(),
            },
            parameters: cfg.text_parameters(),
            context_length: cfg.text.max_position_embeddings,
            weight_bytes: model.weight_bytes(),
        };

        Ok(Self {
            model,
            tokenizer,
            template,
            cache,
            fed: Vec::new(),
            info,
        })
    }

    /// Resolve a snapshot directory and load from it.
    pub fn from_dir(dir: &Path) -> Result<Self> {
        let files = rustcore::hub::resolve_files(dir)?;
        Self::load(&files)
    }

    pub fn tokenizer(&self) -> &Tokenizer {
        &self.tokenizer
    }

    pub fn template(&self) -> &ChatTemplate {
        &self.template
    }

    pub fn model(&self) -> &Model {
        &self.model
    }

    /// Bytes of key/value and recurrent state currently held.
    pub fn cache_bytes(&self) -> u64 {
        self.cache.iter().map(|c| c.nbytes()).sum()
    }

    /// How many tokens the live cache covers.
    pub fn cached_tokens(&self) -> usize {
        self.fed.len()
    }

    /// Pull one row of logits back to the host as float32.
    fn logits_row(logits: &Array) -> Result<Vec<f32>> {
        let row = logits.reshape(&[-1])?.as_dtype(Dtype::Float32)?;
        transforms::eval([&row])?;
        Ok(row.as_slice::<f32>().to_vec())
    }
}

/// Length of the longest common prefix.
fn shared_prefix(a: &[u32], b: &[u32]) -> usize {
    a.iter().zip(b).take_while(|(x, y)| x == y).count()
}

impl Engine for MlxEngine {
    fn info(&self) -> EngineInfo {
        self.info.clone()
    }

    fn reset(&mut self) {
        for c in &mut self.cache {
            c.reset();
        }
        self.fed.clear();
        memory::clear_cache();
    }

    fn generate(
        &mut self,
        prompt: &str,
        cfg: &GenerationConfig,
        on_event: &mut dyn FnMut(Event) -> Flow,
    ) -> Result<Completion> {
        let ids = self
            .tokenizer
            .encode(prompt)
            .context("tokenizing the prompt")?;
        if ids.is_empty() {
            return Err(anyhow!("the prompt is empty"));
        }

        // Reuse the cache only when this prompt is a strict extension of what it
        // already holds. Dropping an earlier `<think>` block from the history
        // breaks that, and then a full prefill is the only correct option.
        let shared = shared_prefix(&self.fed, &ids);
        let reuse = !self.fed.is_empty() && shared == self.fed.len() && shared < ids.len();
        if !reuse {
            self.reset();
        }
        let already = if reuse { shared } else { 0 };
        let todo: Vec<u32> = ids[already..].to_vec();

        memory::reset_peak();
        let started = Instant::now();
        let mut logits = self.model.prefill(&todo, &mut self.cache, |done| {
            on_event(Event::Prefill {
                done: already + done,
                total: ids.len(),
            });
        })?;
        let prefill_seconds = started.elapsed().as_secs_f64();
        self.fed = ids.clone();

        // The chat template leaves the assistant turn open inside `<think>`,
        // so whether we start in a reasoning block is visible in the prompt.
        let mut splitter = ThinkingSplitter::new(prompt.trim_end().ends_with("<think>"));
        let mut sampler = Sampler::new(cfg.clone());
        let mut decoder = StreamDecoder::new();
        let mut generated: Vec<u32> = Vec::new();
        let mut reasoning_tokens = 0usize;
        let mut stop_reason = StopReason::Length;

        let decode_started = Instant::now();
        for step in 0..cfg.max_tokens {
            let mut row = Self::logits_row(&logits)?;
            let id = sampler.sample(&mut row, &generated);

            if self.tokenizer.is_eos(id) {
                stop_reason = StopReason::EndOfTurn;
                break;
            }
            generated.push(id);

            let piece = decoder.push(&self.tokenizer, id)?;
            if !piece.is_empty() {
                let (reasoning, answer, closed) = splitter.push(&piece);
                if !reasoning.is_empty() && on_event(Event::Reasoning(reasoning)) == Flow::Stop {
                    stop_reason = StopReason::Interrupted;
                    break;
                }
                if closed {
                    reasoning_tokens = generated.len();
                    if on_event(Event::ReasoningDone) == Flow::Stop {
                        stop_reason = StopReason::Interrupted;
                        break;
                    }
                }
                if !answer.is_empty() && on_event(Event::Token(answer)) == Flow::Stop {
                    stop_reason = StopReason::Interrupted;
                    break;
                }
            }

            if step + 1 == cfg.max_tokens {
                break;
            }
            logits = self
                .model
                .forward(&tokens_to_array(&[id]), &mut self.cache, true)?;
            transforms::eval([&logits])?;
            self.fed.push(id);
        }
        let decode_seconds = decode_started.elapsed().as_secs_f64();

        // Flush anything the splitter was holding back.
        let tail = decoder.flush(&self.tokenizer)?;
        if !tail.is_empty() {
            let (reasoning, answer, _) = splitter.push(&tail);
            if !reasoning.is_empty() {
                on_event(Event::Reasoning(reasoning));
            }
            if !answer.is_empty() {
                on_event(Event::Token(answer));
            }
        }
        splitter.finish();
        let (reasoning, text) = splitter.into_parts();

        Ok(Completion {
            text,
            reasoning,
            stats: Stats {
                prompt_tokens: ids.len(),
                cached_prompt_tokens: already,
                generated_tokens: generated.len(),
                reasoning_tokens,
                prefill_seconds,
                decode_seconds,
                peak_memory: memory::peak(),
            },
            stop_reason,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_continued_conversation_shares_its_prefix() {
        assert_eq!(shared_prefix(&[1, 2, 3], &[1, 2, 3, 4, 5]), 3);
        assert_eq!(shared_prefix(&[1, 2, 3], &[1, 9, 3]), 1);
        assert_eq!(shared_prefix(&[], &[1]), 0);
    }
}
