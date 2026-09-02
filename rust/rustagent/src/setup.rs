//! The AI setup: which on-device engine, which daemon, which cloud.
//!
//! Two brains, each with its own configuration:
//!
//! * **on-device** — the MLX engine when this build carries it, otherwise a
//!   local ollama daemon (`ollama serve`) holding the same model. Either way
//!   the weights are on this machine and nothing leaves it.
//! * **cloud** — ollama.com, or any host that is not this machine.
//!
//! Every value has three places it can come from, and the order matters:
//!
//! 1. the process environment — `ONDEVICE_MODEL=… agentd listen` wins for
//!    that run, which is what the tests and one-off experiments need;
//! 2. the `settings` table in the space — what the client's setup screen
//!    and `agentd config.set` write, and what survives a restart;
//! 3. `.env` beside the working directory, then the built-in default.
//!
//! [`Setup::describe`] reports every value *and where it came from*, so the
//! setup screen can say "from .env" next to a key rather than leaving the
//! operator to guess why a change in one place did not take.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::ollama::{self, Config};
use crate::store::Store;

/// One configurable value: its settings-table key, its environment name, and
/// what it means.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Key {
    /// The settings-table key, e.g. `ondevice.model`.
    pub name: &'static str,
    /// The environment variable that seeds it, e.g. `ONDEVICE_MODEL`.
    pub env: &'static str,
    pub default: &'static str,
    pub about: &'static str,
    /// Never echoed back in full.
    pub secret: bool,
}

pub const ONDEVICE_ENGINE: Key = Key {
    name: "ondevice.engine",
    env: "ONDEVICE_ENGINE",
    default: "auto",
    about: "auto | mlx | ollama | off",
    secret: false,
};
pub const ONDEVICE_HOST: Key = Key {
    name: "ondevice.host",
    env: "ONDEVICE_HOST",
    default: ollama::DEFAULT_LOCAL_HOST,
    about: "the local ollama daemon",
    secret: false,
};
pub const ONDEVICE_MODEL: Key = Key {
    name: "ondevice.model",
    env: "ONDEVICE_MODEL",
    default: ollama::DEFAULT_LOCAL_MODEL,
    about: "the tag the daemon answers with",
    secret: false,
};
pub const ONDEVICE_EMBED: Key = Key {
    name: "ondevice.embed",
    env: "ONDEVICE_EMBED",
    default: ollama::DEFAULT_EMBED,
    about: "the daemon's embedding model",
    secret: false,
};
pub const CLOUD_HOST: Key = Key {
    name: "cloud.host",
    env: "OLLAMA_HOST",
    default: ollama::DEFAULT_HOST,
    about: "ollama.com, or another host",
    secret: false,
};
pub const CLOUD_KEY: Key = Key {
    name: "cloud.key",
    env: "OLLAMA_API_KEY",
    default: "",
    about: "the ollama.com API key",
    secret: true,
};
pub const CLOUD_MODEL: Key = Key {
    name: "cloud.model",
    env: "OLLAMA_MODEL",
    default: ollama::DEFAULT_MODEL,
    about: "the cloud chat model",
    secret: false,
};
pub const CLOUD_EMBED: Key = Key {
    name: "cloud.embed",
    env: "OLLAMA_EMBED",
    default: ollama::DEFAULT_EMBED,
    about: "the cloud embedding model",
    secret: false,
};
pub const THINK: Key = Key {
    name: "think",
    env: "OLLAMA_THINK",
    default: "low",
    about: "low | medium | high | off",
    secret: false,
};

/// Every key there is, in the order the setup screen shows them.
pub const KEYS: &[Key] = &[
    ONDEVICE_ENGINE,
    ONDEVICE_HOST,
    ONDEVICE_MODEL,
    ONDEVICE_EMBED,
    CLOUD_HOST,
    CLOUD_KEY,
    CLOUD_MODEL,
    CLOUD_EMBED,
    THINK,
];

pub fn key(name: &str) -> Option<Key> {
    KEYS.iter().copied().find(|k| k.name == name)
}

/// Which on-device engine the operator wants.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Engine {
    /// MLX when this build carries it and the weights are on disk, the
    /// daemon otherwise. The default.
    Auto,
    /// The MLX engine only.
    Mlx,
    /// The local ollama daemon only.
    Ollama,
    /// No on-device brain at all — what the tests set.
    Off,
}

impl Engine {
    pub fn parse(s: &str) -> Option<Engine> {
        match s.trim().to_ascii_lowercase().as_str() {
            "auto" | "" => Some(Engine::Auto),
            "mlx" | "metal" => Some(Engine::Mlx),
            "ollama" | "daemon" => Some(Engine::Ollama),
            "off" | "none" | "no" | "false" | "0" => Some(Engine::Off),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Engine::Auto => "auto",
            Engine::Mlx => "mlx",
            Engine::Ollama => "ollama",
            Engine::Off => "off",
        }
    }
}

/// Where a value came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Source {
    /// Handed to this backend when it was opened — see [`Overrides`].
    Caller,
    Env,
    Space,
    DotEnv,
    Default,
}

/// Settings handed to one backend when it was opened, ahead of everything
/// else.
///
/// This exists because of where the backend runs. `agentd` is a child
/// process, so a caller configures it by putting variables on its command
/// line: they reach that process and nowhere else. The same backend
/// embedded in a client has no command line and no process of its own — it
/// is *in* the caller — so the equivalent cannot be the environment.
/// Writing to it would mean one library call quietly changing what every
/// other part of the host program reads, and worse: `setenv` on one thread
/// while another calls `getenv` is a data race, which is exactly the shape
/// an embedded backend has.
///
/// So the values are carried here instead, per backend, and consulted
/// before the process environment. Keyed by variable name — `OLLAMA_API_KEY`,
/// `ONDEVICE_ENGINE` — because that is what a caller already knows, and
/// what the command line took.
///
/// An empty value means "as if unset", which is how a blank on a command
/// line behaves: it shuts a key off without pretending to be one.
#[derive(Debug, Clone, Default)]
pub struct Overrides(std::collections::BTreeMap<String, String>);

impl Overrides {
    /// Read them from a JSON object. Rejects anything that is not a
    /// variable name rather than carrying it: a bad key here would become
    /// somebody else's bug to find.
    pub fn from_json(value: &serde_json::Value) -> Result<Self, String> {
        let object = value
            .as_object()
            .ok_or_else(|| "overrides must be a JSON object".to_string())?;
        let mut map = std::collections::BTreeMap::new();
        for (key, value) in object {
            if key.is_empty() || !key.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_') {
                return Err(format!("{key:?} is not a variable name"));
            }
            let text = match value {
                serde_json::Value::String(s) => s.clone(),
                serde_json::Value::Null => String::new(),
                other => other.to_string(),
            };
            map.insert(key.clone(), text);
        }
        Ok(Self(map))
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    /// What this override says, if it says anything. `None` means "ask the
    /// environment"; `Some("")` means "there is no value", which is not the
    /// same thing.
    pub fn get(&self, name: &str) -> Option<&str> {
        self.0.get(name).map(String::as_str)
    }

    /// The override if there is one, else the process environment. Every
    /// read of a variable in this crate goes through here, so a caller that
    /// overrode something cannot be undercut by the environment behind it.
    pub fn var(&self, name: &str) -> Option<String> {
        match self.get(name) {
            Some(value) => Some(value.to_string()),
            None => std::env::var(name).ok(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Resolved {
    pub value: String,
    pub source: Source,
}

/// The whole setup, resolved.
#[derive(Debug, Clone)]
pub struct Setup {
    values: Vec<(Key, Resolved)>,
}

impl Setup {
    /// Resolve every key from the environment, the space, and `.env`.
    pub fn load(store: &Store) -> Self {
        Self::load_with(store, &Overrides::default())
    }

    /// The same, with values the caller handed this backend when it opened.
    /// They come first — ahead of the process environment — because they
    /// are what this backend was asked for, and the environment is only
    /// what the host process happens to be carrying.
    pub fn load_with(store: &Store, overrides: &Overrides) -> Self {
        let dotenv = ollama::read_dotenv();
        let space = |k: &Key| store.setting(k.name).ok().flatten();
        Self::resolve_with(
            |k| overrides.get(k.env).map(str::to_string),
            |k| std::env::var(k.env).ok(),
            space,
            |k| dotenv.get(k.env).cloned(),
        )
    }

    /// The environment and `.env` only — a setup with no space behind it.
    pub fn from_env() -> Self {
        let dotenv = ollama::read_dotenv();
        Self::resolve(
            |k| std::env::var(k.env).ok(),
            |_| None,
            |k| dotenv.get(k.env).cloned(),
        )
    }

    /// Pure, so the precedence is testable without an environment: the first
    /// non-empty answer wins, in the order env → space → .env → default.
    pub fn resolve(
        env: impl Fn(&Key) -> Option<String>,
        space: impl Fn(&Key) -> Option<String>,
        dotenv: impl Fn(&Key) -> Option<String>,
    ) -> Self {
        Self::resolve_with(|_| None, env, space, dotenv)
    }

    /// The same, with the caller's overrides ahead of the environment:
    /// caller → env → space → .env → default.
    ///
    /// An override that is present but blank is *not* skipped on to the
    /// next source — it is the caller saying there is no value, which is
    /// how a blank on `agentd`'s command line behaves. Falling through
    /// would let a key in `.env` answer a caller who had explicitly shut
    /// the cloud off.
    pub fn resolve_with(
        caller: impl Fn(&Key) -> Option<String>,
        env: impl Fn(&Key) -> Option<String>,
        space: impl Fn(&Key) -> Option<String>,
        dotenv: impl Fn(&Key) -> Option<String>,
    ) -> Self {
        let clean = |v: Option<String>| v.map(|s| s.trim().to_string()).filter(|s| !s.is_empty());
        let values = KEYS
            .iter()
            .map(|k| {
                let (value, source) = if let Some(v) = caller(k) {
                    (v.trim().to_string(), Source::Caller)
                } else if let Some(v) = clean(env(k)) {
                    (v, Source::Env)
                } else if let Some(v) = clean(space(k)) {
                    (v, Source::Space)
                } else if let Some(v) = clean(dotenv(k)) {
                    (v, Source::DotEnv)
                } else {
                    (k.default.to_string(), Source::Default)
                };
                (*k, Resolved { value, source })
            })
            .collect();
        Self { values }
    }

    pub fn get(&self, key: Key) -> &Resolved {
        self.values
            .iter()
            .find(|(k, _)| k.name == key.name)
            .map(|(_, r)| r)
            .expect("every key is resolved")
    }

    pub fn value(&self, key: Key) -> &str {
        &self.get(key).value
    }

    pub fn engine(&self) -> Engine {
        Engine::parse(self.value(ONDEVICE_ENGINE)).unwrap_or(Engine::Auto)
    }

    /// The local daemon, as an ollama client config. `None` when the engine
    /// setting rules the daemon out.
    pub fn local(&self) -> Option<Config> {
        if matches!(self.engine(), Engine::Off | Engine::Mlx) {
            return None;
        }
        Some(Config {
            host: self.value(ONDEVICE_HOST).trim_end_matches('/').to_string(),
            api_key: None,
            model: self.value(ONDEVICE_MODEL).to_string(),
            embed_model: self.value(ONDEVICE_EMBED).to_string(),
            think: ollama::parse_think(self.value(THINK)),
            ..Config::default()
        })
    }

    /// ollama.com — or whatever the cloud host is — as a client config.
    pub fn cloud(&self) -> Config {
        let key = self.value(CLOUD_KEY);
        Config {
            host: self.value(CLOUD_HOST).trim_end_matches('/').to_string(),
            api_key: (!key.is_empty()).then(|| key.to_string()),
            model: self.value(CLOUD_MODEL).to_string(),
            embed_model: self.value(CLOUD_EMBED).to_string(),
            think: ollama::parse_think(self.value(THINK)),
            ..Config::default()
        }
    }

    /// Every value and its source, for the setup screen. A secret is
    /// reported as set or not, never as itself.
    pub fn describe(&self) -> Value {
        let mut out = serde_json::Map::new();
        for (k, r) in &self.values {
            let shown = if k.secret {
                if r.value.is_empty() {
                    String::new()
                } else {
                    mask(&r.value)
                }
            } else {
                r.value.clone()
            };
            out.insert(
                k.name.to_string(),
                json!({
                    "value": shown,
                    "set": !r.value.is_empty(),
                    "source": r.source,
                    "env": k.env,
                    "default": k.default,
                    "about": k.about,
                    "secret": k.secret,
                }),
            );
        }
        Value::Object(out)
    }
}

/// Enough of a key to recognise it, and no more. Asterisks rather than
/// bullets: the client's 6×8 font is ASCII, and a glyph it lacks draws as
/// `?`, which reads as a broken value rather than a hidden one.
pub fn mask(secret: &str) -> String {
    let n = secret.chars().count();
    if n <= 8 {
        return "*".repeat(n);
    }
    let tail: String = secret.chars().skip(n - 4).collect();
    format!("{}{tail}", "*".repeat(8))
}

/// Check a value before it is written. The engine word and the think level
/// are closed sets; a host has to look like one; the rest is free text.
pub fn validate(key: Key, value: &str) -> Result<(), String> {
    let v = value.trim();
    if v.is_empty() {
        return Ok(());
    }
    if key.name == ONDEVICE_ENGINE.name && Engine::parse(v).is_none() {
        return Err(format!("no engine {v:?} — use auto, mlx, ollama or off"));
    }
    if key.name == THINK.name
        && !matches!(
            v.to_ascii_lowercase().as_str(),
            "low" | "medium" | "high" | "off" | "on" | "true" | "false"
        )
    {
        return Err(format!(
            "no think level {v:?} — use low, medium, high or off"
        ));
    }
    if (key.name == ONDEVICE_HOST.name || key.name == CLOUD_HOST.name)
        && !(v.starts_with("http://") || v.starts_with("https://"))
    {
        return Err(format!("{} must start with http:// or https://", key.name));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn none(_: &Key) -> Option<String> {
        None
    }

    #[test]
    fn the_environment_beats_the_space_beats_dotenv_beats_the_default() {
        let s = Setup::resolve(
            |k| (k.name == "ondevice.model").then(|| "from-env".to_string()),
            |k| (k.name != "cloud.model").then(|| "from-space".to_string()),
            |_| Some("from-dotenv".to_string()),
        );
        assert_eq!(s.value(ONDEVICE_MODEL), "from-env");
        assert_eq!(s.get(ONDEVICE_MODEL).source, Source::Env);
        assert_eq!(s.value(ONDEVICE_HOST), "from-space");
        assert_eq!(s.get(ONDEVICE_HOST).source, Source::Space);
        assert_eq!(s.value(CLOUD_MODEL), "from-dotenv");
        assert_eq!(s.get(CLOUD_MODEL).source, Source::DotEnv);

        let bare = Setup::resolve(none, none, none);
        assert_eq!(bare.value(ONDEVICE_MODEL), ollama::DEFAULT_LOCAL_MODEL);
        assert_eq!(bare.value(ONDEVICE_HOST), ollama::DEFAULT_LOCAL_HOST);
        assert_eq!(bare.get(CLOUD_KEY).source, Source::Default);
        assert_eq!(bare.engine(), Engine::Auto);
    }

    #[test]
    fn a_blank_value_falls_through_rather_than_winning() {
        // The tests blank OLLAMA_API_KEY to shut the cloud; a blank must be
        // "unset", not "the empty string wins".
        let s = Setup::resolve(
            |_| Some("   ".to_string()),
            |k| (k.name == "cloud.key").then(|| "sk-space".to_string()),
            none,
        );
        assert_eq!(s.value(CLOUD_KEY), "sk-space");
        assert_eq!(s.cloud().api_key.as_deref(), Some("sk-space"));
    }

    #[test]
    fn the_engine_word_decides_whether_there_is_a_daemon_at_all() {
        let with = |engine: &str| {
            let e = engine.to_string();
            Setup::resolve(
                move |k| (k.name == "ondevice.engine").then(|| e.clone()),
                none,
                none,
            )
        };
        assert!(with("auto").local().is_some());
        assert!(with("ollama").local().is_some());
        assert!(with("mlx").local().is_none());
        assert!(with("off").local().is_none());
        assert_eq!(with("nonsense").engine(), Engine::Auto);

        let local = with("auto").local().unwrap();
        assert_eq!(local.host, "http://localhost:11434");
        assert_eq!(local.model, "qwen3.8:27b-mlx");
        assert!(local.api_key.is_none());
        assert_eq!(local.provenance(), ollama::Provenance::OnDevice);
    }

    #[test]
    fn a_secret_is_described_but_never_shown() {
        let s = Setup::resolve(
            |k| (k.name == "cloud.key").then(|| "sk-0123456789abcdef".to_string()),
            none,
            none,
        );
        let d = s.describe();
        assert_eq!(d["cloud.key"]["set"], json!(true));
        assert_eq!(d["cloud.key"]["value"], json!("********cdef"));
        assert_eq!(d["cloud.key"]["source"], json!("env"));
        assert_eq!(d["ondevice.model"]["value"], json!("qwen3.8:27b-mlx"));
        assert_eq!(d["ondevice.model"]["source"], json!("default"));
        assert_eq!(mask("short"), "*****");
    }

    #[test]
    fn values_are_checked_before_they_are_kept() {
        assert!(validate(ONDEVICE_ENGINE, "ollama").is_ok());
        assert!(validate(ONDEVICE_ENGINE, "gpu").is_err());
        assert!(validate(ONDEVICE_HOST, "http://localhost:11434").is_ok());
        assert!(validate(ONDEVICE_HOST, "localhost:11434").is_err());
        assert!(validate(THINK, "HIGH").is_ok());
        assert!(validate(THINK, "lots").is_err());
        assert!(validate(CLOUD_MODEL, "anything:at-all").is_ok());
        assert!(
            validate(CLOUD_HOST, "").is_ok(),
            "blank clears the override"
        );
        assert!(key("cloud.model").is_some());
        assert!(key("cloud.password").is_none());
    }
}
