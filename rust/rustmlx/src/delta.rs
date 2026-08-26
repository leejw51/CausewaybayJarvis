//! Gated DeltaNet — the linear-attention layer that makes up three quarters of
//! Qwen3.5.
//!
//! Instead of a growing KV cache it carries a fixed `[heads, Dv, Dk]` matrix of
//! associations. Per position it decays that matrix by a learned gate, reads
//! back what the current key already retrieves, and writes in the difference
//! between that and the value — the *delta rule*:
//!
//! ```text
//! S  <- S * g
//! S  <- S + k ⊗ β(v - S k)
//! y   = S q
//! ```
//!
//! The recurrence is inherently sequential, so prefill walks the prompt one
//! position at a time. Every position's work is a handful of large elementwise
//! ops, which is why the state is kept in float32 and everything else in the
//! model's own dtype.

use anyhow::{anyhow, Result};
use mlx_rs::{nn, ops, Array, Dtype};

use crate::cache::DeltaCache;
use crate::config::{QuantConfig, TextConfig};
use crate::kernel::{MetalKernel, OutputSpec, TemplateArg};
use crate::layers::{rms_norm_gated, rms_norm_unweighted, Linear};
use crate::weights::Weights;

/// The reference implementation normalises q and k with a fixed epsilon that is
/// not the model's `rms_norm_eps`.
const QK_NORM_EPS: f32 = 1e-6;

#[derive(Debug)]
pub struct GatedDeltaNet {
    in_proj_qkv: Linear,
    in_proj_z: Linear,
    in_proj_b: Linear,
    in_proj_a: Linear,
    out_proj: Linear,
    /// Depthwise convolution weights, `[conv_dim, kernel, 1]`.
    conv_weight: Array,
    /// Log of the decay rates, one per value head.
    a_log: Array,
    dt_bias: Array,
    norm_weight: Array,
    eps: f32,

    num_v_heads: i32,
    num_k_heads: i32,
    head_k_dim: i32,
    head_v_dim: i32,
    key_dim: i32,
    conv_dim: i32,
    conv_kernel: i32,
}

impl GatedDeltaNet {
    pub fn load(
        w: &mut Weights,
        prefix: &str,
        cfg: &TextConfig,
        quant: Option<&QuantConfig>,
    ) -> Result<Self> {
        Ok(Self {
            in_proj_qkv: Linear::load(w, &format!("{prefix}.in_proj_qkv"), quant)?,
            in_proj_z: Linear::load(w, &format!("{prefix}.in_proj_z"), quant)?,
            in_proj_b: Linear::load(w, &format!("{prefix}.in_proj_b"), quant)?,
            in_proj_a: Linear::load(w, &format!("{prefix}.in_proj_a"), quant)?,
            out_proj: Linear::load(w, &format!("{prefix}.out_proj"), quant)?,
            conv_weight: w.take(&format!("{prefix}.conv1d.weight"))?,
            a_log: w.take(&format!("{prefix}.A_log"))?,
            dt_bias: w.take(&format!("{prefix}.dt_bias"))?,
            norm_weight: w.take(&format!("{prefix}.norm.weight"))?,
            eps: cfg.rms_norm_eps,
            num_v_heads: cfg.linear_num_value_heads,
            num_k_heads: cfg.linear_num_key_heads,
            head_k_dim: cfg.linear_key_head_dim,
            head_v_dim: cfg.linear_value_head_dim,
            key_dim: cfg.linear_key_dim(),
            conv_dim: cfg.conv_dim(),
            conv_kernel: cfg.linear_conv_kernel_dim,
        })
    }

    pub fn forward(&self, x: &Array, cache: &mut DeltaCache) -> Result<Array> {
        let (b, s) = (x.shape()[0], x.shape()[1]);
        let hv = self.num_v_heads;

        let qkv = self.in_proj_qkv.forward(x)?;
        let z = self
            .in_proj_z
            .forward(x)?
            .reshape(&[b, s, hv, self.head_v_dim])?;
        let beta = ops::sigmoid(self.in_proj_b.forward(x)?)?;
        let a = self.in_proj_a.forward(x)?;

        // --- short depthwise convolution over the last `kernel` positions ---
        let carry = self.conv_kernel - 1;
        let conv_state = match cache.conv.take() {
            Some(state) => state,
            None => ops::zeros_dtype(&[b, carry, self.conv_dim], x.dtype())?,
        };
        let conv_input = ops::concatenate_axis(&[conv_state, qkv], 1)?;
        // Keep the tail for next time before the convolution consumes it.
        let tail = ops::split_sections(&conv_input, &[conv_input.shape()[1] - carry], 1)?;
        cache.conv = Some(tail[1].clone());

        let conv_out = nn::silu(ops::conv1d(
            &conv_input,
            &self.conv_weight,
            1,             // stride
            0,             // padding
            1,             // dilation
            self.conv_dim, // groups: one filter per channel
        )?)?;

        let parts = ops::split_sections(&conv_out, &[self.key_dim, 2 * self.key_dim], -1)?;
        let q = parts[0].reshape(&[b, s, self.num_k_heads, self.head_k_dim])?;
        let k = parts[1].reshape(&[b, s, self.num_k_heads, self.head_k_dim])?;
        let v = parts[2].reshape(&[b, s, hv, self.head_v_dim])?;

        // Fold the attention scale into q and k once, up front. The cast back
        // matters: multiplying by a float32 scalar would promote the whole
        // residual stream out of the model's dtype from here on.
        let inv_scale = (self.head_k_dim as f32).powf(-0.5);
        let dtype = x.dtype();
        let q = ops::multiply(
            rms_norm_unweighted(&q, QK_NORM_EPS)?,
            Array::from_f32(inv_scale * inv_scale),
        )?
        .as_dtype(dtype)?;
        let k = ops::multiply(
            rms_norm_unweighted(&k, QK_NORM_EPS)?,
            Array::from_f32(inv_scale),
        )?
        .as_dtype(dtype)?;

        // --- decay gate: exp(-exp(A_log) * softplus(a + dt_bias)) ---
        let decay_rate = ops::exp(self.a_log.as_dtype(Dtype::Float32)?)?;
        let dt = nn::softplus(ops::add(
            a.as_dtype(Dtype::Float32)?,
            self.dt_bias.as_dtype(Dtype::Float32)?,
        )?)?;
        let g = ops::exp(ops::negative(ops::multiply(&decay_rate, &dt)?)?)?;

        let state = match cache.state.take() {
            Some(state) => state,
            None => ops::zeros::<f32>(&[b, hv, self.head_v_dim, self.head_k_dim])?,
        };

        let (out, state) = gated_delta_update(&q, &k, &v, &g, &beta, state, self.num_k_heads)?;
        cache.state = Some(state);

        let out = rms_norm_gated(&out, &z, &self.norm_weight, self.eps)?;
        self.out_proj.forward(&out.reshape(&[b, s, -1])?)
    }

    pub fn nbytes(&self) -> u64 {
        let one = |a: &Array| a.nbytes() as u64;
        self.in_proj_qkv.nbytes()
            + self.in_proj_z.nbytes()
            + self.in_proj_b.nbytes()
            + self.in_proj_a.nbytes()
            + self.out_proj.nbytes()
            + one(&self.conv_weight)
            + one(&self.a_log)
            + one(&self.dt_bias)
            + one(&self.norm_weight)
    }
}

/// `[B, S, Hk, D] -> [B, S, Hk * n, D]`, each key head repeated in place.
fn expand_heads(x: &Array, n: i32) -> Result<Array> {
    if n == 1 {
        return Ok(x.clone());
    }
    Ok(ops::repeat_axis::<f32>(x.clone(), n, 2)?)
}

/// The Metal body of the delta-rule scan.
///
/// One simd-group per (batch, value head, value dimension): the 32 lanes hold
/// `Dk / 32` state entries each, and `simd_sum` does the two dot products.
/// Because the state never leaves registers, the whole scan is a single
/// dispatch instead of roughly ten array operations per position.
const GATED_DELTA_SOURCE: &str = r#"
    auto n = thread_position_in_grid.z;
    auto b_idx = n / Hv;
    auto hv_idx = n % Hv;
    auto hk_idx = hv_idx / (Hv / Hk);
    constexpr int n_per_t = Dk / 32;

    // q, k: [B, T, Hk, Dk]
    auto q_ = q + b_idx * T * Hk * Dk + hk_idx * Dk;
    auto k_ = k + b_idx * T * Hk * Dk + hk_idx * Dk;

    // v, y: [B, T, Hv, Dv]
    auto v_ = v + b_idx * T * Hv * Dv + hv_idx * Dv;
    y += b_idx * T * Hv * Dv + hv_idx * Dv;

    auto dk_idx = thread_position_in_threadgroup.x;
    auto dv_idx = thread_position_in_grid.y;

    // state_in, state_out: [B, Hv, Dv, Dk]
    auto i_state = state_in + (n * Dv + dv_idx) * Dk;
    auto o_state = state_out + (n * Dv + dv_idx) * Dk;

    float state[n_per_t];
    for (int i = 0; i < n_per_t; ++i) {
      auto s_idx = n_per_t * dk_idx + i;
      state[i] = static_cast<float>(i_state[s_idx]);
    }

    // g, beta: [B, T, Hv]
    auto g_ = g + b_idx * T * Hv;
    auto beta_ = beta + b_idx * T * Hv;

    for (int t = 0; t < T; ++t) {
      float kv_mem = 0.0f;
      for (int i = 0; i < n_per_t; ++i) {
        auto s_idx = n_per_t * dk_idx + i;
        state[i] = state[i] * g_[hv_idx];
        kv_mem += state[i] * k_[s_idx];
      }
      kv_mem = simd_sum(kv_mem);

      auto delta = (v_[dv_idx] - kv_mem) * beta_[hv_idx];

      float out = 0.0f;
      for (int i = 0; i < n_per_t; ++i) {
        auto s_idx = n_per_t * dk_idx + i;
        state[i] = state[i] + k_[s_idx] * delta;
        out += state[i] * q_[s_idx];
      }
      out = simd_sum(out);
      if (thread_index_in_simdgroup == 0) {
        y[dv_idx] = static_cast<InT>(out);
      }

      q_ += Hk * Dk;
      k_ += Hk * Dk;
      v_ += Hv * Dv;
      y += Hv * Dv;
      g_ += Hv;
      beta_ += Hv;
    }
    for (int i = 0; i < n_per_t; ++i) {
      auto s_idx = n_per_t * dk_idx + i;
      o_state[s_idx] = static_cast<StT>(state[i]);
    }
"#;

/// Lanes per simd-group; the kernel's `simd_sum` reductions assume this.
const SIMD_WIDTH: i32 = 32;

thread_local! {
    /// One compiled kernel per input-dtype signature.
    ///
    /// MLX caches a compiled kernel under its name and template arguments, and
    /// the *input* dtypes are part of neither — they only shape the generated
    /// pointer declarations. Two calls that differ solely in, say, `v` being
    /// bfloat16 rather than float32 would therefore reuse the wrong binary and
    /// read the buffer as the wrong type. Making the dtypes part of the name is
    /// what keeps that impossible. A `None` entry records a kernel we already
    /// failed to build, so it is not retried.
    static KERNELS: std::cell::RefCell<std::collections::HashMap<String, Option<MetalKernel>>> =
        std::cell::RefCell::new(std::collections::HashMap::new());
}

/// Whether to use the Metal kernel. `JARVIS_DELTA_KERNEL=0` forces the portable
/// path, which is how the two are compared in the tests.
///
/// A machine with no Metal device takes the portable path too. The dispatch
/// below would survive without this — a failed kernel already falls back — but
/// only after warning on stderr once per shape, which is noise rather than
/// news when there was never a GPU to use.
fn kernel_enabled() -> bool {
    if !crate::kernel::metal_available() {
        return false;
    }
    !matches!(
        std::env::var("JARVIS_DELTA_KERNEL").as_deref(),
        Ok("0") | Ok("off") | Ok("false")
    )
}

/// Run the delta-rule scan over `q`, `k`, `v`.
///
/// Shapes: `q`, `k` are `[B, S, Hk, Dk]`, `v` is `[B, S, Hv, Dv]`, `g` and
/// `beta` are `[B, S, Hv]`, `state` is `[B, Hv, Dv, Dk]` float32. The output
/// takes `q`'s dtype; the returned state stays float32.
pub fn gated_delta_update(
    q: &Array,
    k: &Array,
    v: &Array,
    g: &Array,
    beta: &Array,
    state: Array,
    num_k_heads: i32,
) -> Result<(Array, Array)> {
    let steps = q.shape()[1];
    let head_k_dim = q.shape()[3];
    let num_v_heads = v.shape()[2];

    let usable = kernel_enabled() && head_k_dim % SIMD_WIDTH == 0 && num_v_heads % num_k_heads == 0;

    if usable {
        let name = kernel_name(&[q, k, v, g, beta, &state]);
        let compiled = KERNELS.with(|cache| {
            cache
                .borrow_mut()
                .entry(name.clone())
                .or_insert_with(|| {
                    MetalKernel::new(
                        &name,
                        &["q", "k", "v", "g", "beta", "state_in", "T"],
                        &["y", "state_out"],
                        GATED_DELTA_SOURCE,
                    )
                    .map_err(|e| {
                        eprintln!("jarvis: gated-delta kernel unavailable ({e}); using array ops")
                    })
                    .ok()
                })
                .is_some()
        });
        if compiled {
            match run_kernel(&name, q, k, v, g, beta, &state, num_k_heads, steps) {
                Ok(out) => return Ok(out),
                Err(e) => eprintln!("jarvis: gated-delta kernel failed ({e}); using array ops"),
            }
        }
    }

    // Portable path: expand the grouped heads and scan with array operations.
    let repeat = num_v_heads / num_k_heads;
    let q = expand_heads(q, repeat)?.as_dtype(Dtype::Float32)?;
    let k = expand_heads(k, repeat)?.as_dtype(Dtype::Float32)?;
    let (out, state) = recurrence(
        &q,
        &k,
        &v.as_dtype(Dtype::Float32)?,
        g,
        &beta.as_dtype(Dtype::Float32)?,
        state,
        steps,
    )?;
    Ok((out.as_dtype(v.dtype())?, state))
}

/// A kernel name that encodes the dtypes it was generated for.
fn kernel_name(inputs: &[&Array]) -> String {
    let mut name = String::from("jarvis_gated_delta_scan");
    for array in inputs {
        name.push('_');
        name.push_str(dtype_tag(array.dtype()));
    }
    name
}

fn dtype_tag(dtype: Dtype) -> &'static str {
    match dtype {
        Dtype::Bfloat16 => "bf16",
        Dtype::Float16 => "f16",
        Dtype::Float32 => "f32",
        Dtype::Float64 => "f64",
        other => match other {
            Dtype::Int32 => "i32",
            _ => "other",
        },
    }
}

#[allow(clippy::too_many_arguments)]
fn run_kernel(
    name: &str,
    q: &Array,
    k: &Array,
    v: &Array,
    g: &Array,
    beta: &Array,
    state: &Array,
    num_k_heads: i32,
    steps: i32,
) -> Result<(Array, Array)> {
    let (batch, head_k_dim) = (q.shape()[0], q.shape()[3]);
    let (num_v_heads, head_v_dim) = (v.shape()[2], v.shape()[3]);
    let steps_arg = Array::from_int(steps);

    let mut out = MetalKernel::apply_cached(
        name,
        &[q, k, v, g, beta, state, &steps_arg],
        &[
            OutputSpec {
                shape: vec![batch, steps, num_v_heads, head_v_dim],
                dtype: q.dtype(),
            },
            OutputSpec {
                shape: state.shape().to_vec(),
                dtype: state.dtype(),
            },
        ],
        &[
            TemplateArg::Dtype("InT", q.dtype()),
            TemplateArg::Dtype("StT", state.dtype()),
            TemplateArg::Int("Dk", head_k_dim),
            TemplateArg::Int("Dv", head_v_dim),
            TemplateArg::Int("Hk", num_k_heads),
            TemplateArg::Int("Hv", num_v_heads),
        ],
        (SIMD_WIDTH, head_v_dim, batch * num_v_heads),
        (SIMD_WIDTH, 4, 1),
    )?;

    let new_state = out
        .pop()
        .ok_or_else(|| anyhow!("the kernel returned no state"))?;
    let y = out
        .pop()
        .ok_or_else(|| anyhow!("the kernel returned no output"))?;
    Ok((y, new_state))
}

impl MetalKernel {
    /// Dispatch the cached gated-delta kernel compiled under `name`.
    fn apply_cached(
        name: &str,
        inputs: &[&Array],
        outputs: &[OutputSpec],
        template: &[TemplateArg],
        grid: (i32, i32, i32),
        threadgroup: (i32, i32, i32),
    ) -> Result<Vec<Array>> {
        KERNELS.with(|cache| {
            let cache = cache.borrow();
            let kernel = cache
                .get(name)
                .and_then(|k| k.as_ref())
                .ok_or_else(|| anyhow!("`{name}` is not compiled"))?;
            kernel.apply(inputs, outputs, template, grid, threadgroup)
        })
    }
}

/// The delta-rule scan written with array operations — the reference the Metal
/// kernel is checked against, and the fallback when it cannot run.
///
/// Shapes: `q`, `k` are `[B, S, Hv, Dk]` (already expanded), `v` is
/// `[B, S, Hv, Dv]`, `g` and `beta` are `[B, S, Hv]`, `state` is
/// `[B, Hv, Dv, Dk]`. All float32.
fn recurrence(
    q: &Array,
    k: &Array,
    v: &Array,
    g: &Array,
    beta: &Array,
    mut state: Array,
    steps: i32,
) -> Result<(Array, Array)> {
    // One split each rather than `steps` gathers: the per-position slices come
    // out of a single op.
    let qs = ops::split(q, steps, 1)?;
    let ks = ops::split(k, steps, 1)?;
    let vs = ops::split(v, steps, 1)?;
    let gs = ops::split(g, steps, 1)?;
    let bs = ops::split(beta, steps, 1)?;

    let mut ys = Vec::with_capacity(steps as usize);
    for t in 0..steps as usize {
        let qt = qs[t].squeeze_axes(&[1])?; // [B, Hv, Dk]
        let kt = ks[t].squeeze_axes(&[1])?;
        let vt = vs[t].squeeze_axes(&[1])?; // [B, Hv, Dv]
        let gt = gs[t].squeeze_axes(&[1])?; // [B, Hv]
        let bt = bs[t].squeeze_axes(&[1])?;

        // Forget.
        state = ops::multiply(&state, gt.expand_dims_axes(&[2, 3])?)?;
        // What the current key already retrieves.
        let recalled = ops::multiply(&state, kt.expand_dims(2)?)?.sum_axis(-1, None)?;
        // Write in the part of the value that is still missing.
        let delta = ops::multiply(&ops::subtract(&vt, &recalled)?, bt.expand_dims(2)?)?;
        state = ops::add(
            &state,
            ops::multiply(&kt.expand_dims(2)?, &delta.expand_dims(3)?)?,
        )?;
        // Read out with the query.
        ys.push(ops::multiply(&state, qt.expand_dims(2)?)?.sum_axis(-1, None)?);
    }

    Ok((ops::stack_axis(&ys, 1)?, state))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn arr(data: &[f32], shape: &[i32]) -> Array {
        Array::from_slice(data, shape)
    }

    fn normal(shape: &[i32]) -> Array {
        mlx_rs::random::normal::<f32>(shape, None, None, None).unwrap()
    }

    /// Random q and k, normalised the way the model does.
    ///
    /// This is not cosmetic. The delta rule only contracts for keys of about
    /// unit norm; feeding raw N(0, 1) with a 128-wide key makes the recurrence
    /// diverge on its own, and then any two implementations disagree wildly no
    /// matter how correct both are.
    fn unit_qk(shape: &[i32]) -> (Array, Array) {
        let inv = (*shape.last().unwrap() as f32).powf(-0.5);
        let scaled = |scale: f32| {
            ops::multiply(
                rms_norm_unweighted(&normal(shape), QK_NORM_EPS).unwrap(),
                Array::from_f32(scale),
            )
            .unwrap()
        };
        (scaled(inv * inv), scaled(inv))
    }

    /// Largest absolute difference, in float32.
    fn worst(a: &Array, b: &Array) -> f32 {
        let f = |x: &Array| x.as_dtype(Dtype::Float32).unwrap();
        ops::subtract(f(a), f(b))
            .unwrap()
            .abs()
            .unwrap()
            .max(None)
            .unwrap()
            .item::<f32>()
    }

    #[test]
    fn one_step_writes_the_value_and_reads_it_back() {
        // A single head, Dk = Dv = 1, no decay (g = 1) and full write (beta = 1).
        // Starting from an empty state: S <- k*v, y = S*q = k*v*q.
        let q = arr(&[2.0], &[1, 1, 1, 1]);
        let k = arr(&[3.0], &[1, 1, 1, 1]);
        let v = arr(&[5.0], &[1, 1, 1, 1]);
        let g = arr(&[1.0], &[1, 1, 1]);
        let beta = arr(&[1.0], &[1, 1, 1]);
        let state = ops::zeros::<f32>(&[1, 1, 1, 1]).unwrap();

        let (y, state) = recurrence(&q, &k, &v, &g, &beta, state, 1).unwrap();
        assert_eq!(y.shape(), &[1, 1, 1, 1]);
        assert!((y.as_slice::<f32>()[0] - 30.0).abs() < 1e-5); // 3*5*2
        assert!((state.as_slice::<f32>()[0] - 15.0).abs() < 1e-5); // 3*5
    }

    #[test]
    fn the_gate_decays_the_state() {
        // Second step writes nothing (beta = 0) and halves the state (g = 0.5).
        let q = arr(&[1.0, 1.0], &[1, 2, 1, 1]);
        let k = arr(&[1.0, 1.0], &[1, 2, 1, 1]);
        let v = arr(&[4.0, 0.0], &[1, 2, 1, 1]);
        let g = arr(&[1.0, 0.5], &[1, 2, 1]);
        let beta = arr(&[1.0, 0.0], &[1, 2, 1]);
        let state = ops::zeros::<f32>(&[1, 1, 1, 1]).unwrap();

        let (y, state) = recurrence(&q, &k, &v, &g, &beta, state, 2).unwrap();
        let y = y.as_slice::<f32>();
        assert!((y[0] - 4.0).abs() < 1e-5);
        assert!((y[1] - 2.0).abs() < 1e-5);
        assert!((state.as_slice::<f32>()[0] - 2.0).abs() < 1e-5);
    }

    #[test]
    fn a_repeated_key_is_overwritten_not_accumulated() {
        // The delta rule replaces: writing v=4 then v=6 under the same unit key
        // must leave 6, not 10.
        let q = arr(&[1.0, 1.0], &[1, 2, 1, 1]);
        let k = arr(&[1.0, 1.0], &[1, 2, 1, 1]);
        let v = arr(&[4.0, 6.0], &[1, 2, 1, 1]);
        let g = arr(&[1.0, 1.0], &[1, 2, 1]);
        let beta = arr(&[1.0, 1.0], &[1, 2, 1]);
        let state = ops::zeros::<f32>(&[1, 1, 1, 1]).unwrap();

        let (y, _) = recurrence(&q, &k, &v, &g, &beta, state, 2).unwrap();
        assert!((y.as_slice::<f32>()[1] - 6.0).abs() < 1e-5);
    }

    /// The Metal kernel and the array-ops fallback must agree. Realistic head
    /// grouping (3 value heads per key head) and a key dimension one simd wide.
    #[test]
    fn the_kernel_and_the_ops_path_agree() {
        crate::skip_without_metal!();
        use mlx_rs::transforms::eval;

        let (b, s, hk, hv, dk, dv) = (1, 5, 2, 6, 32, 8);
        let (q, k) = unit_qk(&[b, s, hk, dk]);
        let v = normal(&[b, s, hv, dv]);
        // Gates and betas live in (0, 1), as they do in the model.
        let g = ops::sigmoid(normal(&[b, s, hv])).unwrap();
        let beta = ops::sigmoid(normal(&[b, s, hv])).unwrap();
        let state = normal(&[b, hv, dv, dk]);

        let (y_kernel, s_kernel) =
            gated_delta_update(&q, &k, &v, &g, &beta, state.clone(), hk).unwrap();
        let repeat = hv / hk;
        let (y_ops, s_ops) = recurrence(
            &expand_heads(&q, repeat).unwrap(),
            &expand_heads(&k, repeat).unwrap(),
            &v,
            &g,
            &beta,
            state,
            s,
        )
        .unwrap();

        eval([&y_kernel, &s_kernel, &y_ops, &s_ops]).unwrap();
        assert_eq!(y_kernel.shape(), y_ops.shape());
        assert!(
            worst(&y_kernel, &y_ops) < 1e-4,
            "outputs differ by {}",
            worst(&y_kernel, &y_ops)
        );
        assert!(
            worst(&s_kernel, &s_ops) < 1e-4,
            "states differ by {}",
            worst(&s_kernel, &s_ops)
        );
    }

    /// Same check at the shapes and dtypes the 27B model actually uses:
    /// 48 value heads over 16 key heads, 128-wide, in bfloat16.
    #[test]
    fn the_kernel_matches_at_model_scale() {
        crate::skip_without_metal!();
        use mlx_rs::transforms::eval;

        let (b, s, hk, hv, dk, dv) = (1, 19, 16, 48, 128, 128);
        let bf = |a: Array| a.as_dtype(Dtype::Bfloat16).unwrap();
        let (q, k) = unit_qk(&[b, s, hk, dk]);
        let (q, k) = (bf(q), bf(k));
        let v = bf(normal(&[b, s, hv, dv]));
        let g = ops::sigmoid(normal(&[b, s, hv])).unwrap();
        let beta = bf(ops::sigmoid(normal(&[b, s, hv])).unwrap());
        let state = normal(&[b, hv, dv, dk]);

        let (y_kernel, s_kernel) =
            gated_delta_update(&q, &k, &v, &g, &beta, state.clone(), hk).unwrap();
        let repeat = hv / hk;
        let (y_ops, s_ops) = recurrence(
            &expand_heads(&q.as_dtype(Dtype::Float32).unwrap(), repeat).unwrap(),
            &expand_heads(&k.as_dtype(Dtype::Float32).unwrap(), repeat).unwrap(),
            &v.as_dtype(Dtype::Float32).unwrap(),
            &g,
            &beta.as_dtype(Dtype::Float32).unwrap(),
            state,
            s,
        )
        .unwrap();

        eval([&y_kernel, &s_kernel, &y_ops, &s_ops]).unwrap();
        let dy = worst(&y_kernel, &y_ops);
        let ds = worst(&s_kernel, &s_ops);
        // bfloat16 carries about three decimal digits.
        assert!(dy.is_finite() && dy < 1e-2, "outputs differ by {dy}");
        assert!(ds.is_finite() && ds < 1e-2, "states differ by {ds}");
    }

    /// Regression: MLX keys a compiled kernel by name and template arguments,
    /// and input dtypes are part of neither. Feeding the same shapes with `v`
    /// and `beta` in a different dtype must therefore compile a *different*
    /// kernel, or the second call reads the buffers as the wrong type and
    /// returns garbage.
    #[test]
    fn a_dtype_change_does_not_reuse_the_wrong_kernel() {
        crate::skip_without_metal!();
        use mlx_rs::transforms::eval;

        let (b, s, hk, hv, dk, dv) = (1, 7, 2, 6, 32, 8);
        let (q, k) = unit_qk(&[b, s, hk, dk]);
        let v = normal(&[b, s, hv, dv]);
        let g = ops::sigmoid(normal(&[b, s, hv])).unwrap();
        let beta = ops::sigmoid(normal(&[b, s, hv])).unwrap();
        let state = normal(&[b, hv, dv, dk]);

        // First with bfloat16 values, then the identical numbers as float32.
        let bf = |a: &Array| a.as_dtype(Dtype::Bfloat16).unwrap();
        let (y_bf, _) =
            gated_delta_update(&q, &k, &bf(&v), &g, &bf(&beta), state.clone(), hk).unwrap();
        let (y_f32, _) = gated_delta_update(&q, &k, &v, &g, &beta, state, hk).unwrap();

        eval([&y_bf, &y_f32]).unwrap();
        let gap = worst(&y_f32, &y_bf);
        // bfloat16 carries ~3 decimal digits, so a small gap is expected;
        // garbage from the wrong kernel is orders of magnitude larger.
        assert!(gap.is_finite() && gap < 0.1, "the two runs differ by {gap}");
    }

    #[test]
    fn expanding_heads_keeps_each_group_contiguous() {
        // [B=1, S=1, Hk=2, D=1] with heads 1 and 2, doubled.
        let x = arr(&[1.0, 2.0], &[1, 1, 2, 1]);
        let out = expand_heads(&x, 2).unwrap();
        assert_eq!(out.shape(), &[1, 1, 4, 1]);
        assert_eq!(out.as_slice::<f32>(), &[1.0, 1.0, 2.0, 2.0]);
    }
}
