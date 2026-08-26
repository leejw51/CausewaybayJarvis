//! The Qwen3.5 text tower: 64 decoder layers, three quarters of them linear.

use std::path::Path;

use anyhow::{Context, Result};
use mlx_rs::{ops, transforms, Array};

use crate::attention::Attention;
use crate::cache::{DeltaCache, KvCache, LayerCache};
use crate::config::{LayerKind, ModelConfig};
use crate::delta::GatedDeltaNet;
use crate::layers::{Embedding, Linear, Mlp, RmsNorm};
use crate::weights::Weights;

/// How many prompt tokens to push through in one forward pass. Bounds peak
/// memory on a long prompt; the delta layers are sequential either way.
pub const PREFILL_CHUNK: usize = 256;

#[derive(Debug)]
enum Mixer {
    Full(Attention),
    Linear(GatedDeltaNet),
}

#[derive(Debug)]
struct DecoderLayer {
    input_layernorm: RmsNorm,
    post_attention_layernorm: RmsNorm,
    mixer: Mixer,
    mlp: Mlp,
}

impl DecoderLayer {
    fn forward(&self, x: &Array, cache: &mut LayerCache) -> Result<Array> {
        let normed = self.input_layernorm.forward(x)?;
        let mixed = match (&self.mixer, cache) {
            (Mixer::Full(attn), LayerCache::Kv(c)) => attn.forward(&normed, c)?,
            (Mixer::Linear(delta), LayerCache::Delta(c)) => delta.forward(&normed, c)?,
            _ => unreachable!("layer and cache kinds are built together"),
        };
        let h = ops::add(x, &mixed)?;
        let out = self
            .mlp
            .forward(&self.post_attention_layernorm.forward(&h)?)?;
        Ok(ops::add(&h, &out)?)
    }

    fn nbytes(&self) -> u64 {
        self.input_layernorm.nbytes()
            + self.post_attention_layernorm.nbytes()
            + self.mlp.nbytes()
            + match &self.mixer {
                Mixer::Full(a) => a.nbytes(),
                Mixer::Linear(d) => d.nbytes(),
            }
    }
}

pub struct Model {
    embed_tokens: Embedding,
    layers: Vec<DecoderLayer>,
    norm: RmsNorm,
    /// `None` when the checkpoint ties the output projection to the embedding.
    lm_head: Option<Linear>,
    pub config: ModelConfig,
    weight_bytes: u64,
}

impl std::fmt::Debug for Model {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Model")
            .field("layers", &self.layers.len())
            .field("weight_bytes", &self.weight_bytes)
            .finish()
    }
}

impl Model {
    pub fn load(config_path: &Path, shards: &[impl AsRef<Path>]) -> Result<Self> {
        let config = ModelConfig::load(config_path)?;
        let mut w = Weights::load(shards).context("loading the checkpoint")?;
        Self::from_weights(config, &mut w)
    }

    pub fn from_weights(config: ModelConfig, w: &mut Weights) -> Result<Self> {
        let cfg = &config.text;
        let quant = config.quantization.as_ref();

        let embed_tokens = Embedding::load(w, "language_model.model.embed_tokens", quant)
            .context("loading the embedding table")?;

        let mut layers = Vec::with_capacity(cfg.num_hidden_layers);
        for i in 0..cfg.num_hidden_layers {
            let p = format!("language_model.model.layers.{i}");
            let mixer = match cfg.layer_kind(i) {
                LayerKind::Full => {
                    Mixer::Full(Attention::load(w, &format!("{p}.self_attn"), cfg, quant)?)
                }
                LayerKind::Linear => Mixer::Linear(GatedDeltaNet::load(
                    w,
                    &format!("{p}.linear_attn"),
                    cfg,
                    quant,
                )?),
            };
            layers.push(DecoderLayer {
                input_layernorm: RmsNorm::load(
                    w,
                    &format!("{p}.input_layernorm"),
                    cfg.rms_norm_eps,
                )?,
                post_attention_layernorm: RmsNorm::load(
                    w,
                    &format!("{p}.post_attention_layernorm"),
                    cfg.rms_norm_eps,
                )?,
                mixer,
                mlp: Mlp::load(w, &format!("{p}.mlp"), quant)?,
            });
        }

        let norm = RmsNorm::load(w, "language_model.model.norm", cfg.rms_norm_eps)?;
        let lm_head = if cfg.tie_word_embeddings {
            None
        } else {
            Some(Linear::load(w, "language_model.lm_head", quant)?)
        };

        let weight_bytes = embed_tokens.nbytes()
            + norm.nbytes()
            + lm_head.as_ref().map_or(0, |l| l.nbytes())
            + layers.iter().map(|l| l.nbytes()).sum::<u64>();

        Ok(Self {
            embed_tokens,
            layers,
            norm,
            lm_head,
            config,
            weight_bytes,
        })
    }

    pub fn make_cache(&self) -> Vec<LayerCache> {
        (0..self.layers.len())
            .map(|i| match self.config.text.layer_kind(i) {
                LayerKind::Full => LayerCache::Kv(KvCache::new()),
                LayerKind::Linear => LayerCache::Delta(DeltaCache::new()),
            })
            .collect()
    }

    pub fn weight_bytes(&self) -> u64 {
        self.weight_bytes
    }

    pub fn num_layers(&self) -> usize {
        self.layers.len()
    }

    /// Run `ids` (`[B, L]` int32) through the tower.
    ///
    /// With `last_only`, the output projection is applied to the final position
    /// alone — during prefill the other 248 320-wide rows are dead weight.
    pub fn forward(&self, ids: &Array, cache: &mut [LayerCache], last_only: bool) -> Result<Array> {
        let mut h = self.embed_tokens.forward(ids)?;
        for (layer, c) in self.layers.iter().zip(cache.iter_mut()) {
            h = layer.forward(&h, c)?;
        }
        let h = self.norm.forward(&h)?;

        let h = if last_only && h.shape()[1] > 1 {
            let l = h.shape()[1];
            ops::split_sections(&h, &[l - 1], 1)?.remove(1)
        } else {
            h
        };

        match &self.lm_head {
            Some(head) => head.forward(&h),
            None => self.embed_tokens.as_linear(&h),
        }
    }

    /// Feed a prompt in bounded chunks and return the logits for its last token.
    ///
    /// `on_chunk` is called with the number of tokens ingested so far.
    pub fn prefill(
        &self,
        ids: &[u32],
        cache: &mut [LayerCache],
        mut on_chunk: impl FnMut(usize),
    ) -> Result<Array> {
        assert!(!ids.is_empty(), "prefill needs at least one token");
        let mut logits = None;
        for (n, chunk) in ids.chunks(PREFILL_CHUNK).enumerate() {
            let arr = tokens_to_array(chunk);
            let out = self.forward(&arr, cache, true)?;
            transforms::eval([&out])?;
            logits = Some(out);
            on_chunk(((n + 1) * PREFILL_CHUNK).min(ids.len()));
        }
        Ok(logits.unwrap())
    }
}

/// `[u32] -> [1, L]` int32 array.
pub fn tokens_to_array(ids: &[u32]) -> Array {
    let as_i32: Vec<i32> = ids.iter().map(|&i| i as i32).collect();
    Array::from_slice(&as_i32, &[1, as_i32.len() as i32])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tokens_become_a_batch_of_one() {
        let a = tokens_to_array(&[1, 2, 3]);
        assert_eq!(a.shape(), &[1, 3]);
        assert_eq!(a.as_slice::<i32>(), &[1, 2, 3]);
    }
}
