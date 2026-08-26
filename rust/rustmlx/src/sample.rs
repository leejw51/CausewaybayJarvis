//! Turning a row of logits into the next token.
//!
//! Sampling runs on the host: the vocabulary row has to come back anyway before
//! the next step can be built, so there is nothing to gain from keeping it on
//! the GPU, and plain Rust is far easier to test.

use rustcore::GenerationConfig;

/// xoshiro256++ — small, fast, and reproducible from a seed.
#[derive(Debug, Clone)]
pub struct Rng {
    s: [u64; 4],
}

impl Rng {
    pub fn new(seed: u64) -> Self {
        // SplitMix64 to spread one seed over the whole state.
        let mut z = seed;
        let mut next = || {
            z = z.wrapping_add(0x9E3779B97F4A7C15);
            let mut x = z;
            x = (x ^ (x >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
            x = (x ^ (x >> 27)).wrapping_mul(0x94D049BB133111EB);
            x ^ (x >> 31)
        };
        Self {
            s: [next(), next(), next(), next()],
        }
    }

    pub fn from_entropy() -> Self {
        use std::time::{SystemTime, UNIX_EPOCH};
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos() as u64)
            .unwrap_or(0x5EED);
        Self::new(nanos ^ (std::process::id() as u64) << 32)
    }

    fn next_u64(&mut self) -> u64 {
        let s = &mut self.s;
        let result = s[0].wrapping_add(s[3]).rotate_left(23).wrapping_add(s[0]);
        let t = s[1] << 17;
        s[2] ^= s[0];
        s[3] ^= s[1];
        s[1] ^= s[2];
        s[0] ^= s[3];
        s[2] ^= t;
        s[3] = s[3].rotate_left(45);
        result
    }

    /// Uniform in `[0, 1)`.
    pub fn next_f32(&mut self) -> f32 {
        (self.next_u64() >> 40) as f32 / (1u32 << 24) as f32
    }
}

#[derive(Debug)]
pub struct Sampler {
    cfg: GenerationConfig,
    rng: Rng,
    /// Scratch, reused across steps so a 248k-wide vocabulary is not reallocated
    /// once per token.
    scratch: Vec<(u32, f32)>,
}

impl Sampler {
    pub fn new(cfg: GenerationConfig) -> Self {
        let rng = match cfg.seed {
            Some(seed) => Rng::new(seed),
            None => Rng::from_entropy(),
        };
        Self {
            cfg,
            rng,
            scratch: Vec::new(),
        }
    }

    /// Pick the next token. `recent` is the tail of the generated ids, used for
    /// the repetition penalty.
    pub fn sample(&mut self, logits: &mut [f32], recent: &[u32]) -> u32 {
        self.apply_repetition_penalty(logits, recent);

        if self.cfg.temperature <= 0.0 {
            return argmax(logits);
        }

        let inv_t = 1.0 / self.cfg.temperature;
        let k = if self.cfg.top_k == 0 {
            logits.len()
        } else {
            self.cfg.top_k.min(logits.len())
        };

        let cand = &mut self.scratch;
        cand.clear();
        cand.extend(
            logits
                .iter()
                .enumerate()
                .map(|(i, &l)| (i as u32, l * inv_t)),
        );

        // Keep only the k largest, then order those.
        if k < cand.len() {
            cand.select_nth_unstable_by(k - 1, |a, b| b.1.total_cmp(&a.1));
            cand.truncate(k);
        }
        cand.sort_unstable_by(|a, b| b.1.total_cmp(&a.1));

        // Softmax over the survivors.
        let max = cand[0].1;
        let mut total = 0.0f32;
        for c in cand.iter_mut() {
            c.1 = (c.1 - max).exp();
            total += c.1;
        }
        for c in cand.iter_mut() {
            c.1 /= total;
        }

        // min-p: drop anything far below the most likely token.
        if self.cfg.min_p > 0.0 {
            let floor = self.cfg.min_p * cand[0].1;
            let keep = cand
                .iter()
                .position(|c| c.1 < floor)
                .unwrap_or(cand.len())
                .max(1);
            cand.truncate(keep);
        }

        // top-p: the shortest prefix whose mass reaches p.
        if self.cfg.top_p > 0.0 && self.cfg.top_p < 1.0 {
            let mut acc = 0.0;
            let mut keep = cand.len();
            for (i, c) in cand.iter().enumerate() {
                acc += c.1;
                if acc >= self.cfg.top_p {
                    keep = i + 1;
                    break;
                }
            }
            cand.truncate(keep.max(1));
        }

        let total: f32 = cand.iter().map(|c| c.1).sum();
        let mut target = self.rng.next_f32() * total;
        for c in cand.iter() {
            target -= c.1;
            if target <= 0.0 {
                return c.0;
            }
        }
        cand.last().expect("at least one candidate").0
    }

    fn apply_repetition_penalty(&self, logits: &mut [f32], recent: &[u32]) {
        let p = self.cfg.repetition_penalty;
        if p == 1.0 || self.cfg.repetition_context == 0 {
            return;
        }
        let from = recent.len().saturating_sub(self.cfg.repetition_context);
        for &id in &recent[from..] {
            let Some(l) = logits.get_mut(id as usize) else {
                continue;
            };
            // Pushing a positive logit down and a negative one further down are
            // the same operation on the odds; the sign split is what the
            // original CTRL formulation does.
            *l = if *l > 0.0 { *l / p } else { *l * p };
        }
    }
}

pub fn argmax(logits: &[f32]) -> u32 {
    let mut best = 0usize;
    for (i, &l) in logits.iter().enumerate() {
        if l > logits[best] {
            best = i;
        }
    }
    best as u32
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg() -> GenerationConfig {
        GenerationConfig {
            max_tokens: 8,
            temperature: 1.0,
            top_p: 1.0,
            top_k: 0,
            min_p: 0.0,
            repetition_penalty: 1.0,
            repetition_context: 64,
            seed: Some(7),
        }
    }

    #[test]
    fn zero_temperature_is_greedy() {
        let mut s = Sampler::new(GenerationConfig {
            temperature: 0.0,
            ..cfg()
        });
        let mut logits = [0.1f32, 5.0, 0.3];
        assert_eq!(s.sample(&mut logits, &[]), 1);
    }

    #[test]
    fn top_k_of_one_is_also_greedy() {
        let mut s = Sampler::new(GenerationConfig { top_k: 1, ..cfg() });
        let logits = [0.1f32, 5.0, 0.3];
        for _ in 0..10 {
            assert_eq!(s.sample(&mut logits.clone(), &[]), 1);
        }
    }

    #[test]
    fn the_same_seed_gives_the_same_stream() {
        let logits = [1.0f32, 1.1, 0.9, 1.05];
        let run = |seed| {
            let mut s = Sampler::new(GenerationConfig {
                seed: Some(seed),
                ..cfg()
            });
            (0..20)
                .map(|_| s.sample(&mut logits.clone(), &[]))
                .collect::<Vec<_>>()
        };
        assert_eq!(run(42), run(42));
        assert_ne!(run(42), run(43));
    }

    #[test]
    fn sampling_respects_the_distribution() {
        // A logit gap of 5 nats means the low option should essentially never win.
        let mut s = Sampler::new(cfg());
        let logits = [0.0f32, 5.0];
        let ones = (0..200)
            .filter(|_| s.sample(&mut logits.clone(), &[]) == 1)
            .count();
        assert!(
            ones > 180,
            "expected the high-logit token to dominate, got {ones}/200"
        );
    }

    #[test]
    fn repetition_penalty_only_touches_recent_tokens() {
        let s = Sampler::new(GenerationConfig {
            repetition_penalty: 2.0,
            repetition_context: 2,
            ..cfg()
        });
        let mut logits = [4.0f32, -4.0, 4.0];
        s.apply_repetition_penalty(&mut logits, &[0, 1]);
        assert_eq!(logits, [2.0, -8.0, 4.0]);
    }

    #[test]
    fn repetition_context_is_a_window() {
        let s = Sampler::new(GenerationConfig {
            repetition_penalty: 2.0,
            repetition_context: 1,
            ..cfg()
        });
        let mut logits = [4.0f32, 4.0];
        s.apply_repetition_penalty(&mut logits, &[0, 1]);
        assert_eq!(
            logits,
            [4.0, 2.0],
            "only the last token is inside the window"
        );
    }

    #[test]
    fn min_p_prunes_the_tail() {
        // With min_p = 0.5 only tokens at least half as likely as the top survive.
        let mut s = Sampler::new(GenerationConfig {
            min_p: 0.5,
            ..cfg()
        });
        let logits = [0.0f32, 10.0, 9.9];
        let picks: Vec<_> = (0..50)
            .map(|_| s.sample(&mut logits.clone(), &[]))
            .collect();
        assert!(picks.iter().all(|&p| p == 1 || p == 2), "{picks:?}");
    }

    #[test]
    fn rng_stays_inside_the_unit_interval() {
        let mut r = Rng::new(1);
        for _ in 0..10_000 {
            let v = r.next_f32();
            assert!((0.0..1.0).contains(&v), "{v}");
        }
    }
}
