//! ollama.com, or a daemon on this machine. Same API either way.
//!
//! The same client serves both brains. As the **cloud** it is configured by
//! the `OLLAMA_*` names, which is where the LOVE client's `.env` puts them
//! too; as the **on-device** daemon it is the `ONDEVICE_*` set, defaulting
//! to `http://localhost:11434` and the same `qwen3.8:27b-mlx` tag the MLX
//! engine runs. [`crate::setup`] resolves both.
//!
//! ```text
//! OLLAMA_API_KEY   ollama.com key. Not needed for a local daemon.
//! OLLAMA_HOST      https://ollama.com (default)
//! OLLAMA_MODEL     the cloud chat model, e.g. gpt-oss:20b
//! OLLAMA_EMBED     the embedding model, e.g. embeddinggemma
//! OLLAMA_THINK     low | medium | high | off
//! ONDEVICE_HOST    http://localhost:11434 (default)
//! ONDEVICE_MODEL   qwen3.8:27b-mlx (default)
//! ```
//!
//! Whether prompts leave the machine is not a detail: [`Config::provenance`]
//! answers it in one word, and the boot report says it out loud.

use std::time::Duration;

use anyhow::{anyhow, bail, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

pub const DEFAULT_HOST: &str = "https://ollama.com";
pub const DEFAULT_MODEL: &str = "gpt-oss:20b";
pub const DEFAULT_EMBED: &str = "embeddinggemma";
/// Where `ollama serve` listens by default.
pub const DEFAULT_LOCAL_HOST: &str = "http://localhost:11434";
/// The on-device model, by the tag the daemon knows it by — the same name
/// the MLX engine resolves, so the two halves agree on what "the model" is.
pub const DEFAULT_LOCAL_MODEL: &str = "qwen3.8:27b-mlx";
/// How long a daemon gets to say whether it is there. A turn waits ninety
/// seconds; a health check must not.
pub const PROBE_TIMEOUT: Duration = Duration::from_secs(3);

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Provenance {
    /// The weights are on this machine. Nothing leaves it.
    OnDevice,
    /// A local daemon, but the tag is a `-cloud` one: it relays.
    CloudRelay,
    /// Somebody else's machine.
    Cloud,
}

impl Provenance {
    pub fn label(&self) -> &'static str {
        match self {
            Provenance::OnDevice => "ON-DEVICE",
            Provenance::CloudRelay => "CLOUD RELAY",
            Provenance::Cloud => "CLOUD AI",
        }
    }

    pub fn leaves_the_machine(&self) -> bool {
        !matches!(self, Provenance::OnDevice)
    }
}

/// One message on the wire.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Message {
    pub role: String,
    pub content: String,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub tool_calls: Option<Vec<ToolCall>>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub tool_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub thinking: Option<String>,
}

impl Message {
    pub fn new(role: &str, content: impl Into<String>) -> Self {
        Self {
            role: role.to_string(),
            content: content.into(),
            tool_calls: None,
            tool_name: None,
            thinking: None,
        }
    }
    pub fn system(c: impl Into<String>) -> Self {
        Self::new("system", c)
    }
    pub fn user(c: impl Into<String>) -> Self {
        Self::new("user", c)
    }
    pub fn assistant(c: impl Into<String>) -> Self {
        Self::new("assistant", c)
    }
    pub fn tool(name: &str, c: impl Into<String>) -> Self {
        let mut m = Self::new("tool", c);
        m.tool_name = Some(name.to_string());
        m
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolCall {
    #[serde(rename = "function")]
    pub function: ToolCallFunction,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolCallFunction {
    pub name: String,
    /// ollama sends this as an object; some models send a JSON string.
    #[serde(default)]
    pub arguments: Value,
}

impl ToolCallFunction {
    /// The arguments as an object, whichever of the two shapes arrived.
    pub fn args(&self) -> Value {
        match &self.arguments {
            Value::String(s) => serde_json::from_str(s).unwrap_or_else(|_| json!({})),
            Value::Object(_) => self.arguments.clone(),
            _ => json!({}),
        }
    }
}

#[derive(Debug, Clone)]
pub struct Config {
    pub host: String,
    pub api_key: Option<String>,
    pub model: String,
    pub embed_model: String,
    /// `Some("low")`, or `None` for thinking off.
    pub think: Option<String>,
    pub timeout: Duration,
    pub num_predict: usize,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            host: DEFAULT_HOST.into(),
            api_key: None,
            model: DEFAULT_MODEL.into(),
            embed_model: DEFAULT_EMBED.into(),
            think: Some("low".into()),
            timeout: Duration::from_secs(90),
            num_predict: 600,
        }
    }
}

impl Config {
    /// The cloud, from the environment. Also reads a `.env` beside the
    /// working directory if one is there, because that is where the LOVE
    /// client keeps its key and the two should not need two copies. The
    /// backend goes through [`crate::setup::Setup`] instead, which adds the
    /// space's own settings on top.
    pub fn from_env() -> Self {
        crate::setup::Setup::from_env().cloud()
    }

    /// A host on this machine runs the weights here; anything else is a
    /// relay. A local daemon can still proxy ollama.com, and those tags carry
    /// a `-cloud` suffix.
    pub fn provenance(&self) -> Provenance {
        let h = self.host.to_lowercase();
        let on_box = ["localhost", "127.0.0.1", "0.0.0.0", "[::1]", "::1"]
            .iter()
            .any(|needle| h.contains(needle));
        if !on_box {
            return Provenance::Cloud;
        }
        if self.model.to_lowercase().ends_with("-cloud") {
            return Provenance::CloudRelay;
        }
        Provenance::OnDevice
    }

    /// Can a turn actually be sent? A cloud host with no key cannot.
    pub fn usable(&self) -> std::result::Result<(), &'static str> {
        if self.provenance() == Provenance::Cloud && self.api_key.is_none() {
            return Err("no OLLAMA_API_KEY, and the host is not this machine");
        }
        Ok(())
    }
}

/// `OLLAMA_THINK` takes a reasoning level or an off switch. `gpt-oss` ignores
/// `think=false` and reasons anyway, so `low` is the useful default: it keeps
/// the hidden preamble short instead of letting it eat the token budget.
pub fn parse_think(v: &str) -> Option<String> {
    match v.trim().to_lowercase().as_str() {
        "low" | "medium" | "high" => Some(v.trim().to_lowercase()),
        "" | "true" | "on" | "yes" => Some("low".into()),
        _ => None,
    }
}

pub(crate) fn read_dotenv() -> std::collections::HashMap<String, String> {
    let mut out = std::collections::HashMap::new();
    for candidate in [".env", "robots/.env"] {
        let Ok(text) = std::fs::read_to_string(candidate) else {
            continue;
        };
        for line in text.lines() {
            let line = line.trim().trim_start_matches("export ").trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let Some((k, v)) = line.split_once('=') else {
                continue;
            };
            let v = v.trim();
            let v = if v.len() >= 2
                && ((v.starts_with('"') && v.ends_with('"'))
                    || (v.starts_with('\'') && v.ends_with('\'')))
            {
                v[1..v.len() - 1].to_string()
            } else {
                v.split('#').next().unwrap_or("").trim().to_string()
            };
            out.entry(k.trim().to_string()).or_insert(v);
        }
        break;
    }
    out
}

/// The reply to one `/api/chat`.
#[derive(Debug, Clone)]
pub struct Reply {
    pub message: Message,
    pub done_reason: String,
}

impl Reply {
    pub fn tool_calls(&self) -> &[ToolCall] {
        self.message.tool_calls.as_deref().unwrap_or(&[])
    }
    pub fn text(&self) -> &str {
        self.message.content.trim()
    }
}

pub struct Ollama {
    cfg: Config,
    agent: ureq::Agent,
}

impl Clone for Ollama {
    fn clone(&self) -> Self {
        Self::new(self.cfg.clone())
    }
}

impl Ollama {
    pub fn new(cfg: Config) -> Self {
        let agent: ureq::Agent = ureq::Agent::config_builder()
            .timeout_global(Some(cfg.timeout))
            // Read the body of a 4xx rather than throwing it away: ollama puts
            // the reason ("model not found") in there.
            .http_status_as_error(false)
            .build()
            .into();
        Self { cfg, agent }
    }

    pub fn from_env() -> Self {
        Self::new(Config::from_env())
    }

    pub fn config(&self) -> &Config {
        &self.cfg
    }

    fn post(&self, path: &str, payload: &Value) -> Result<Value> {
        let url = format!("{}{}", self.cfg.host, path);
        let mut req = self
            .agent
            .post(&url)
            .header("Content-Type", "application/json");
        if let Some(key) = &self.cfg.api_key {
            req = req.header("Authorization", format!("Bearer {key}"));
        }
        let mut res = req.send_json(payload).map_err(|e| anyhow!("{path}: {e}"))?;
        let status = res.status().as_u16();
        let body: Value = res
            .body_mut()
            .read_json()
            .map_err(|e| anyhow!("{path}: unreadable reply ({status}): {e}"))?;
        if let Some(err) = body.get("error") {
            let msg = err
                .as_str()
                .map(str::to_string)
                .unwrap_or_else(|| err.to_string());
            bail!("{path}: {msg}");
        }
        if !(200..300).contains(&status) {
            bail!("{path}: HTTP {status}");
        }
        Ok(body)
    }

    /// One non-streaming turn. `tools` is the function-call schema; the reply
    /// carries `tool_calls` when the model wants to act before it answers.
    pub fn chat(&self, messages: &[Message], tools: &[Value]) -> Result<Reply> {
        self.cfg.usable().map_err(|e| anyhow!(e))?;
        let mut payload = json!({
            "model": self.cfg.model,
            "messages": messages,
            "stream": false,
            "options": { "temperature": 0.7, "num_predict": self.cfg.num_predict },
        });
        match &self.cfg.think {
            Some(level) => payload["think"] = json!(level),
            None => payload["think"] = json!(false),
        }
        if !tools.is_empty() {
            payload["tools"] = json!(tools);
        }

        let body = self.post("/api/chat", &payload)?;
        let message: Message =
            serde_json::from_value(body.get("message").cloned().unwrap_or_else(|| json!({})))
                .unwrap_or_else(|_| Message::assistant(""));
        Ok(Reply {
            message,
            done_reason: body
                .get("done_reason")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string(),
        })
    }

    /// The same turn, streamed: ollama answers `/api/chat` with one JSON
    /// object per line when `stream` is true, each carrying the next slice
    /// of the message. The pieces are handed to `sink` as they land and
    /// also accumulated, so the caller still gets one whole [`Reply`] at
    /// the end and nothing downstream has to care that it arrived in bits.
    ///
    /// A `false` from the sink stops the read, which drops the connection
    /// and so the generation with it.
    pub fn chat_stream(
        &self,
        messages: &[Message],
        tools: &[Value],
        sink: &mut crate::harness::Sink<'_>,
    ) -> Result<Reply> {
        use crate::harness::Chunk;
        use std::io::BufRead;

        self.cfg.usable().map_err(|e| anyhow!(e))?;
        let mut payload = json!({
            "model": self.cfg.model,
            "messages": messages,
            "stream": true,
            "options": { "temperature": 0.7, "num_predict": self.cfg.num_predict },
        });
        match &self.cfg.think {
            Some(level) => payload["think"] = json!(level),
            None => payload["think"] = json!(false),
        }
        if !tools.is_empty() {
            payload["tools"] = json!(tools);
        }

        let url = format!("{}/api/chat", self.cfg.host);
        let mut req = self
            .agent
            .post(&url)
            .header("Content-Type", "application/json");
        if let Some(key) = &self.cfg.api_key {
            req = req.header("Authorization", format!("Bearer {key}"));
        }
        let mut res = req
            .send_json(&payload)
            .map_err(|e| anyhow!("/api/chat: {e}"))?;
        let status = res.status().as_u16();

        let mut whole = Message::assistant(String::new());
        let mut thinking = String::new();
        let mut done_reason = String::new();
        let mut stopped = false;
        let reader = std::io::BufReader::new(res.body_mut().as_reader());
        for line in reader.lines() {
            let line = line.map_err(|e| anyhow!("/api/chat: {e}"))?;
            let line = line.trim();
            if line.is_empty() {
                continue;
            }
            let frame: Value =
                serde_json::from_str(line).map_err(|e| anyhow!("/api/chat: bad frame: {e}"))?;
            if let Some(err) = frame.get("error") {
                let msg = err
                    .as_str()
                    .map(str::to_string)
                    .unwrap_or_else(|| err.to_string());
                bail!("/api/chat: {msg}");
            }
            if let Some(part) = frame.get("message") {
                if let Some(text) = part.get("content").and_then(Value::as_str) {
                    if !text.is_empty() {
                        whole.content.push_str(text);
                        if !sink(Chunk::Token(text)) {
                            stopped = true;
                        }
                    }
                }
                if let Some(text) = part.get("thinking").and_then(Value::as_str) {
                    if !text.is_empty() {
                        thinking.push_str(text);
                        if !sink(Chunk::Reasoning(text)) {
                            stopped = true;
                        }
                    }
                }
                // Tool calls arrive whole, in the frame that carries them.
                if let Some(calls) = part.get("tool_calls") {
                    if let Ok(calls) = serde_json::from_value::<Vec<ToolCall>>(calls.clone()) {
                        if !calls.is_empty() {
                            whole.tool_calls = Some(calls);
                        }
                    }
                }
            }
            if let Some(reason) = frame.get("done_reason").and_then(Value::as_str) {
                done_reason = reason.to_string();
            }
            if stopped || frame.get("done").and_then(Value::as_bool) == Some(true) {
                break;
            }
        }
        if !(200..300).contains(&status) {
            bail!("/api/chat: HTTP {status}");
        }
        if !thinking.is_empty() {
            whole.thinking = Some(thinking);
        }
        if stopped && done_reason.is_empty() {
            done_reason = "interrupted".into();
        }
        Ok(Reply {
            message: whole,
            done_reason,
        })
    }

    /// Ask the daemon to load the model into memory without generating
    /// anything: `/api/chat` with no messages is ollama's documented way to
    /// say "get ready". The first real turn then answers at once.
    pub fn load(&self) -> Result<()> {
        self.cfg.usable().map_err(|e| anyhow!(e))?;
        let payload = json!({ "model": self.cfg.model, "messages": [], "stream": false });
        self.post("/api/chat", &payload).map(|_| ())
    }

    /// `/api/embed`. Returns one vector per input, in order.
    pub fn embed(&self, model: &str, inputs: &[String]) -> Result<Vec<Vec<f32>>> {
        if inputs.is_empty() {
            return Ok(Vec::new());
        }
        self.cfg.usable().map_err(|e| anyhow!(e))?;
        let body = self.post("/api/embed", &json!({ "model": model, "input": inputs }))?;
        parse_embeddings(&body, inputs.len())
    }

    /// What is actually answering: parameters, quantization, context window.
    pub fn show(&self) -> Result<Value> {
        self.post("/api/show", &json!({ "model": self.cfg.model }))
    }

    /// The tags the host has pulled — `/api/tags`, on a short leash.
    ///
    /// This is the one call made *before* the operator asks for a turn, so it
    /// waits [`PROBE_TIMEOUT`] and not the ninety seconds a generation may.
    pub fn tags(&self) -> Result<Vec<String>> {
        let url = format!("{}/api/tags", self.cfg.host);
        let mut req = self
            .agent
            .get(&url)
            .config()
            .timeout_global(Some(PROBE_TIMEOUT))
            .build();
        if let Some(key) = &self.cfg.api_key {
            req = req.header("Authorization", format!("Bearer {key}"));
        }
        let mut res = req.call().map_err(|e| anyhow!("/api/tags: {e}"))?;
        let status = res.status().as_u16();
        if !(200..300).contains(&status) {
            bail!("/api/tags: HTTP {status}");
        }
        let body: Value = res
            .body_mut()
            .read_json()
            .map_err(|e| anyhow!("/api/tags: unreadable reply: {e}"))?;
        Ok(body
            .get("models")
            .and_then(Value::as_array)
            .map(|list| {
                list.iter()
                    .filter_map(|m| {
                        m.get("name")
                            .or_else(|| m.get("model"))
                            .and_then(Value::as_str)
                            .map(str::to_string)
                    })
                    .collect()
            })
            .unwrap_or_default())
    }

    /// Is there a daemon at the host, and does it hold the model? The `Err`
    /// is the sentence the health report shows, with the command that fixes
    /// it — because "on-device unavailable" on its own sends the operator
    /// off to read the source.
    pub fn probe(&self) -> std::result::Result<(), String> {
        let host = &self.cfg.host;
        let model = &self.cfg.model;
        match self.tags() {
            Ok(tags) if model_listed(&tags, model) => Ok(()),
            Ok(_) => Err(format!(
                "{model} is not pulled on {host} — run `ollama pull {model}`"
            )),
            Err(_) => Err(format!("no ollama daemon at {host} — run `ollama serve`")),
        }
    }

    /// The boot report, as the LOVE client draws it.
    pub fn report(&self) -> Vec<(String, &'static str)> {
        let mut out = Vec::new();
        let prov = self.cfg.provenance();
        if let Err(why) = self.cfg.usable() {
            out.push((format!("OFFLINE  {}", why.to_uppercase()), "warn"));
            out.push(("LOCAL ARCHIVE ONLY. NO MODEL, SIR.".into(), "info"));
            return out;
        }
        let host = self
            .cfg
            .host
            .trim_start_matches("https://")
            .trim_start_matches("http://")
            .trim_end_matches('/')
            .to_uppercase();
        out.push((
            format!("{}  {host}", prov.label()),
            if prov.leaves_the_machine() {
                "info"
            } else {
                "good"
            },
        ));
        out.push((format!("MODEL {}", self.cfg.model.to_uppercase()), "info"));
        out.push((
            format!("EMBED {}", self.cfg.embed_model.to_uppercase()),
            "info",
        ));
        if prov.leaves_the_machine() {
            out.push(("CAUTION  PROMPTS LEAVE THIS MACHINE".into(), "warn"));
        }
        out
    }
}

/// Does a tag list carry the model? `qwen3.8` and `qwen3.8:latest` are the
/// same tag, and ollama lists whichever spelling it was pulled by.
pub fn model_listed(tags: &[String], model: &str) -> bool {
    let want = model.trim().to_lowercase();
    let bare = |s: &str| s.strip_suffix(":latest").unwrap_or(s).to_string();
    let want_bare = bare(&want);
    tags.iter().any(|t| {
        let t = t.to_lowercase();
        t == want || bare(&t) == want_bare
    })
}

/// `/api/embed` answers `{"embeddings": [[...]]}`; the older `/api/embeddings`
/// answered `{"embedding": [...]}`. Read either.
pub fn parse_embeddings(body: &Value, expected: usize) -> Result<Vec<Vec<f32>>> {
    let read = |v: &Value| -> Vec<f32> {
        v.as_array()
            .map(|a| {
                a.iter()
                    .filter_map(|x| x.as_f64().map(|f| f as f32))
                    .collect()
            })
            .unwrap_or_default()
    };
    if let Some(list) = body.get("embeddings").and_then(Value::as_array) {
        let out: Vec<Vec<f32>> = list.iter().map(read).collect();
        if out.len() != expected {
            bail!("asked for {expected} embeddings, got {}", out.len());
        }
        return Ok(out);
    }
    if let Some(one) = body.get("embedding") {
        return Ok(vec![read(one)]);
    }
    bail!("no embeddings in the reply")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn where_the_prompt_goes_is_decided_by_host_and_tag() {
        let cloud = Config {
            host: "https://ollama.com".into(),
            ..Default::default()
        };
        assert_eq!(cloud.provenance(), Provenance::Cloud);
        assert!(cloud.provenance().leaves_the_machine());

        let local = Config {
            host: "http://localhost:11434".into(),
            model: "qwen3:8b".into(),
            ..Default::default()
        };
        assert_eq!(local.provenance(), Provenance::OnDevice);
        assert!(!local.provenance().leaves_the_machine());

        let relay = Config {
            model: "gpt-oss:120b-cloud".into(),
            ..local.clone()
        };
        assert_eq!(relay.provenance(), Provenance::CloudRelay);
        assert!(relay.provenance().leaves_the_machine());
    }

    #[test]
    fn a_cloud_host_without_a_key_refuses_before_it_dials() {
        let mut cfg = Config::default();
        assert!(cfg.usable().is_err());
        cfg.api_key = Some("k".into());
        assert!(cfg.usable().is_ok());

        let local = Config {
            host: "http://localhost:11434".into(),
            api_key: None,
            ..Default::default()
        };
        assert!(local.usable().is_ok(), "a local daemon needs no key");
    }

    #[test]
    fn think_levels_and_the_off_switch() {
        assert_eq!(parse_think("low").as_deref(), Some("low"));
        assert_eq!(parse_think("HIGH").as_deref(), Some("high"));
        assert_eq!(parse_think("").as_deref(), Some("low"));
        assert_eq!(parse_think("off"), None);
        assert_eq!(parse_think("false"), None);
    }

    #[test]
    fn tool_arguments_arrive_as_an_object_or_as_a_string() {
        let as_object: ToolCallFunction =
            serde_json::from_str(r#"{"name":"x","arguments":{"a":1}}"#).unwrap();
        assert_eq!(as_object.args()["a"], 1);

        let as_string: ToolCallFunction =
            serde_json::from_str(r#"{"name":"x","arguments":"{\"a\":2}"}"#).unwrap();
        assert_eq!(as_string.args()["a"], 2);

        let missing: ToolCallFunction = serde_json::from_str(r#"{"name":"x"}"#).unwrap();
        assert!(missing.args().is_object());
    }

    #[test]
    fn a_tag_is_found_with_or_without_its_latest_suffix() {
        let tags: Vec<String> = ["qwen3.8:27b-mlx", "gemma4:latest", "Qwen3.6:latest"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        assert!(model_listed(&tags, "qwen3.8:27b-mlx"));
        assert!(model_listed(&tags, "gemma4"));
        assert!(model_listed(&tags, "gemma4:latest"));
        assert!(model_listed(&tags, "qwen3.6"));
        assert!(!model_listed(&tags, "qwen3.8"));
        assert!(!model_listed(&tags, "qwen3.8:8b"));
        assert!(!model_listed(&[], "gemma4"));
    }

    #[test]
    fn a_probe_of_nothing_names_the_daemon_and_the_fix() {
        // Port 9 is discard; nothing answers HTTP there, and the probe must
        // come back in the probe timeout with the `ollama serve` hint.
        let cfg = Config {
            host: "http://127.0.0.1:9".into(),
            model: "qwen3.8:27b-mlx".into(),
            ..Default::default()
        };
        let started = std::time::Instant::now();
        let why = Ollama::new(cfg).probe().unwrap_err();
        assert!(why.contains("no ollama daemon"), "{why}");
        assert!(why.contains("ollama serve"), "{why}");
        assert!(started.elapsed() < PROBE_TIMEOUT + Duration::from_secs(2));
    }

    #[test]
    fn both_shapes_of_embedding_reply_are_read() {
        let batch = serde_json::json!({"embeddings": [[1.0, 0.0], [0.0, 1.0]]});
        assert_eq!(parse_embeddings(&batch, 2).unwrap().len(), 2);
        assert!(parse_embeddings(&batch, 3).is_err());

        let single = serde_json::json!({"embedding": [1.0, 2.0, 3.0]});
        assert_eq!(
            parse_embeddings(&single, 1).unwrap()[0],
            vec![1.0, 2.0, 3.0]
        );

        assert!(parse_embeddings(&serde_json::json!({}), 1).is_err());
    }
}
