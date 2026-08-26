//! Which model an alias means.
//!
//! Aliases follow the Ollama naming the project already uses (`qwen3.8:27b-mlx`)
//! but always resolve to a Hugging Face repository, because that is where the
//! MLX-format weights actually live.

use anyhow::{anyhow, Result};

pub const DEFAULT_ALIAS: &str = "qwen3.8:27b-mlx";

/// Weight format of a checkpoint. Only affects reporting — the loader reads the
/// real numbers out of `config.json`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Quantization {
    /// `bits`-wide affine quantization with the given group size.
    Affine {
        bits: u32,
        group_size: u32,
    },
    None,
}

impl std::fmt::Display for Quantization {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Quantization::Affine { bits, group_size } => {
                write!(f, "{bits}-bit (group {group_size})")
            }
            Quantization::None => write!(f, "unquantized"),
        }
    }
}

/// The architecture family a checkpoint needs. `rustmlx` matches on this.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Architecture {
    /// Qwen3.5 / Qwen3.8 hybrid: gated DeltaNet linear attention interleaved
    /// with gated full attention.
    Qwen3_5,
}

#[derive(Debug, Clone)]
pub struct ModelSpec {
    pub alias: String,
    pub repo: String,
    pub revision: String,
    pub architecture: Architecture,
    /// Rough on-disk size, for the "this will take a while" message.
    pub approx_gib: f32,
}

struct Known {
    alias: &'static str,
    repo: &'static str,
    approx_gib: f32,
}

/// Aliases we ship. Anything of the form `org/name` is also accepted verbatim.
const KNOWN: &[Known] = &[
    Known {
        alias: "qwen3.8:27b-mlx",
        repo: "mlx-community/Qwen3.8-27B-4bit",
        approx_gib: 15.0,
    },
    Known {
        alias: "qwen3.8:27b-mlx-4bit",
        repo: "mlx-community/Qwen3.8-27B-4bit",
        approx_gib: 15.0,
    },
    Known {
        alias: "qwen3.8:27b-mlx-6bit",
        repo: "lmstudio-community/Qwen3.8-27B-MLX-6bit",
        approx_gib: 22.0,
    },
    Known {
        alias: "qwen3.8:27b-mlx-8bit",
        repo: "mlx-community/Qwen3.8-27B-8bit",
        approx_gib: 29.0,
    },
];

/// Resolve an alias (or a bare `org/name`) into a full spec.
pub fn resolve(alias: &str, revision: &str) -> Result<ModelSpec> {
    let alias = alias.trim();
    let revision = if revision.trim().is_empty() {
        "main"
    } else {
        revision.trim()
    };

    if let Some(k) = KNOWN.iter().find(|k| k.alias.eq_ignore_ascii_case(alias)) {
        return Ok(ModelSpec {
            alias: k.alias.to_string(),
            repo: k.repo.to_string(),
            revision: revision.to_string(),
            architecture: Architecture::Qwen3_5,
            approx_gib: k.approx_gib,
        });
    }

    // Accept a raw repository id so an unlisted MLX checkpoint still works.
    if alias.matches('/').count() == 1 && !alias.starts_with('/') && !alias.ends_with('/') {
        return Ok(ModelSpec {
            alias: alias.to_string(),
            repo: alias.to_string(),
            revision: revision.to_string(),
            architecture: Architecture::Qwen3_5,
            approx_gib: 0.0,
        });
    }

    Err(anyhow!(
        "unknown model `{alias}`. Known aliases: {}. A Hugging Face `org/name` also works.",
        KNOWN.iter().map(|k| k.alias).collect::<Vec<_>>().join(", ")
    ))
}

/// Build a spec straight from the `model` block of `config.jsonl`, honouring an
/// explicit `repo` override.
pub fn from_config(cfg: &crate::config::ModelConfig) -> Result<ModelSpec> {
    let mut spec = resolve(&cfg.alias, &cfg.revision)?;
    if !cfg.repo.trim().is_empty() {
        spec.repo = cfg.repo.trim().to_string();
    }
    Ok(spec)
}

pub fn known_aliases() -> impl Iterator<Item = (&'static str, &'static str)> {
    KNOWN.iter().map(|k| (k.alias, k.repo))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_alias_maps_to_the_4bit_mlx_repo() {
        let spec = resolve(DEFAULT_ALIAS, "").unwrap();
        assert_eq!(spec.repo, "mlx-community/Qwen3.8-27B-4bit");
        assert_eq!(spec.revision, "main");
    }

    #[test]
    fn bare_repo_ids_pass_through() {
        let spec = resolve("mlx-community/Qwen3.8-27B-8bit", "abc123").unwrap();
        assert_eq!(spec.repo, "mlx-community/Qwen3.8-27B-8bit");
        assert_eq!(spec.revision, "abc123");
    }

    #[test]
    fn nonsense_is_rejected() {
        assert!(resolve("llama-42", "").is_err());
    }
}
