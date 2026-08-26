//! Thin wrappers over MLX's allocator counters.
//!
//! `mlx-rs` does not surface these, so we call the C API directly. They are
//! plain process-wide counters — no arrays or streams involved.

/// Bytes MLX currently has allocated.
pub fn active() -> u64 {
    let mut out: usize = 0;
    unsafe { mlx_sys::mlx_get_active_memory(&mut out) };
    out as u64
}

/// High-water mark since the process started (or since [`reset_peak`]).
pub fn peak() -> u64 {
    let mut out: usize = 0;
    unsafe { mlx_sys::mlx_get_peak_memory(&mut out) };
    out as u64
}

pub fn reset_peak() {
    unsafe { mlx_sys::mlx_reset_peak_memory() };
}

/// Release cached-but-unused buffers back to the system.
pub fn clear_cache() {
    unsafe { mlx_sys::mlx_clear_cache() };
}

/// Ask Metal to keep this many bytes resident. Returns the previous limit.
///
/// Worth raising past the default when the weights are a large fraction of
/// physical memory, which is exactly the case for a 15 GiB model on 36 GiB.
pub fn set_wired_limit(bytes: u64) -> u64 {
    let mut previous: usize = 0;
    unsafe { mlx_sys::mlx_set_wired_limit(&mut previous, bytes as usize) };
    previous as u64
}

/// Human-readable byte count.
pub fn human(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KiB", "MiB", "GiB", "TiB"];
    let mut value = bytes as f64;
    let mut unit = 0;
    while value >= 1024.0 && unit + 1 < UNITS.len() {
        value /= 1024.0;
        unit += 1;
    }
    if unit == 0 {
        format!("{bytes} B")
    } else {
        format!("{value:.1} {}", UNITS[unit])
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn byte_counts_read_sensibly() {
        assert_eq!(human(512), "512 B");
        assert_eq!(human(2048), "2.0 KiB");
        assert_eq!(human(15 * 1024 * 1024 * 1024), "15.0 GiB");
    }

    #[test]
    fn the_counters_answer() {
        // Allocating something has to move `active` off zero.
        let _a = mlx_rs::ops::zeros::<f32>(&[1024, 1024]).unwrap();
        mlx_rs::transforms::eval([&_a]).unwrap();
        assert!(active() > 0);
        assert!(peak() >= active());
    }
}
