//! Per-layer state carried between forward passes.
//!
//! Full-attention layers keep the usual key/value cache. Linear-attention layers
//! keep two fixed-size things instead: the tail of the depthwise convolution's
//! input, and the DeltaNet recurrent state. That is the point of the hybrid —
//! only every fourth layer grows with the conversation.

use anyhow::Result;
use mlx_rs::{ops, Array};

#[derive(Debug, Default)]
pub struct KvCache {
    keys: Option<Array>,
    values: Option<Array>,
    offset: i32,
}

impl KvCache {
    pub fn new() -> Self {
        Self::default()
    }

    /// How many positions are already cached — the rotary offset for the next call.
    pub fn offset(&self) -> i32 {
        self.offset
    }

    /// Append `[B, H, L, D]` keys and values and return the full history.
    pub fn update(&mut self, k: &Array, v: &Array) -> Result<(Array, Array)> {
        self.offset += k.shape()[2];
        let keys = match self.keys.take() {
            Some(old) => ops::concatenate_axis(&[old, k.clone()], 2)?,
            None => k.clone(),
        };
        let values = match self.values.take() {
            Some(old) => ops::concatenate_axis(&[old, v.clone()], 2)?,
            None => v.clone(),
        };
        self.keys = Some(keys.clone());
        self.values = Some(values.clone());
        Ok((keys, values))
    }

    pub fn reset(&mut self) {
        self.keys = None;
        self.values = None;
        self.offset = 0;
    }

    /// Bytes currently held.
    pub fn nbytes(&self) -> u64 {
        let one = |a: &Option<Array>| a.as_ref().map_or(0, |a| a.nbytes() as u64);
        one(&self.keys) + one(&self.values)
    }
}

/// State for one gated DeltaNet layer.
#[derive(Debug, Default)]
pub struct DeltaCache {
    /// The last `kernel_size - 1` convolution inputs, `[B, K-1, conv_dim]`.
    pub conv: Option<Array>,
    /// The recurrent state, `[B, Hv, Dv, Dk]`, always float32.
    pub state: Option<Array>,
}

impl DeltaCache {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn reset(&mut self) {
        self.conv = None;
        self.state = None;
    }

    pub fn nbytes(&self) -> u64 {
        let one = |a: &Option<Array>| a.as_ref().map_or(0, |a| a.nbytes() as u64);
        one(&self.conv) + one(&self.state)
    }
}

#[derive(Debug)]
pub enum LayerCache {
    Kv(KvCache),
    Delta(DeltaCache),
}

impl LayerCache {
    pub fn reset(&mut self) {
        match self {
            LayerCache::Kv(c) => c.reset(),
            LayerCache::Delta(c) => c.reset(),
        }
    }

    pub fn nbytes(&self) -> u64 {
        match self {
            LayerCache::Kv(c) => c.nbytes(),
            LayerCache::Delta(c) => c.nbytes(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn step(cache: &mut KvCache, value: f32, len: i32) -> Array {
        let k = ops::full::<f32>(&[1, 1, len, 2], mlx_rs::array!(value)).unwrap();
        cache.update(&k, &k).unwrap().0
    }

    #[test]
    fn the_cache_appends_in_order() {
        let mut cache = KvCache::new();
        let k = step(&mut cache, 1.0, 3);
        assert_eq!(k.shape(), &[1, 1, 3, 2]);
        assert_eq!(cache.offset(), 3);

        let k = step(&mut cache, 2.0, 1);
        assert_eq!(k.shape(), &[1, 1, 4, 2]);
        assert_eq!(
            k.as_slice::<f32>(),
            &[1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 2.0, 2.0]
        );
        assert_eq!(cache.offset(), 4);
    }

    #[test]
    fn reset_empties_it() {
        let mut cache = KvCache::new();
        step(&mut cache, 1.0, 2);
        assert!(cache.nbytes() > 0);
        cache.reset();
        assert_eq!(cache.offset(), 0);
        assert_eq!(cache.nbytes(), 0);
        assert_eq!(step(&mut cache, 5.0, 1).shape(), &[1, 1, 1, 2]);
    }
}
