//! Qwen3.5 full attention.
//!
//! Two things set it apart from plain GQA: `q_proj` is twice as wide because it
//! also produces a sigmoid gate applied to the attention output, and only the
//! first quarter of each head is rotated (`partial_rotary_factor = 0.25`).

use anyhow::Result;
use mlx_rs::{fast, ops, Array};

use crate::cache::KvCache;
use crate::config::{QuantConfig, TextConfig};
use crate::layers::{Linear, RmsNorm};
use crate::weights::Weights;

#[derive(Debug)]
pub struct Attention {
    q_proj: Linear,
    k_proj: Linear,
    v_proj: Linear,
    o_proj: Linear,
    q_norm: RmsNorm,
    k_norm: RmsNorm,
    num_heads: i32,
    num_kv_heads: i32,
    rope_dims: i32,
    rope_base: f32,
    scale: f32,
}

impl Attention {
    pub fn load(
        w: &mut Weights,
        prefix: &str,
        cfg: &TextConfig,
        quant: Option<&QuantConfig>,
    ) -> Result<Self> {
        let head_dim = cfg.head_dim();
        Ok(Self {
            q_proj: Linear::load(w, &format!("{prefix}.q_proj"), quant)?,
            k_proj: Linear::load(w, &format!("{prefix}.k_proj"), quant)?,
            v_proj: Linear::load(w, &format!("{prefix}.v_proj"), quant)?,
            o_proj: Linear::load(w, &format!("{prefix}.o_proj"), quant)?,
            q_norm: RmsNorm::load(w, &format!("{prefix}.q_norm"), cfg.rms_norm_eps)?,
            k_norm: RmsNorm::load(w, &format!("{prefix}.k_norm"), cfg.rms_norm_eps)?,
            num_heads: cfg.num_attention_heads,
            num_kv_heads: cfg.num_key_value_heads,
            rope_dims: cfg.rope_dims(),
            rope_base: cfg.rope.rope_theta,
            scale: (head_dim as f32).powf(-0.5),
        })
    }

    pub fn forward(&self, x: &Array, cache: &mut KvCache) -> Result<Array> {
        let (b, l) = (x.shape()[0], x.shape()[1]);

        // q_proj emits [queries | gate] per head; split them apart.
        let qg = self
            .q_proj
            .forward(x)?
            .reshape(&[b, l, self.num_heads, -1])?;
        let halves = ops::split(&qg, 2, -1)?;
        let queries = self
            .q_norm
            .forward(&halves[0])?
            .transpose_axes(&[0, 2, 1, 3])?;
        let gate = halves[1].reshape(&[b, l, -1])?;

        let keys = self
            .k_norm
            .forward(
                &self
                    .k_proj
                    .forward(x)?
                    .reshape(&[b, l, self.num_kv_heads, -1])?,
            )?
            .transpose_axes(&[0, 2, 1, 3])?;
        let values = self
            .v_proj
            .forward(x)?
            .reshape(&[b, l, self.num_kv_heads, -1])?
            .transpose_axes(&[0, 2, 1, 3])?;

        let offset = cache.offset();
        let queries = fast::rope(
            &queries,
            self.rope_dims,
            false,
            self.rope_base,
            1.0,
            offset,
            None,
        )?;
        let keys = fast::rope(
            &keys,
            self.rope_dims,
            false,
            self.rope_base,
            1.0,
            offset,
            None,
        )?;
        let (keys, values) = cache.update(&keys, &values)?;

        // A single new token attends to everything, so it needs no mask; MLX's
        // "causal" mode already aligns a longer query block to the end of the
        // cached keys.
        let out = if l > 1 {
            fast::scaled_dot_product_attention(
                &queries,
                &keys,
                &values,
                self.scale,
                fast::ScaledDotProductAttentionMask::Causal,
            )?
        } else {
            fast::scaled_dot_product_attention(&queries, &keys, &values, self.scale, None)?
        };

        let out = out.transpose_axes(&[0, 2, 1, 3])?.reshape(&[b, l, -1])?;
        self.o_proj
            .forward(&ops::multiply(&out, ops::sigmoid(&gate)?)?)
    }

    pub fn nbytes(&self) -> u64 {
        self.q_proj.nbytes()
            + self.k_proj.nbytes()
            + self.v_proj.nbytes()
            + self.o_proj.nbytes()
            + self.q_norm.nbytes()
            + self.k_norm.nbytes()
    }
}
