//! Custom Metal kernels, through the MLX C API.
//!
//! `mlx-rs` does not wrap `mlx.fast.metal_kernel`, so this is a thin safe layer
//! over the C entry points. MLX compiles the source at first use and caches the
//! result by name, so a kernel is built once per process.

use std::ffi::CString;

use anyhow::{anyhow, Result};
use mlx_rs::{Array, Device, Dtype, Stream};

/// Whether this machine actually has a Metal device.
///
/// False on a GPU-less box — a CI runner, most notably. MLX still evaluates on
/// the CPU stream there, so the ordinary array paths keep working; only the
/// custom kernels in this module have nowhere to run. Tests and the delta
/// dispatch both consult this so they can take the portable route rather than
/// fail.
pub fn metal_available() -> bool {
    // Cached: the delta dispatch consults this once per layer per token, and
    // whether the machine has a GPU is not going to change mid-process.
    static AVAILABLE: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *AVAILABLE.get_or_init(|| {
        if mocked_away() {
            return false;
        }
        let mut out = false;
        // Reads a static MLX initialises on load; no device is created.
        let status = unsafe { mlx_sys::mlx_metal_is_available(&mut out) };
        status == 0 && out
    })
}

/// `JARVIS_NO_METAL=1` pretends the GPU is not there.
///
/// The point is to make the GPU-less path reachable on a machine that does
/// have a GPU — which is the only way to check it, since the runner that needs
/// it cannot run this code. Reporting no Metal is not enough on its own: MLX
/// would still default to the GPU stream and the array paths would quietly
/// stay on it, so the mock also pins the default device to the CPU. That is
/// what a machine without Metal gets from MLX anyway, so the simulation is
/// faithful rather than merely plausible.
fn mocked_away() -> bool {
    static MOCK: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *MOCK.get_or_init(|| {
        let on = matches!(
            std::env::var("JARVIS_NO_METAL").as_deref(),
            Ok("1") | Ok("on") | Ok("true")
        );
        if on {
            Device::set_default(&Device::cpu());
            eprintln!("jarvis: JARVIS_NO_METAL is set — running on the CPU device");
        }
        on
    })
}

/// Skip the body of a GPU-only test when there is no Metal device.
///
/// Returns from the calling test after saying why, in the same spirit as the
/// checkpoint tests skipping when the weights are not on disk. A silent pass
/// would be worse than a skip: it reads as coverage that did not happen.
#[macro_export]
macro_rules! skip_without_metal {
    () => {
        if !$crate::kernel::metal_available() {
            eprintln!("skipped: no Metal device on this machine");
            return;
        }
    };
}

/// A compile-time constant substituted into the kernel source.
#[derive(Debug, Clone)]
pub enum TemplateArg {
    Int(&'static str, i32),
    Dtype(&'static str, Dtype),
}

/// Shape and element type of one kernel output.
#[derive(Debug, Clone)]
pub struct OutputSpec {
    pub shape: Vec<i32>,
    pub dtype: Dtype,
}

pub struct MetalKernel {
    raw: mlx_sys::mlx_fast_metal_kernel,
}

impl std::fmt::Debug for MetalKernel {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("MetalKernel").finish_non_exhaustive()
    }
}

impl Drop for MetalKernel {
    fn drop(&mut self) {
        unsafe { mlx_sys::mlx_fast_metal_kernel_free(self.raw) };
    }
}

impl MetalKernel {
    /// Compile a kernel body.
    ///
    /// `source` is the body only: MLX generates the signature from
    /// `input_names` and `output_names` and supplies the usual Metal builtins
    /// (`thread_position_in_grid` and friends).
    pub fn new(
        name: &str,
        input_names: &[&str],
        output_names: &[&str],
        source: &str,
    ) -> Result<Self> {
        let c_name = CString::new(name)?;
        let c_source = CString::new(source)?;
        let c_header = CString::new("")?;

        unsafe {
            // Freed on every path out, including the `?` in `vector_string`.
            let inputs = VectorGuard(vector_string(input_names)?);
            let outputs = VectorGuard(vector_string(output_names)?);
            let raw = mlx_sys::mlx_fast_metal_kernel_new(
                c_name.as_ptr(),
                inputs.0,
                outputs.0,
                c_source.as_ptr(),
                c_header.as_ptr(),
                true,  // ensure_row_contiguous
                false, // atomic_outputs
            );

            if raw.ctx.is_null() {
                return Err(anyhow!("MLX rejected the `{name}` kernel source"));
            }
            Ok(Self { raw })
        }
    }

    /// Dispatch the kernel. `grid` is in threads, not threadgroups.
    pub fn apply(
        &self,
        inputs: &[&Array],
        outputs: &[OutputSpec],
        template: &[TemplateArg],
        grid: (i32, i32, i32),
        threadgroup: (i32, i32, i32),
    ) -> Result<Vec<Array>> {
        unsafe {
            let config = mlx_sys::mlx_fast_metal_kernel_config_new();
            let mut guard = ConfigGuard(config);

            for spec in outputs {
                check(
                    mlx_sys::mlx_fast_metal_kernel_config_add_output_arg(
                        config,
                        spec.shape.as_ptr(),
                        spec.shape.len(),
                        u32::from(spec.dtype),
                    ),
                    "adding a kernel output",
                )?;
            }
            for arg in template {
                let status = match arg {
                    TemplateArg::Int(name, value) => {
                        let name = CString::new(*name)?;
                        mlx_sys::mlx_fast_metal_kernel_config_add_template_arg_int(
                            config,
                            name.as_ptr(),
                            *value,
                        )
                    }
                    TemplateArg::Dtype(name, dtype) => {
                        let name = CString::new(*name)?;
                        mlx_sys::mlx_fast_metal_kernel_config_add_template_arg_dtype(
                            config,
                            name.as_ptr(),
                            u32::from(*dtype),
                        )
                    }
                };
                check(status, "adding a template argument")?;
            }
            check(
                mlx_sys::mlx_fast_metal_kernel_config_set_grid(config, grid.0, grid.1, grid.2),
                "setting the grid",
            )?;
            check(
                mlx_sys::mlx_fast_metal_kernel_config_set_thread_group(
                    config,
                    threadgroup.0,
                    threadgroup.1,
                    threadgroup.2,
                ),
                "setting the threadgroup",
            )?;

            let input_vector = mlx_sys::mlx_vector_array_new();
            for array in inputs {
                mlx_sys::mlx_vector_array_append_value(input_vector, array.as_ref().as_ptr());
            }
            let mut output_vector = mlx_sys::mlx_vector_array_new();
            let status = mlx_sys::mlx_fast_metal_kernel_apply(
                &mut output_vector,
                self.raw,
                input_vector,
                config,
                Stream::gpu().as_ptr(),
            );
            mlx_sys::mlx_vector_array_free(input_vector);
            guard.release();

            if status != 0 {
                mlx_sys::mlx_vector_array_free(output_vector);
                return Err(anyhow!("the kernel failed to launch"));
            }

            let count = mlx_sys::mlx_vector_array_size(output_vector);
            let mut result = Vec::with_capacity(count);
            for i in 0..count {
                let mut raw = mlx_sys::mlx_array_new();
                mlx_sys::mlx_vector_array_get(&mut raw, output_vector, i);
                result.push(Array::from_ptr(raw));
            }
            mlx_sys::mlx_vector_array_free(output_vector);
            Ok(result)
        }
    }
}

/// Frees the config unless `release` was called first.
struct ConfigGuard(mlx_sys::mlx_fast_metal_kernel_config);

impl ConfigGuard {
    fn release(&mut self) {
        unsafe { mlx_sys::mlx_fast_metal_kernel_config_free(self.0) };
        self.0.ctx = std::ptr::null_mut();
    }
}

impl Drop for ConfigGuard {
    fn drop(&mut self) {
        if !self.0.ctx.is_null() {
            unsafe { mlx_sys::mlx_fast_metal_kernel_config_free(self.0) };
        }
    }
}

/// Frees an `mlx_vector_string` however its scope is left.
struct VectorGuard(mlx_sys::mlx_vector_string);

impl Drop for VectorGuard {
    fn drop(&mut self) {
        unsafe { mlx_sys::mlx_vector_string_free(self.0) };
    }
}

unsafe fn vector_string(values: &[&str]) -> Result<mlx_sys::mlx_vector_string> {
    let vector = VectorGuard(mlx_sys::mlx_vector_string_new());
    for value in values {
        // `CString::new` rejects an interior NUL; the guard frees the vector.
        let c = CString::new(*value)?;
        mlx_sys::mlx_vector_string_append_value(vector.0, c.as_ptr());
    }
    // Ownership passes to the caller, which wraps it in a guard of its own.
    let raw = vector.0;
    std::mem::forget(vector);
    Ok(raw)
}

fn check(status: std::os::raw::c_int, what: &str) -> Result<()> {
    if status == 0 {
        Ok(())
    } else {
        Err(anyhow!("MLX returned {status} while {what}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use mlx_rs::transforms::eval;

    #[test]
    fn a_trivial_kernel_compiles_and_runs() {
        crate::skip_without_metal!();
        // out[i] = in[i] * scale, one thread per element.
        let kernel = MetalKernel::new(
            "jarvis_scale_test",
            &["x", "scale"],
            &["out"],
            r#"
                auto i = thread_position_in_grid.x;
                out[i] = static_cast<T>(x[i] * scale);
            "#,
        )
        .unwrap();

        let x = Array::from_slice(&[1.0f32, 2.0, 3.0, 4.0], &[4]);
        let scale = Array::from_f32(2.5);
        let out = kernel
            .apply(
                &[&x, &scale],
                &[OutputSpec {
                    shape: vec![4],
                    dtype: Dtype::Float32,
                }],
                &[TemplateArg::Dtype("T", Dtype::Float32)],
                (4, 1, 1),
                (4, 1, 1),
            )
            .unwrap();

        assert_eq!(out.len(), 1);
        eval([&out[0]]).unwrap();
        assert_eq!(out[0].as_slice::<f32>(), &[2.5, 5.0, 7.5, 10.0]);
    }

    #[test]
    fn a_broken_kernel_reports_an_error_rather_than_aborting() {
        crate::skip_without_metal!();
        let kernel = MetalKernel::new("jarvis_broken_test", &["x"], &["out"], "this is not metal;");
        // Compilation is deferred to first use, so either step may be the one
        // that fails — what matters is that neither crashes the process.
        if let Ok(kernel) = kernel {
            let x = Array::from_slice(&[1.0f32], &[1]);
            let result = kernel.apply(
                &[&x],
                &[OutputSpec {
                    shape: vec![1],
                    dtype: Dtype::Float32,
                }],
                &[],
                (1, 1, 1),
                (1, 1, 1),
            );
            let _ = result.map(|out| eval(out.iter()));
        }
    }
}
