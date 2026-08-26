//! The small building blocks: quantized projections, embeddings, RMSNorm, MLP.

use anyhow::{anyhow, Result};
use mlx_rs::ops::indexing::take_axis;
use mlx_rs::{fast, nn, ops, Array, Dtype};

use crate::config::QuantConfig;
use crate::weights::Weights;

/// A `nn.Linear`, quantized or not.
///
/// MLX ships these checkpoints with `weight` packed into `u32` plus per-group
/// `scales`/`biases`; `quantized_matmul` consumes that triple directly, so the
/// weights never have to be expanded.
#[derive(Debug, Clone)]
pub enum Linear {
    Quantized {
        weight: Array,
        scales: Array,
        biases: Array,
        bias: Option<Array>,
        group_size: i32,
        bits: i32,
    },
    Dense {
        weight: Array,
        bias: Option<Array>,
    },
}

impl Linear {
    /// Load `{prefix}.weight` and, when present, its quantization triple.
    pub fn load(w: &mut Weights, prefix: &str, quant: Option<&QuantConfig>) -> Result<Self> {
        let weight = w.take(&format!("{prefix}.weight"))?;
        let bias = w.take(&format!("{prefix}.bias")).ok();

        let scales_key = format!("{prefix}.scales");
        if w.has(&scales_key) {
            let quant = quant.ok_or_else(|| {
                anyhow!("`{prefix}` is quantized but config.json has no quantization block")
            })?;
            return Ok(Linear::Quantized {
                weight,
                scales: w.take(&scales_key)?,
                biases: w.take(&format!("{prefix}.biases"))?,
                bias,
                group_size: quant.group_size,
                bits: quant.bits,
            });
        }
        Ok(Linear::Dense { weight, bias })
    }

    pub fn forward(&self, x: &Array) -> Result<Array> {
        let out = match self {
            Linear::Quantized {
                weight,
                scales,
                biases,
                group_size,
                bits,
                ..
            } => ops::quantized_matmul(x, weight, scales, biases, true, *group_size, *bits)?,
            Linear::Dense { weight, .. } => x.matmul(weight.t())?,
        };
        match self.bias() {
            Some(b) => Ok(ops::add(&out, b)?),
            None => Ok(out),
        }
    }

    fn bias(&self) -> Option<&Array> {
        match self {
            Linear::Quantized { bias, .. } | Linear::Dense { bias, .. } => bias.as_ref(),
        }
    }

    /// Bytes the weights occupy, for the memory report.
    pub fn nbytes(&self) -> u64 {
        let one = |a: &Array| a.nbytes() as u64;
        match self {
            Linear::Quantized {
                weight,
                scales,
                biases,
                bias,
                ..
            } => one(weight) + one(scales) + one(biases) + bias.as_ref().map_or(0, one),
            Linear::Dense { weight, bias } => one(weight) + bias.as_ref().map_or(0, one),
        }
    }
}

/// Token embedding table, quantized the same way the projections are.
#[derive(Debug)]
pub struct Embedding {
    inner: Linear,
}

impl Embedding {
    pub fn load(w: &mut Weights, prefix: &str, quant: Option<&QuantConfig>) -> Result<Self> {
        Ok(Self {
            inner: Linear::load(w, prefix, quant)?,
        })
    }

    /// `ids` is `[B, L]` of int32; the result is `[B, L, hidden]`.
    pub fn forward(&self, ids: &Array) -> Result<Array> {
        match &self.inner {
            Linear::Quantized {
                weight,
                scales,
                biases,
                group_size,
                bits,
                ..
            } => {
                // Gather the packed rows and their scales, then expand just those.
                let flat = ids.reshape(&[-1])?;
                let w = take_axis(weight, &flat, 0)?;
                let s = take_axis(scales, &flat, 0)?;
                let b = take_axis(biases, &flat, 0)?;
                let rows = ops::dequantize(&w, &s, &b, *group_size, *bits)?;
                let hidden = *rows.shape().last().unwrap();
                let mut shape: Vec<i32> = ids.shape().to_vec();
                shape.push(hidden);
                Ok(rows.reshape(&shape)?)
            }
            Linear::Dense { weight, .. } => {
                let flat = ids.reshape(&[-1])?;
                let rows = take_axis(weight, &flat, 0)?;
                let hidden = *rows.shape().last().unwrap();
                let mut shape: Vec<i32> = ids.shape().to_vec();
                shape.push(hidden);
                Ok(rows.reshape(&shape)?)
            }
        }
    }

    /// Use the embedding table as the output projection (tied weights).
    pub fn as_linear(&self, x: &Array) -> Result<Array> {
        self.inner.forward(x)
    }

    pub fn nbytes(&self) -> u64 {
        self.inner.nbytes()
    }
}

#[derive(Debug, Clone)]
pub struct RmsNorm {
    weight: Array,
    eps: f32,
}

impl RmsNorm {
    pub fn load(w: &mut Weights, prefix: &str, eps: f32) -> Result<Self> {
        Ok(Self {
            weight: w.take(&format!("{prefix}.weight"))?,
            eps,
        })
    }

    pub fn forward(&self, x: &Array) -> Result<Array> {
        Ok(fast::rms_norm(x, &self.weight, self.eps)?)
    }

    pub fn nbytes(&self) -> u64 {
        self.weight.nbytes() as u64
    }
}

/// RMSNorm without learned weights, used inside the DeltaNet on q and k.
pub fn rms_norm_unweighted(x: &Array, eps: f32) -> Result<Array> {
    let dim = *x.shape().last().unwrap();
    let ones = ops::ones_dtype(&[dim], x.dtype())?;
    Ok(fast::rms_norm(x, &ones, eps)?)
}

/// The gated RMSNorm at the DeltaNet output: `rms_norm(x) * silu(gate)`,
/// with the product taken in float32 like the reference implementation.
pub fn rms_norm_gated(x: &Array, gate: &Array, weight: &Array, eps: f32) -> Result<Array> {
    let normed = fast::rms_norm(x, weight, eps)?.as_dtype(Dtype::Float32)?;
    let gate = nn::silu(gate.as_dtype(Dtype::Float32)?)?;
    Ok(ops::multiply(&normed, &gate)?.as_dtype(x.dtype())?)
}

/// SwiGLU feed-forward: `down(silu(gate(x)) * up(x))`.
#[derive(Debug)]
pub struct Mlp {
    gate_proj: Linear,
    up_proj: Linear,
    down_proj: Linear,
}

impl Mlp {
    pub fn load(w: &mut Weights, prefix: &str, quant: Option<&QuantConfig>) -> Result<Self> {
        Ok(Self {
            gate_proj: Linear::load(w, &format!("{prefix}.gate_proj"), quant)?,
            up_proj: Linear::load(w, &format!("{prefix}.up_proj"), quant)?,
            down_proj: Linear::load(w, &format!("{prefix}.down_proj"), quant)?,
        })
    }

    pub fn forward(&self, x: &Array) -> Result<Array> {
        let gate = nn::silu(self.gate_proj.forward(x)?)?;
        let up = self.up_proj.forward(x)?;
        self.down_proj.forward(&ops::multiply(&gate, &up)?)
    }

    pub fn nbytes(&self) -> u64 {
        self.gate_proj.nbytes() + self.up_proj.nbytes() + self.down_proj.nbytes()
    }
}

/// Repeat each head `n` times along `axis`, the way grouped heads are expanded.
///
/// `[.., H, D] -> [.., H * n, D]` with head `i` landing at `n*i .. n*i+n`.
pub fn repeat_heads(x: &Array, n: i32, head_axis: i32) -> Result<Array> {
    if n == 1 {
        return Ok(x.clone());
    }
    Ok(ops::repeat_axis::<f32>(x.clone(), n, head_axis)?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn repeat_heads_groups_each_head_together() {
        // Two heads of width one: [[1], [2]] -> [[1], [1], [2], [2]].
        let x = Array::from_slice(&[1.0f32, 2.0], &[2, 1]);
        let out = repeat_heads(&x, 2, 0).unwrap();
        assert_eq!(out.shape(), &[4, 1]);
        assert_eq!(out.as_slice::<f32>(), &[1.0, 1.0, 2.0, 2.0]);
    }

    #[test]
    fn unweighted_rms_norm_scales_to_unit_rms() {
        let x = Array::from_slice(&[3.0f32, 4.0], &[1, 2]);
        let out = rms_norm_unweighted(&x, 1e-6).unwrap();
        let v = out.as_slice::<f32>();
        // rms([3,4]) = 3.5355 -> [0.8485, 1.1314]
        assert!((v[0] - 0.848_5).abs() < 1e-3, "{v:?}");
        assert!((v[1] - 1.131_4).abs() < 1e-3, "{v:?}");
    }
}
