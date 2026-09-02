//! Vectors, for the half of retrieval that BM25 cannot do.
//!
//! BM25 finds the rows that use the words you typed. It cannot find the note
//! about *"the thing that eats the borrow checker"* when the note says
//! `lifetime elision`. That is what a vector is for, and the two together are
//! what [`crate::search`] fuses.
//!
//! Two embedders ship. [`OllamaEmbedder`] is the real one — `/api/embed` on
//! ollama.com or a local daemon. [`HashEmbedder`] is a deterministic
//! bag-of-words projection that needs no network at all: it is what the tests
//! run against, and what the backend falls back to when there is no key and no
//! daemon, so semantic search *degrades* rather than disappearing.

use anyhow::Result;

pub trait Embedder: Send + Sync {
    /// A name to store beside the vector, so a change of model is visible.
    fn model(&self) -> &str;
    fn dim(&self) -> usize;
    /// One vector per input, in order.
    fn embed(&self, inputs: &[String]) -> Result<Vec<Vec<f32>>>;

    fn embed_one(&self, input: &str) -> Result<Vec<f32>> {
        Ok(self
            .embed(std::slice::from_ref(&input.to_string()))?
            .into_iter()
            .next()
            .unwrap_or_default())
    }
}

/// Cosine similarity. Both sides are L2-normalised on the way in, so this is
/// a dot product; it is written out in full anyway because a vector that
/// arrived from somewhere else may not be.
pub fn cosine(a: &[f32], b: &[f32]) -> f32 {
    if a.len() != b.len() || a.is_empty() {
        return 0.0;
    }
    let mut dot = 0.0f32;
    let mut na = 0.0f32;
    let mut nb = 0.0f32;
    for i in 0..a.len() {
        dot += a[i] * b[i];
        na += a[i] * a[i];
        nb += b[i] * b[i];
    }
    if na <= f32::EPSILON || nb <= f32::EPSILON {
        return 0.0;
    }
    dot / (na.sqrt() * nb.sqrt())
}

pub fn normalize(v: &mut [f32]) {
    let n = v.iter().map(|x| x * x).sum::<f32>().sqrt();
    if n > f32::EPSILON {
        for x in v.iter_mut() {
            *x /= n;
        }
    }
}

// ------------------------------------------------------------ the offline --

/// A hashing embedder: every token is projected onto two of `DIM` axes by its
/// own hash, weighted by `1 + ln(tf)`, and the result normalised.
///
/// This is the "random indexing" trick, and it is genuinely useful rather than
/// a stub: two texts that share vocabulary land near each other, which is
/// enough for *related note* retrieval, and it is exactly reproducible so the
/// tests can assert on it. What it cannot do is synonyms — that is what the
/// real model is for.
#[derive(Debug, Clone)]
pub struct HashEmbedder {
    dim: usize,
}

impl Default for HashEmbedder {
    fn default() -> Self {
        Self { dim: 256 }
    }
}

impl HashEmbedder {
    pub fn new(dim: usize) -> Self {
        Self { dim: dim.max(16) }
    }
}

/// FNV-1a. Small, fast, and stable across runs and platforms — which a
/// `DefaultHasher` is explicitly not.
fn fnv1a(bytes: &[u8], seed: u64) -> u64 {
    let mut h = 0xcbf2_9ce4_8422_2325u64 ^ seed;
    for b in bytes {
        h ^= *b as u64;
        h = h.wrapping_mul(0x1000_0000_01b3);
    }
    h
}

pub fn tokenize(text: &str) -> Vec<String> {
    text.split(|c: char| !c.is_alphanumeric() && c != '_')
        .filter(|t| !t.is_empty())
        .map(|t| t.to_lowercase())
        .collect()
}

impl Embedder for HashEmbedder {
    fn model(&self) -> &str {
        "hash-256"
    }

    fn dim(&self) -> usize {
        self.dim
    }

    fn embed(&self, inputs: &[String]) -> Result<Vec<Vec<f32>>> {
        let mut out = Vec::with_capacity(inputs.len());
        for text in inputs {
            let mut counts: std::collections::HashMap<String, f32> = Default::default();
            for token in tokenize(text) {
                *counts.entry(token).or_insert(0.0) += 1.0;
            }
            let mut v = vec![0.0f32; self.dim];
            for (token, tf) in counts {
                let w = 1.0 + tf.ln();
                let h1 = fnv1a(token.as_bytes(), 0);
                let h2 = fnv1a(token.as_bytes(), 0x9e37_79b9_7f4a_7c15);
                // Two axes with signs, so unrelated tokens cancel instead of
                // piling up on one dimension.
                let i1 = (h1 % self.dim as u64) as usize;
                let i2 = (h2 % self.dim as u64) as usize;
                v[i1] += if h1 & 1 == 0 { w } else { -w };
                v[i2] += if h2 & 1 == 0 { w * 0.5 } else { -w * 0.5 };
            }
            normalize(&mut v);
            out.push(v);
        }
        Ok(out)
    }
}

// -------------------------------------------------------------- the real ---

/// `/api/embed` on ollama.com or a local daemon.
pub struct OllamaEmbedder {
    client: crate::ollama::Ollama,
    model: String,
    dim: std::sync::atomic::AtomicUsize,
}

impl OllamaEmbedder {
    pub fn new(client: crate::ollama::Ollama, model: impl Into<String>) -> Self {
        Self {
            client,
            model: model.into(),
            dim: std::sync::atomic::AtomicUsize::new(0),
        }
    }
}

impl Embedder for OllamaEmbedder {
    fn model(&self) -> &str {
        &self.model
    }

    fn dim(&self) -> usize {
        self.dim.load(std::sync::atomic::Ordering::Relaxed)
    }

    fn embed(&self, inputs: &[String]) -> Result<Vec<Vec<f32>>> {
        let mut vectors = self.client.embed(&self.model, inputs)?;
        for v in vectors.iter_mut() {
            normalize(v);
        }
        if let Some(first) = vectors.first() {
            self.dim
                .store(first.len(), std::sync::atomic::Ordering::Relaxed);
        }
        Ok(vectors)
    }
}

// ------------------------------------------------------------- the safety --

/// A primary embedder with the offline one behind it.
///
/// This is not belt and braces: ollama.com has no embedding models at all —
/// `/api/embed` answers `unauthorized` for every key — so a cloud-only setup
/// would otherwise have *no* semantic search, and the hybrid half of every
/// query would silently vanish. The first failure latches, because a call
/// that failed once will fail for every row of a reindex and thirty timeouts
/// is not a retry policy.
///
/// The model name follows whichever is live, and that name is stored beside
/// every vector, so a fallback cannot leave one archive holding two
/// incompatible geometries: [`crate::search::semantic`] only ever compares
/// vectors written by the embedder it is running.
pub struct Fallback {
    primary: Box<dyn Embedder>,
    backup: HashEmbedder,
    fell_back: std::sync::atomic::AtomicBool,
    why: std::sync::Mutex<String>,
}

impl Fallback {
    pub fn new(primary: Box<dyn Embedder>) -> Self {
        Self {
            primary,
            backup: HashEmbedder::default(),
            fell_back: std::sync::atomic::AtomicBool::new(false),
            why: std::sync::Mutex::new(String::new()),
        }
    }

    pub fn degraded(&self) -> bool {
        self.fell_back.load(std::sync::atomic::Ordering::Relaxed)
    }

    /// Why it fell back, or empty while the primary is still answering.
    pub fn why(&self) -> String {
        self.why.lock().map(|w| w.clone()).unwrap_or_default()
    }
}

impl Embedder for Fallback {
    fn model(&self) -> &str {
        if self.degraded() {
            self.backup.model()
        } else {
            self.primary.model()
        }
    }

    fn dim(&self) -> usize {
        if self.degraded() {
            self.backup.dim()
        } else {
            self.primary.dim()
        }
    }

    fn embed(&self, inputs: &[String]) -> Result<Vec<Vec<f32>>> {
        if !self.degraded() {
            match self.primary.embed(inputs) {
                Ok(v) if v.iter().all(|x| !x.is_empty()) => return Ok(v),
                Ok(_) => self.fall_back("the embedding model returned nothing".into()),
                Err(e) => self.fall_back(e.to_string()),
            }
        }
        self.backup.embed(inputs)
    }
}

impl Fallback {
    fn fall_back(&self, why: String) {
        self.fell_back
            .store(true, std::sync::atomic::Ordering::Relaxed);
        if let Ok(mut slot) = self.why.lock() {
            *slot = why;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_hash_embedder_is_deterministic_and_normalised() {
        let e = HashEmbedder::default();
        let a = e
            .embed_one("the borrow checker rejected my lifetime")
            .unwrap();
        let b = e
            .embed_one("the borrow checker rejected my lifetime")
            .unwrap();
        assert_eq!(a, b);
        assert_eq!(a.len(), 256);
        let norm: f32 = a.iter().map(|x| x * x).sum::<f32>().sqrt();
        assert!((norm - 1.0).abs() < 1e-4, "norm was {norm}");
    }

    #[test]
    fn shared_vocabulary_scores_higher_than_none() {
        let e = HashEmbedder::default();
        let q = e.embed_one("rust borrow checker lifetime error").unwrap();
        let near = e
            .embed_one("a note about the rust borrow checker and lifetime rules")
            .unwrap();
        let far = e
            .embed_one("braise the pork belly for three hours")
            .unwrap();
        assert!(
            cosine(&q, &near) > cosine(&q, &far),
            "near {} far {}",
            cosine(&q, &near),
            cosine(&q, &far)
        );
        assert!(cosine(&q, &q) > 0.999);
    }

    #[test]
    fn cosine_survives_mismatched_and_empty_vectors() {
        assert_eq!(cosine(&[1.0, 0.0], &[1.0]), 0.0);
        assert_eq!(cosine(&[], &[]), 0.0);
        assert_eq!(cosine(&[0.0, 0.0], &[1.0, 1.0]), 0.0);
    }
}

#[cfg(test)]
mod fallback_tests {
    use super::*;

    struct Broken;
    impl Embedder for Broken {
        fn model(&self) -> &str {
            "broken"
        }
        fn dim(&self) -> usize {
            0
        }
        fn embed(&self, _: &[String]) -> Result<Vec<Vec<f32>>> {
            anyhow::bail!("/api/embed: unauthorized")
        }
    }

    struct Empty;
    impl Embedder for Empty {
        fn model(&self) -> &str {
            "empty"
        }
        fn dim(&self) -> usize {
            0
        }
        fn embed(&self, inputs: &[String]) -> Result<Vec<Vec<f32>>> {
            Ok(vec![Vec::new(); inputs.len()])
        }
    }

    #[test]
    fn a_failing_embedder_falls_back_and_says_why() {
        let e = Fallback::new(Box::new(Broken));
        assert_eq!(e.model(), "broken");
        let v = e.embed_one("anything").unwrap();
        assert_eq!(v.len(), 256);
        assert!(e.degraded());
        assert_eq!(
            e.model(),
            "hash-256",
            "the stored model name follows the live one"
        );
        assert!(e.why().contains("unauthorized"));
    }

    #[test]
    fn an_embedder_that_answers_with_nothing_counts_as_failing() {
        let e = Fallback::new(Box::new(Empty));
        assert!(!e.embed_one("x").unwrap().is_empty());
        assert!(e.degraded());
    }

    #[test]
    fn a_working_embedder_is_left_alone() {
        let e = Fallback::new(Box::new(HashEmbedder::new(64)));
        assert_eq!(e.embed_one("x").unwrap().len(), 64);
        assert!(!e.degraded());
        assert_eq!(e.model(), "hash-256");
        assert!(e.why().is_empty());
    }
}
