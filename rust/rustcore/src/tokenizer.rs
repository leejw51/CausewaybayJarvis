//! Tokenization, plus the piece that makes streaming output readable.

use std::path::Path;

use anyhow::{anyhow, Context, Result};

pub struct Tokenizer {
    inner: tokenizers::Tokenizer,
    eos: Vec<u32>,
    vocab_size: usize,
}

impl std::fmt::Debug for Tokenizer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Tokenizer")
            .field("vocab_size", &self.vocab_size)
            .field("eos", &self.eos)
            .finish()
    }
}

impl Tokenizer {
    /// Load `tokenizer.json` and pick up the stop tokens from
    /// `generation_config.json` / `config.json` if they are next to it.
    pub fn load(tokenizer_json: &Path, model_dir: &Path) -> Result<Self> {
        let inner = tokenizers::Tokenizer::from_file(tokenizer_json)
            .map_err(|e| anyhow!("{e}"))
            .with_context(|| format!("loading {}", tokenizer_json.display()))?;
        let vocab_size = inner.get_vocab_size(true);

        let mut eos = Vec::new();
        for name in ["generation_config.json", "config.json"] {
            let p = model_dir.join(name);
            if !p.is_file() {
                continue;
            }
            let json: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&p)?)?;
            collect_eos(&json, &mut eos);
            if !eos.is_empty() {
                break;
            }
        }
        // Last resort: the ChatML terminator every Qwen chat model uses.
        if eos.is_empty() {
            if let Some(id) = inner.token_to_id("<|im_end|>") {
                eos.push(id);
            }
        }
        eos.sort_unstable();
        eos.dedup();

        Ok(Self {
            inner,
            eos,
            vocab_size,
        })
    }

    pub fn encode(&self, text: &str) -> Result<Vec<u32>> {
        // `add_special_tokens: false` — the chat template already put every
        // special token exactly where it belongs.
        let enc = self.inner.encode(text, false).map_err(|e| anyhow!("{e}"))?;
        Ok(enc.get_ids().to_vec())
    }

    pub fn decode(&self, ids: &[u32]) -> Result<String> {
        self.inner.decode(ids, false).map_err(|e| anyhow!("{e}"))
    }

    pub fn eos_ids(&self) -> &[u32] {
        &self.eos
    }

    pub fn is_eos(&self, id: u32) -> bool {
        self.eos.contains(&id)
    }

    pub fn vocab_size(&self) -> usize {
        self.vocab_size
    }

    pub fn token_to_id(&self, token: &str) -> Option<u32> {
        self.inner.token_to_id(token)
    }
}

fn collect_eos(json: &serde_json::Value, out: &mut Vec<u32>) {
    match json.get("eos_token_id") {
        Some(serde_json::Value::Number(n)) => out.extend(n.as_u64().map(|v| v as u32)),
        Some(serde_json::Value::Array(a)) => {
            out.extend(a.iter().filter_map(|v| v.as_u64()).map(|v| v as u32))
        }
        _ => {}
    }
}

/// Incremental detokenizer.
///
/// A BPE token is not a character: a single id can be half a UTF-8 sequence, and
/// several ids can merge into one glyph. So we decode the whole run each step and
/// emit only the new tail, holding back anything that still decodes to U+FFFD.
#[derive(Debug, Default)]
pub struct StreamDecoder {
    ids: Vec<u32>,
    emitted: usize,
}

impl StreamDecoder {
    pub fn new() -> Self {
        Self::default()
    }

    /// Feed one token; returns the text to print, which is often empty.
    pub fn push(&mut self, tok: &Tokenizer, id: u32) -> Result<String> {
        self.ids.push(id);
        let text = tok.decode(&self.ids)?;
        // An incomplete byte sequence shows up as a replacement char at the end.
        if text.ends_with('\u{FFFD}') {
            return Ok(String::new());
        }
        if text.len() <= self.emitted {
            return Ok(String::new());
        }
        let chunk = text[self.emitted..].to_string();
        self.emitted = text.len();
        Ok(chunk)
    }

    /// Anything still buffered at the end of a generation.
    pub fn flush(&mut self, tok: &Tokenizer) -> Result<String> {
        let text = tok.decode(&self.ids)?;
        if text.len() <= self.emitted {
            return Ok(String::new());
        }
        let chunk = text[self.emitted..].to_string();
        self.emitted = text.len();
        Ok(chunk)
    }

    pub fn text(&self, tok: &Tokenizer) -> Result<String> {
        tok.decode(&self.ids)
    }

    pub fn len(&self) -> usize {
        self.ids.len()
    }

    pub fn is_empty(&self) -> bool {
        self.ids.is_empty()
    }

    pub fn reset(&mut self) {
        self.ids.clear();
        self.emitted = 0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn eos_is_read_from_a_list_or_a_scalar() {
        let mut out = Vec::new();
        collect_eos(&serde_json::json!({"eos_token_id": 7}), &mut out);
        assert_eq!(out, [7]);
        out.clear();
        collect_eos(&serde_json::json!({"eos_token_id": [1, 2]}), &mut out);
        assert_eq!(out, [1, 2]);
    }
}
