//! Loading and normalising safetensors shards.
//!
//! Checkpoints in the wild disagree about prefixes and about one tensor layout,
//! so everything is rewritten once at load time into a single naming scheme:
//! `language_model.model.…` / `language_model.lm_head.…`.

use std::collections::HashMap;
use std::path::Path;

use anyhow::{anyhow, Context, Result};
use mlx_rs::ops;
use mlx_rs::Array;

pub struct Weights {
    map: HashMap<String, Array>,
}

impl std::fmt::Debug for Weights {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Weights")
            .field("tensors", &self.map.len())
            .finish()
    }
}

impl Weights {
    pub fn load(shards: &[impl AsRef<Path>]) -> Result<Self> {
        let mut raw: HashMap<String, Array> = HashMap::new();
        for shard in shards {
            let path = shard.as_ref();
            let part = Array::load_safetensors(path)
                .with_context(|| format!("loading {}", path.display()))?;
            raw.extend(part);
        }
        if raw.is_empty() {
            return Err(anyhow!("no tensors found in the checkpoint"));
        }
        Ok(Self {
            map: sanitize(raw)?,
        })
    }

    pub fn get(&self, name: &str) -> Result<&Array> {
        self.map
            .get(name)
            .ok_or_else(|| anyhow!("checkpoint is missing `{name}`"))
    }

    pub fn take(&mut self, name: &str) -> Result<Array> {
        self.map
            .remove(name)
            .ok_or_else(|| anyhow!("checkpoint is missing `{name}`"))
    }

    pub fn has(&self, name: &str) -> bool {
        self.map.contains_key(name)
    }

    pub fn len(&self) -> usize {
        self.map.len()
    }

    pub fn is_empty(&self) -> bool {
        self.map.is_empty()
    }

    /// Names still unclaimed — useful for spotting a checkpoint we only half read.
    pub fn remaining(&self) -> impl Iterator<Item = &str> {
        self.map.keys().map(|s| s.as_str())
    }
}

/// True for tensors the text tower never touches.
fn is_dropped(key: &str) -> bool {
    key.starts_with("vision_tower.")
        || key.starts_with("model.visual.")
        || key.starts_with("visual.")
        // Multi-token-prediction head: a speculative-decoding extra we do not run.
        || key.contains("mtp.")
}

/// Rewrite one key into the canonical `language_model.…` namespace.
pub fn canonical_key(key: &str) -> String {
    if let Some(rest) = key.strip_prefix("model.language_model.") {
        format!("language_model.model.{rest}")
    } else if key.starts_with("language_model.") {
        key.to_string()
    } else {
        format!("language_model.{key}")
    }
}

fn sanitize(raw: HashMap<String, Array>) -> Result<HashMap<String, Array>> {
    let raw: HashMap<String, Array> = raw
        .into_iter()
        .filter(|(k, _)| !is_dropped(k))
        .map(|(k, v)| (canonical_key(&k), v))
        .collect();

    // A checkpoint straight from Hugging Face stores the depthwise convolution
    // as [C, 1, K] and its RMSNorm weights centred on zero. MLX wants [C, K, 1]
    // and weights centred on one. Checkpoints already converted for MLX (the
    // `mlx-community` ones) need neither fix — detect which we have.
    let needs_fix = raw
        .iter()
        .any(|(k, v)| k.ends_with("conv1d.weight") && v.shape().last().is_some_and(|&d| d != 1));
    if !needs_fix {
        return Ok(raw);
    }

    let mut out = HashMap::with_capacity(raw.len());
    for (k, v) in raw {
        let v = if k.ends_with("conv1d.weight") && v.shape().last().is_some_and(|&d| d != 1) {
            ops::move_axis(&v, 2, 1)?
        } else if v.ndim() == 1 && is_norm_weight(&k) {
            ops::add(&v, Array::from_f32(1.0))?
        } else {
            v
        };
        out.insert(k, v);
    }
    Ok(out)
}

fn is_norm_weight(key: &str) -> bool {
    const SUFFIXES: [&str; 5] = [
        ".input_layernorm.weight",
        ".post_attention_layernorm.weight",
        "model.norm.weight",
        ".q_norm.weight",
        ".k_norm.weight",
    ];
    SUFFIXES.iter().any(|s| key.ends_with(s))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keys_land_in_one_namespace() {
        assert_eq!(
            canonical_key("model.layers.0.mlp.up_proj.weight"),
            "language_model.model.layers.0.mlp.up_proj.weight"
        );
        assert_eq!(
            canonical_key("model.language_model.norm.weight"),
            "language_model.model.norm.weight"
        );
        assert_eq!(
            canonical_key("language_model.lm_head.weight"),
            "language_model.lm_head.weight"
        );
    }

    #[test]
    fn vision_and_mtp_tensors_are_dropped() {
        assert!(is_dropped("vision_tower.blocks.0.attn.qkv.weight"));
        assert!(is_dropped("model.visual.patch_embed.proj.weight"));
        assert!(is_dropped("model.mtp.layers.0.mlp.up_proj.weight"));
        assert!(!is_dropped("model.layers.0.linear_attn.conv1d.weight"));
    }

    #[test]
    fn norm_weights_are_recognised() {
        assert!(is_norm_weight(
            "language_model.model.layers.3.self_attn.q_norm.weight"
        ));
        assert!(is_norm_weight("language_model.model.norm.weight"));
        assert!(!is_norm_weight(
            "language_model.model.layers.0.linear_attn.norm.weight"
        ));
    }

    #[test]
    fn an_mlx_checkpoint_is_left_alone() {
        let mut raw = HashMap::new();
        raw.insert(
            "model.layers.0.linear_attn.conv1d.weight".to_string(),
            mlx_rs::ops::zeros::<f32>(&[8, 4, 1]).unwrap(),
        );
        raw.insert(
            "model.layers.0.input_layernorm.weight".to_string(),
            mlx_rs::ops::zeros::<f32>(&[8]).unwrap(),
        );
        let out = sanitize(raw).unwrap();
        let norm = &out["language_model.model.layers.0.input_layernorm.weight"];
        assert_eq!(
            norm.as_slice::<f32>()[0],
            0.0,
            "norms must not be shifted twice"
        );
    }

    #[test]
    fn a_hugging_face_checkpoint_is_converted() {
        let mut raw = HashMap::new();
        raw.insert(
            "model.layers.0.linear_attn.conv1d.weight".to_string(),
            mlx_rs::ops::zeros::<f32>(&[8, 1, 4]).unwrap(),
        );
        raw.insert(
            "model.layers.0.input_layernorm.weight".to_string(),
            mlx_rs::ops::zeros::<f32>(&[8]).unwrap(),
        );
        let out = sanitize(raw).unwrap();
        assert_eq!(
            out["language_model.model.layers.0.linear_attn.conv1d.weight"].shape(),
            &[8, 4, 1]
        );
        assert_eq!(
            out["language_model.model.layers.0.input_layernorm.weight"].as_slice::<f32>()[0],
            1.0
        );
    }
}
