//! Reading a Qwen3.5 / Qwen3.8 `config.json`.
//!
//! The 27B checkpoint is a conditional-generation (vision+text) config, so the
//! text hyper-parameters live under `text_config` and every language weight is
//! prefixed `language_model.`. We only run the text tower.

use std::path::Path;

use anyhow::{anyhow, Context, Result};
use serde::Deserialize;

/// What a decoder layer does for attention.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LayerKind {
    /// Gated DeltaNet — linear attention with a recurrent state.
    Linear,
    /// Ordinary softmax attention with a KV cache.
    Full,
}

#[derive(Debug, Clone, Deserialize)]
pub struct RopeParams {
    #[serde(default = "default_theta", alias = "theta")]
    pub rope_theta: f32,
    #[serde(default = "default_partial")]
    pub partial_rotary_factor: f32,
}

fn default_theta() -> f32 {
    10_000_000.0
}
fn default_partial() -> f32 {
    0.25
}

impl Default for RopeParams {
    fn default() -> Self {
        Self {
            rope_theta: default_theta(),
            partial_rotary_factor: default_partial(),
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct TextConfig {
    #[serde(default)]
    pub model_type: String,
    pub hidden_size: i32,
    pub intermediate_size: i32,
    pub num_hidden_layers: usize,
    pub num_attention_heads: i32,
    pub num_key_value_heads: i32,
    #[serde(default)]
    pub head_dim: Option<i32>,
    #[serde(default = "default_eps")]
    pub rms_norm_eps: f32,
    pub vocab_size: i32,

    // Gated DeltaNet
    pub linear_num_value_heads: i32,
    pub linear_num_key_heads: i32,
    pub linear_key_head_dim: i32,
    pub linear_value_head_dim: i32,
    #[serde(default = "default_conv_kernel")]
    pub linear_conv_kernel_dim: i32,

    #[serde(default = "default_interval")]
    pub full_attention_interval: usize,
    /// Explicit per-layer schedule, when the checkpoint ships one.
    #[serde(default)]
    pub layer_types: Option<Vec<String>>,

    #[serde(default)]
    pub tie_word_embeddings: bool,
    #[serde(default)]
    pub attention_bias: bool,
    #[serde(default = "default_max_pos")]
    pub max_position_embeddings: usize,
    #[serde(default, alias = "rope_parameters")]
    pub rope: RopeParams,
}

fn default_eps() -> f32 {
    1e-6
}
fn default_conv_kernel() -> i32 {
    4
}
fn default_interval() -> usize {
    4
}
fn default_max_pos() -> usize {
    262_144
}

impl TextConfig {
    pub fn head_dim(&self) -> i32 {
        self.head_dim
            .unwrap_or(self.hidden_size / self.num_attention_heads)
    }

    /// Number of rotary dimensions — Qwen3.5 rotates only the first quarter.
    pub fn rope_dims(&self) -> i32 {
        (self.head_dim() as f32 * self.rope.partial_rotary_factor) as i32
    }

    /// What layer `i` does. Prefers the explicit schedule, falls back to
    /// "every `full_attention_interval`-th layer is full attention".
    pub fn layer_kind(&self, i: usize) -> LayerKind {
        if let Some(types) = &self.layer_types {
            if let Some(t) = types.get(i) {
                return if t == "full_attention" {
                    LayerKind::Full
                } else {
                    LayerKind::Linear
                };
            }
        }
        if (i + 1) % self.full_attention_interval == 0 {
            LayerKind::Full
        } else {
            LayerKind::Linear
        }
    }

    pub fn linear_key_dim(&self) -> i32 {
        self.linear_key_head_dim * self.linear_num_key_heads
    }
    pub fn linear_value_dim(&self) -> i32 {
        self.linear_value_head_dim * self.linear_num_value_heads
    }
    /// Width of the depthwise convolution: q, k and v concatenated.
    pub fn conv_dim(&self) -> i32 {
        self.linear_key_dim() * 2 + self.linear_value_dim()
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct QuantConfig {
    pub bits: i32,
    pub group_size: i32,
    #[serde(default)]
    pub mode: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
struct RawConfig {
    #[serde(default)]
    model_type: String,
    #[serde(default)]
    architectures: Vec<String>,
    #[serde(default)]
    text_config: Option<TextConfig>,
    // Checkpoints carry both spellings, sometimes at once.
    #[serde(default)]
    quantization: Option<QuantConfig>,
    #[serde(default)]
    quantization_config: Option<QuantConfig>,
}

#[derive(Debug, Clone)]
pub struct ModelConfig {
    pub model_type: String,
    pub architectures: Vec<String>,
    pub text: TextConfig,
    pub quantization: Option<QuantConfig>,
}

impl ModelConfig {
    pub fn load(path: &Path) -> Result<Self> {
        let text =
            std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
        Self::parse(&text)
    }

    pub fn parse(json: &str) -> Result<Self> {
        let raw: RawConfig = serde_json::from_str(json).context("parsing config.json")?;
        // Text-only checkpoints put the hyper-parameters at the top level.
        let text = match raw.text_config {
            Some(t) => t,
            None => {
                serde_json::from_str(json).context("config.json has no text hyper-parameters")?
            }
        };
        if !text.model_type.is_empty()
            && !text.model_type.starts_with("qwen3_5")
            && !raw.model_type.starts_with("qwen3_5")
        {
            return Err(anyhow!(
                "unsupported architecture `{}` — rustmlx implements qwen3_5 (Qwen3.5 / Qwen3.8)",
                raw.model_type
            ));
        }
        Ok(Self {
            model_type: raw.model_type,
            architectures: raw.architectures,
            text,
            quantization: raw.quantization.or(raw.quantization_config),
        })
    }

    /// Rough parameter count of the text tower, from the shapes in the config.
    pub fn text_parameters(&self) -> u64 {
        let c = &self.text;
        let h = c.hidden_size as u64;
        let embed = c.vocab_size as u64 * h * 2; // embed_tokens + lm_head
        let mlp = 3 * h * c.intermediate_size as u64;

        let hd = c.head_dim() as u64;
        let full = h * (c.num_attention_heads as u64 * hd * 2) // q_proj is gated: 2x
            + 2 * h * (c.num_key_value_heads as u64 * hd)
            + (c.num_attention_heads as u64 * hd) * h;

        let kd = c.linear_key_dim() as u64;
        let vd = c.linear_value_dim() as u64;
        let linear = h * (2 * kd + vd)         // in_proj_qkv
            + h * vd                            // in_proj_z
            + 2 * h * c.linear_num_value_heads as u64 // in_proj_a, in_proj_b
            + vd * h                            // out_proj
            + c.conv_dim() as u64 * c.linear_conv_kernel_dim as u64;

        let mut total = embed;
        for i in 0..c.num_hidden_layers {
            total += mlp
                + match c.layer_kind(i) {
                    LayerKind::Full => full,
                    LayerKind::Linear => linear,
                };
        }
        total
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const QWEN38_27B: &str = r#"{
      "model_type": "qwen3_5",
      "architectures": ["Qwen3_5ForConditionalGeneration"],
      "quantization": {"group_size": 64, "bits": 4, "mode": "affine"},
      "text_config": {
        "model_type": "qwen3_5_text",
        "hidden_size": 5120, "intermediate_size": 17408,
        "num_hidden_layers": 64, "num_attention_heads": 24,
        "num_key_value_heads": 4, "head_dim": 256, "rms_norm_eps": 1e-06,
        "vocab_size": 248320,
        "linear_num_value_heads": 48, "linear_num_key_heads": 16,
        "linear_key_head_dim": 128, "linear_value_head_dim": 128,
        "linear_conv_kernel_dim": 4, "full_attention_interval": 4,
        "tie_word_embeddings": false,
        "rope_parameters": {"rope_theta": 10000000, "partial_rotary_factor": 0.25}
      }
    }"#;

    #[test]
    fn reads_the_27b_text_config() {
        let cfg = ModelConfig::parse(QWEN38_27B).unwrap();
        assert_eq!(cfg.text.hidden_size, 5120);
        assert_eq!(cfg.text.head_dim(), 256);
        assert_eq!(cfg.text.rope_dims(), 64);
        assert_eq!(cfg.text.conv_dim(), 10240);
        assert_eq!(cfg.quantization.as_ref().unwrap().bits, 4);
    }

    #[test]
    fn every_fourth_layer_is_full_attention() {
        let cfg = ModelConfig::parse(QWEN38_27B).unwrap();
        let kinds: Vec<_> = (0..8).map(|i| cfg.text.layer_kind(i)).collect();
        assert_eq!(
            kinds,
            [
                LayerKind::Linear,
                LayerKind::Linear,
                LayerKind::Linear,
                LayerKind::Full,
                LayerKind::Linear,
                LayerKind::Linear,
                LayerKind::Linear,
                LayerKind::Full,
            ]
        );
        let full = (0..64)
            .filter(|&i| cfg.text.layer_kind(i) == LayerKind::Full)
            .count();
        assert_eq!(full, 16);
    }

    #[test]
    fn an_explicit_schedule_wins() {
        let mut cfg = ModelConfig::parse(QWEN38_27B).unwrap();
        cfg.text.layer_types = Some(vec!["full_attention".into(), "linear_attention".into()]);
        assert_eq!(cfg.text.layer_kind(0), LayerKind::Full);
        assert_eq!(cfg.text.layer_kind(1), LayerKind::Linear);
    }

    #[test]
    fn parameter_count_is_in_the_right_ballpark() {
        let cfg = ModelConfig::parse(QWEN38_27B).unwrap();
        let n = cfg.text_parameters();
        assert!((24e9..32e9).contains(&(n as f64)), "got {n}");
    }

    #[test]
    fn a_foreign_architecture_is_rejected() {
        let err = ModelConfig::parse(r#"{"model_type":"llama","hidden_size":1}"#).unwrap_err();
        assert!(
            format!("{err:#}").contains("qwen3_5") || format!("{err:#}").contains("text hyper")
        );
    }
}
