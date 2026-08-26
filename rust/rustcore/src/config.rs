//! `config.jsonl` — one `{"key": ..., "value": ...}` object per line.
//!
//! Same shape as the sibling `causewaybay agent` project: a flat key/value store
//! that is trivial to read from any language, and diffs line-by-line in git.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// The config that ships with the source tree, compiled in so a stray binary
/// still has sane defaults.
const BUILTIN: &str = include_str!("../../../config.jsonl");

/// Why a config file should not be trusted, or `None` when it is fine.
///
/// The two cases that matter, both borrowed from how OpenSSH vets its own
/// config: the file belongs to somebody else, or anyone on the machine can
/// rewrite it. Group-writable is deliberately allowed — a 664 file under a
/// shared umask is ordinary, and the threat here is an unrelated user.
#[cfg(unix)]
fn writable_by_others(path: &Path) -> Option<&'static str> {
    use std::os::unix::fs::MetadataExt;

    let meta = std::fs::metadata(path).ok()?;
    if meta.uid() != rustix::process::geteuid().as_raw() {
        return Some("it is owned by another user");
    }
    if meta.mode() & 0o002 != 0 {
        return Some("it is world-writable");
    }
    None
}

#[cfg(not(unix))]
fn writable_by_others(_path: &Path) -> Option<&'static str> {
    None
}

#[derive(Debug, Clone)]
pub struct Config {
    /// Where it was read from, or `None` for the compiled-in defaults.
    pub source: Option<PathBuf>,
    entries: BTreeMap<String, Value>,
}

#[derive(Debug, Deserialize, Serialize)]
struct Entry {
    key: String,
    value: Value,
}

impl Config {
    /// Parse the jsonl text directly.
    pub fn parse(text: &str, source: Option<PathBuf>) -> Result<Self> {
        let mut entries = BTreeMap::new();
        for (i, line) in text.lines().enumerate() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let entry: Entry = serde_json::from_str(line)
                .with_context(|| format!("config line {}: {line}", i + 1))?;
            entries.insert(entry.key, entry.value);
        }
        Ok(Self { source, entries })
    }

    pub fn load(path: impl AsRef<Path>) -> Result<Self> {
        let path = path.as_ref();
        let text =
            std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
        Self::parse(&text, Some(path.to_path_buf()))
    }

    /// Compiled-in defaults.
    pub fn builtin() -> Self {
        Self::parse(BUILTIN, None).expect("builtin config.jsonl is valid")
    }

    /// Look for `config.jsonl` next to the binary, then walking up from the
    /// working directory, then fall back to the compiled-in copy.
    ///
    /// The walk climbs to the filesystem root, so it can pass through
    /// directories the user does not control — `/tmp` and friends. A config
    /// decides which checkpoint is downloaded and run, so a candidate someone
    /// else could have written is skipped rather than trusted; see
    /// [`writable_by_others`].
    pub fn discover() -> Self {
        for candidate in Self::candidates() {
            if !candidate.is_file() {
                continue;
            }
            if let Some(why) = writable_by_others(&candidate) {
                eprintln!("jarvis: ignoring {} ({why})", candidate.display());
                continue;
            }
            if let Ok(cfg) = Self::load(&candidate) {
                return cfg;
            }
        }
        Self::builtin()
    }

    fn candidates() -> Vec<PathBuf> {
        let mut out = Vec::new();
        if let Ok(explicit) = std::env::var("JARVIS_CONFIG") {
            out.push(PathBuf::from(explicit));
        }
        if let Ok(cwd) = std::env::current_dir() {
            let mut dir = Some(cwd.as_path());
            while let Some(d) = dir {
                out.push(d.join("config.jsonl"));
                dir = d.parent();
            }
        }
        if let Ok(exe) = std::env::current_exe() {
            if let Some(d) = exe.parent() {
                out.push(d.join("config.jsonl"));
            }
        }
        out
    }

    pub fn raw(&self, key: &str) -> Option<&Value> {
        self.entries.get(key)
    }

    /// Deserialize one key, or fall back to `T::default()` when it is absent.
    pub fn get<T: DeserializeOwned + Default>(&self, key: &str) -> T {
        self.try_get(key).unwrap_or_default()
    }

    /// Deserialize one key. `None` when absent or malformed.
    pub fn try_get<T: DeserializeOwned>(&self, key: &str) -> Option<T> {
        serde_json::from_value(self.entries.get(key)?.clone()).ok()
    }

    pub fn app(&self) -> AppConfig {
        self.get("app")
    }
    pub fn model(&self) -> ModelConfig {
        self.get("model")
    }
    pub fn generation(&self) -> GenerationSettings {
        self.get("generation")
    }
    pub fn thinking(&self) -> ThinkingConfig {
        self.get("thinking")
    }
    pub fn paths(&self) -> PathsConfig {
        self.get("paths")
    }
    pub fn runtime(&self) -> RuntimeConfig {
        self.get("runtime")
    }
    pub fn system_prompt(&self) -> Option<String> {
        self.try_get::<String>("system_prompt")
            .filter(|s| !s.trim().is_empty())
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct AppConfig {
    pub name: String,
    pub version: String,
}

impl Default for AppConfig {
    fn default() -> Self {
        Self {
            name: "Causewaybay Jarvis".into(),
            version: env!("CARGO_PKG_VERSION").into(),
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct ModelConfig {
    /// Ollama-style alias, e.g. `qwen3.8:27b-mlx`.
    pub alias: String,
    /// Explicit `org/name` override. Empty means "resolve from the alias".
    pub repo: String,
    pub revision: String,
}

impl Default for ModelConfig {
    fn default() -> Self {
        Self {
            alias: crate::models::DEFAULT_ALIAS.into(),
            repo: String::new(),
            revision: "main".into(),
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct GenerationSettings {
    pub max_tokens: usize,
    pub temperature: f32,
    pub top_p: f32,
    pub top_k: usize,
    pub min_p: f32,
    pub repetition_penalty: f32,
    pub repetition_context: usize,
    pub seed: Option<u64>,
}

impl Default for GenerationSettings {
    fn default() -> Self {
        Self {
            max_tokens: 2048,
            temperature: 0.7,
            top_p: 0.95,
            top_k: 20,
            min_p: 0.0,
            repetition_penalty: 1.05,
            repetition_context: 64,
            seed: None,
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct ThinkingConfig {
    /// Let the model emit a `<think>` block at all.
    pub enabled: bool,
    /// `low` | `medium` | `xhigh` — the template turns this into an instruction.
    pub effort: String,
    /// Show the reasoning stream in the UI.
    pub show: bool,
}

impl Default for ThinkingConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            effort: "low".into(),
            show: true,
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct PathsConfig {
    pub data: String,
    pub history: String,
}

impl Default for PathsConfig {
    fn default() -> Self {
        Self {
            data: "data".into(),
            history: "data/history.jsonl".into(),
        }
    }
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct RuntimeConfig {
    /// Metal wired-memory limit in GiB. 0 leaves the system default alone.
    pub wired_limit_gb: u32,
    /// Quantize the KV cache to this many bits. 0 disables.
    pub kv_bits: u32,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[cfg(unix)]
    fn a_config_anyone_could_rewrite_is_not_trusted() {
        use std::os::unix::fs::PermissionsExt;

        let dir = std::env::temp_dir().join(format!("jarvis-config-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("config.jsonl");
        std::fs::write(&path, "{\"key\":\"app\",\"value\":{}}\n").unwrap();

        // Ours, and only ours to write: trusted.
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert_eq!(writable_by_others(&path), None);

        // Ours, but anyone can rewrite it: not trusted.
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o646)).unwrap();
        assert_eq!(writable_by_others(&path), Some("it is world-writable"));

        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn builtin_config_parses_and_has_the_default_model() {
        let cfg = Config::builtin();
        assert_eq!(cfg.model().alias, "qwen3.8:27b-mlx");
        assert_eq!(cfg.model().repo, "mlx-community/Qwen3.8-27B-4bit");
        assert!(cfg.generation().max_tokens > 0);
        assert!(cfg.system_prompt().is_some());
    }

    #[test]
    fn missing_keys_fall_back_to_defaults() {
        let cfg = Config::parse("{\"key\": \"app\", \"value\": {}}", None).unwrap();
        assert_eq!(cfg.generation().top_k, 20);
        assert_eq!(cfg.model().alias, crate::models::DEFAULT_ALIAS);
    }

    #[test]
    fn blank_and_comment_lines_are_skipped() {
        let cfg = Config::parse("\n# note\n{\"key\":\"a\",\"value\":1}\n", None).unwrap();
        assert_eq!(cfg.raw("a").unwrap().as_i64(), Some(1));
    }
}
