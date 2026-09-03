//! The wire between the LOVE client and this backend: one JSON object in, one
//! JSON object out.
//!
//! ```json
//! {"op":"chat","agent":"coding","text":"why won't this borrow?"}
//! {"ok":true,"data":{"reply":"…","agent":{…},"tools":[…]}}
//! ```
//!
//! It is a request/response protocol and not a C ABI on purpose: LOVE 11 has
//! no way to call a blocking function without stopping the frame, so the
//! client already runs everything through a worker thread and a pipe. A line
//! of JSON is the cheapest thing to put through that pipe, it is readable in a
//! terminal, and `agentd` can be driven by hand while the UI is being built.
//!
//! Every reply has `ok`. A failure is `{"ok":false,"error":"…"}` and never a
//! non-zero exit, because half the callers are a Lua thread that would rather
//! read a sentence than a signal.

use anyhow::{anyhow, Result};
use serde_json::{json, Value};

use crate::agent::Seed;
use crate::context::{Kind, NewItem};
use crate::embed::{Embedder, Fallback, HashEmbedder, OllamaEmbedder};
use crate::harness::{Brain, Harness, LocalBrain};
use crate::ollama::{Message, Ollama};
use crate::provider::{effective, Effective, Provider};
use crate::router;
use crate::search::{self, Mode, Scope};
use crate::setup::{self, Engine, Overrides, Setup};
use crate::space::Space;
use crate::store::Store;

pub struct Backend {
    pub store: Store,
    /// Settings handed to this backend when it was opened, ahead of the
    /// process environment. Empty for a daemon, which has a command line of
    /// its own; filled in for an embedded one, which does not.
    overrides: Overrides,
    /// Everything that a `config.set` can change: the two ollama clients,
    /// the embedder in front of them, and the daemon probe. Behind a mutex
    /// so the setup screen can rewire a running daemon; the dispatcher is
    /// one thread, so it is never contended.
    ai: std::sync::Mutex<Ai>,
    /// The on-device engine, when this build carries one and the model alias
    /// resolved. Loading is lazy; holding this costs nothing.
    #[cfg(feature = "mlx")]
    mlx: Option<crate::ondevice::MlxBrain>,
    /// Why `mlx` is `None`, when it is.
    #[cfg(feature = "mlx")]
    mlx_why: String,
}

/// What [`Backend::with_brain`] does when no model can answer: refuse, or
/// fall back to the archive.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Offline {
    /// A raw model call: there is no model, so there is no answer.
    Refuse,
    /// A turn: answer out of the archive and say the link is down.
    Archive,
}

/// The configurable half of the backend — see [`Backend::ai`].
struct Ai {
    setup: Setup,
    embedder: std::sync::Arc<dyn Embedder>,
    /// The same object as `embedder` when there is a remote one to fall back
    /// from, so `health` can say whether it has.
    fallback: Option<std::sync::Arc<Fallback>>,
    /// `None` when there is no key for a cloud host: the cloud path is shut.
    cloud: Option<Ollama>,
    cloud_why: String,
    /// The local daemon, when the engine setting allows one. Configured is
    /// not the same as answering: `probe` says whether it is.
    local: Option<Ollama>,
    local_why: String,
    /// The last `/api/tags` answer and when it was taken. A turn, a health
    /// check and the chip all ask; the daemon is asked once per
    /// [`PROBE_TTL`].
    probe: Option<(std::time::Instant, std::result::Result<(), String>)>,
}

/// How long a daemon probe is trusted before it is repeated.
const PROBE_TTL: std::time::Duration = std::time::Duration::from_secs(10);

impl Ai {
    /// No network at all: the hash embedder and nothing to dial.
    fn offline() -> Self {
        Self {
            setup: Setup::resolve(|_| None, |_| None, |_| None),
            embedder: std::sync::Arc::new(HashEmbedder::default()),
            fallback: None,
            cloud: None,
            cloud_why: "no model configured".into(),
            local: None,
            local_why: "the offline backend dials nothing".into(),
            probe: None,
        }
    }

    /// Build the clients from a resolved setup and pick an embedder.
    ///
    /// The embedder is the daemon's when the daemon is up — the only place
    /// real vectors ever come from, since ollama.com serves none — the
    /// cloud's when only the cloud can be dialled, and the hashing one
    /// otherwise. Each remote one sits behind [`Fallback`], because a host
    /// that answers chat may still have no embedding model.
    fn build(setup: Setup) -> Self {
        let (cloud, cloud_why) = {
            let client = Ollama::new(setup.cloud());
            match client.config().usable() {
                Ok(()) => (Some(client), String::new()),
                Err(why) => (None, why.to_string()),
            }
        };
        let (local, local_why) = match setup.local() {
            Some(cfg) if cfg.provenance() == crate::ollama::Provenance::OnDevice => {
                (Some(Ollama::new(cfg)), String::new())
            }
            Some(cfg) => (
                None,
                format!(
                    "{} on {} is not on this machine ({})",
                    cfg.model,
                    cfg.host,
                    cfg.provenance().label().to_lowercase()
                ),
            ),
            None => (
                None,
                format!(
                    "on-device AI is {}",
                    match setup.engine() {
                        Engine::Off => "off (ondevice.engine=off)".to_string(),
                        other => format!("set to {} only", other.as_str()),
                    }
                ),
            ),
        };
        let probe = local
            .as_ref()
            .map(|client| (std::time::Instant::now(), client.probe()));

        let remote = if matches!(probe, Some((_, Ok(())))) {
            local
                .as_ref()
                .map(|c| (c.clone(), c.config().embed_model.clone()))
        } else {
            cloud
                .as_ref()
                .map(|c| (c.clone(), c.config().embed_model.clone()))
        };
        let (embedder, fallback): (std::sync::Arc<dyn Embedder>, Option<_>) = match remote {
            Some((client, model)) => {
                let guarded = std::sync::Arc::new(Fallback::new(Box::new(OllamaEmbedder::new(
                    client, model,
                ))));
                (guarded.clone(), Some(guarded))
            }
            None => (std::sync::Arc::new(HashEmbedder::default()), None),
        };
        Self {
            setup,
            embedder,
            fallback,
            cloud,
            cloud_why,
            local,
            local_why,
            probe,
        }
    }

    /// Is the daemon there with the model, asking it again only when the
    /// last answer is older than [`PROBE_TTL`].
    fn daemon_ok(&mut self) -> std::result::Result<(), String> {
        let Some(client) = &self.local else {
            return Err(self.local_why.clone());
        };
        let fresh = self
            .probe
            .as_ref()
            .filter(|(at, _)| at.elapsed() < PROBE_TTL)
            .map(|(_, r)| r.clone());
        match fresh {
            Some(r) => r,
            None => {
                let r = client.probe();
                self.probe = Some((std::time::Instant::now(), r.clone()));
                r
            }
        }
    }
}

impl Backend {
    /// Open `~/.causewaybayjarvis`, seed the roster, and work out whether
    /// there is a model to talk to.
    pub fn boot() -> Result<Self> {
        let store = crate::store::boot()?;
        Ok(Self::wrap(store, Overrides::default()))
    }

    pub fn at(space: Space) -> Result<Self> {
        Self::at_with(space, Overrides::default())
    }

    /// Open a space with settings handed to this backend by whoever opened
    /// it — the in-process equivalent of the variables a caller puts on
    /// `agentd`'s command line. See [`Overrides`]: they are carried here
    /// rather than written to the process, because an embedded backend
    /// shares its process with its caller.
    pub fn at_with(space: Space, overrides: Overrides) -> Result<Self> {
        let store = Store::open(space)?;
        store.seed_roster()?;
        store.sync()?;
        Ok(Self::wrap(store, overrides))
    }

    /// A backend with no network at all: the hash embedder and the offline
    /// brain. The tests run against this, and so does a machine with no key.
    pub fn offline(store: Store) -> Self {
        Self {
            store,
            overrides: Overrides::default(),
            ai: std::sync::Mutex::new(Ai::offline()),
            // Deliberately no engine either: `offline` is the deterministic
            // backend the tests run against, and it has to behave the same on
            // a machine with the weights as on one without.
            #[cfg(feature = "mlx")]
            mlx: None,
            #[cfg(feature = "mlx")]
            mlx_why: "the offline backend carries no engine".into(),
        }
    }

    fn wrap(store: Store, overrides: Overrides) -> Self {
        // JARVIS_NO_MLX=1 keeps an mlx build off the engine — what the tests
        // set so they stay hermetic on a machine that has the weights, and a
        // way to force the cloud without rebuilding. Read through the
        // overrides, so a caller that asked for it in-process is answered
        // the same as one that put it on a command line.
        #[cfg(feature = "mlx")]
        let (mlx, mlx_why) = if overrides.var("JARVIS_NO_MLX").as_deref() == Some("1") {
            (
                None,
                "the on-device engine is disabled (JARVIS_NO_MLX=1)".to_string(),
            )
        } else {
            match crate::ondevice::MlxBrain::new(&overrides.var("JARVIS_MODEL").unwrap_or_default())
            {
                Ok(brain) => (Some(brain), String::new()),
                Err(e) => (
                    None,
                    format!("the on-device model alias did not resolve: {e}"),
                ),
            }
        };
        let ai = Ai::build(Setup::load_with(&store, &overrides));
        Self {
            store,
            overrides,
            ai: std::sync::Mutex::new(ai),
            #[cfg(feature = "mlx")]
            mlx,
            #[cfg(feature = "mlx")]
            mlx_why,
        }
    }

    fn ai(&self) -> std::sync::MutexGuard<'_, Ai> {
        self.ai.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Re-read the setup and rebuild the clients: what `config.set` does
    /// after it has written, so a running daemon follows the setup screen
    /// without a restart. The offline backend stays offline.
    fn reconfigure(&self) {
        let mut ai = self.ai();
        if ai.local_why == "the offline backend dials nothing" {
            return;
        }
        *ai = Ai::build(Setup::load_with(&self.store, &self.overrides));
    }

    /// The live embedder, cloned out so a turn never holds the lock.
    fn embedder(&self) -> std::sync::Arc<dyn Embedder> {
        self.ai().embedder.clone()
    }

    /// Can *anything* answer a turn? On-device counts: a machine with the
    /// weights and no key is online in every sense that matters.
    pub fn online(&self) -> bool {
        !matches!(self.effective(), Effective::Offline(_))
    }

    // ------------------------------------------------------------ provider --

    /// What the operator asked for, out of the settings table. `auto` until
    /// they say otherwise.
    pub fn provider(&self) -> Provider {
        self.store
            .setting(Provider::KEY)
            .ok()
            .flatten()
            .and_then(|v| Provider::parse(&v))
            .unwrap_or(Provider::Auto)
    }

    pub fn set_provider(&self, choice: Provider) -> Result<()> {
        self.store.set_setting(Provider::KEY, choice.as_str())
    }

    /// Can the MLX engine answer a turn right now?
    fn mlx_ok(&self) -> std::result::Result<(), String> {
        #[cfg(feature = "mlx")]
        {
            match &self.mlx {
                Some(brain) => brain.weights_ready(),
                None => Err(self.mlx_why.clone()),
            }
        }
        #[cfg(not(feature = "mlx"))]
        {
            Err("this build has no MLX engine — run `make gui`".into())
        }
    }

    /// Which on-device engine answers right now: MLX when the build has it
    /// and the weights are on disk, the local ollama daemon when it is up
    /// with the model — or neither, with both reasons.
    ///
    /// The engine setting narrows this: `mlx` and `ollama` ask for one of
    /// them only, `off` for none. Pure over the two checks, see
    /// [`pick_engine`].
    fn ondevice_engine(&self) -> std::result::Result<Engine, String> {
        let engine = self.ai().setup.engine();
        pick_engine(engine, || self.mlx_ok(), || self.ai().daemon_ok())
    }

    /// Can anything on this machine answer a turn right now?
    fn ondevice_ok(&self) -> std::result::Result<(), String> {
        self.ondevice_engine().map(|_| ())
    }

    fn cloud_ok(&self) -> std::result::Result<(), String> {
        let ai = self.ai();
        match &ai.cloud {
            Some(_) => Ok(()),
            None => Err(ai.cloud_why.clone()),
        }
    }

    /// What a turn will actually use, honouring the choice rather than
    /// substituting for it — see [`crate::provider::effective`].
    pub fn effective(&self) -> Effective {
        effective(self.provider(), &self.ondevice_ok(), &self.cloud_ok())
    }

    /// The whole picture: the wish, the outcome, and both brains' state.
    /// This is what the UI's toggle and the setup screen draw from.
    fn provider_info(&self) -> Value {
        let eff = self.effective();
        let engine = self.ondevice_engine();
        let cloud = self.cloud_ok();
        let mlx = self.mlx_ok();
        // Everything the lock guards is copied out here, in one statement:
        // a guard taken inside the `json!` below would live to the end of
        // that expression, and a second `self.ai()` in it would deadlock.
        let (daemon, daemon_host, daemon_model, wanted, cloud_host, cloud_model, cloud_prov) = {
            let mut ai = self.ai();
            let probe = ai.daemon_ok();
            let host = ai.local.as_ref().map(|c| c.config().host.clone());
            let model = ai.local.as_ref().map(|c| c.config().model.clone());
            let c = ai.cloud.as_ref().map(|o| o.config().clone());
            (
                probe,
                host,
                model,
                ai.setup.engine(),
                c.as_ref().map(|c| c.host.clone()),
                c.as_ref().map(|c| c.model.clone()),
                c.as_ref().map(|c| c.provenance().label()),
            )
        };
        let model = match engine {
            Ok(Engine::Mlx) => self.mlx_model(),
            Ok(_) => daemon_model.clone(),
            Err(_) => None,
        };
        json!({
            "current": self.provider().as_str(),
            "effective": eff.as_str(),
            "why": match &eff { Effective::Offline(why) => Some(why.clone()), _ => None },
            "ondevice": {
                "compiled": crate::ondevice::COMPILED,
                "ready": engine.is_ok(),
                "why": engine.as_ref().err(),
                "engine": engine.as_ref().ok().map(|e| e.as_str()),
                "wanted": wanted.as_str(),
                "model": model,
                "host": match engine { Ok(Engine::Mlx) => None, _ => daemon_host.clone() },
                "loaded": self.mlx_loaded(),
                "mlx": {
                    "compiled": crate::ondevice::COMPILED,
                    "ready": mlx.is_ok(),
                    "why": mlx.err(),
                    "model": self.mlx_model(),
                },
                "daemon": {
                    "ready": daemon.is_ok(),
                    "why": daemon.err(),
                    "host": daemon_host,
                    "model": daemon_model,
                },
            },
            "cloud": {
                "ready": cloud.is_ok(),
                "why": cloud.err(),
                "host": cloud_host,
                "model": cloud_model,
                "provenance": cloud_prov,
            },
        })
    }

    fn mlx_model(&self) -> Option<String> {
        #[cfg(feature = "mlx")]
        {
            self.mlx.as_ref().map(|b| b.alias().to_string())
        }
        #[cfg(not(feature = "mlx"))]
        {
            None
        }
    }

    fn mlx_loaded(&self) -> bool {
        #[cfg(feature = "mlx")]
        {
            self.mlx.as_ref().is_some_and(|b| b.loaded())
        }
        #[cfg(not(feature = "mlx"))]
        {
            false
        }
    }

    // -------------------------------------------------------------- setup --

    /// The setup as the screen shows it: every value, its source, and what
    /// each brain makes of it right now.
    fn config_info(&self) -> Value {
        let setup = self.ai().setup.describe();
        json!({
            "setup": setup,
            "keys": setup::KEYS.iter().map(|k| k.name).collect::<Vec<_>>(),
            "provider": self.provider_info(),
        })
    }

    /// Write one or more values into the space and rewire. A blank value
    /// clears the space's override, so the environment or the default shows
    /// through again — there is no way to persist "nothing" on purpose,
    /// which is the right shape for a setup screen with a CLEAR button.
    fn set_config(&self, req: &Value) -> Result<Value> {
        let mut pairs: Vec<(setup::Key, String)> = Vec::new();
        let mut take = |name: &str, value: &Value| -> Result<()> {
            let key = setup::key(name)
                .ok_or_else(|| anyhow!("no setting {name:?} — see `agentd config`"))?;
            let value = match value {
                Value::String(s) => s.trim().to_string(),
                Value::Null => String::new(),
                other => other.to_string(),
            };
            setup::validate(key, &value).map_err(|e| anyhow!(e))?;
            pairs.push((key, value));
            Ok(())
        };
        if let Some(values) = req.get("values").and_then(Value::as_object) {
            for (k, v) in values {
                take(k, v)?;
            }
        }
        if let Some(name) = req.get("key").and_then(Value::as_str) {
            take(name, req.get("value").unwrap_or(&Value::Null))?;
        }
        if pairs.is_empty() {
            return Err(anyhow!(
                "config.set needs a key and a value, or a values object"
            ));
        }
        for (key, value) in &pairs {
            self.store.set_setting(key.name, value)?;
        }
        self.reconfigure();
        Ok(self.config_info())
    }

    /// One raw model call — messages and a tool schema in, the reply message
    /// out — against whatever the provider setting resolves to. No routing,
    /// no archive, no memory: this is for a client that runs its own loop,
    /// such as the swarm console, so that its turns obey the same brain
    /// choice as the robots' instead of dialling a link of their own.
    fn brain_chat(&self, messages: &[Message], tools: &[Value]) -> Result<Value> {
        let (reply, label, effective) = match self.effective() {
            Effective::OnDevice => match self.ondevice_engine() {
                Ok(Engine::Mlx) => {
                    #[cfg(feature = "mlx")]
                    {
                        let brain = self.mlx.as_ref().expect("ondevice_engine() checked this");
                        (
                            Brain::chat(brain, messages, tools)?,
                            brain.label(),
                            "ondevice",
                        )
                    }
                    #[cfg(not(feature = "mlx"))]
                    unreachable!("pick_engine() cannot pick an engine that was not compiled")
                }
                Ok(_) => {
                    let client = self
                        .ai()
                        .local
                        .clone()
                        .expect("ondevice_engine() checked this");
                    (
                        Brain::chat(&client, messages, tools)?,
                        client.label(),
                        "ondevice",
                    )
                }
                Err(why) => unreachable!("effective() said on-device but no engine: {why}"),
            },
            Effective::Cloud => {
                let client = self.ai().cloud.clone().expect("effective() checked this");
                (
                    Brain::chat(&client, messages, tools)?,
                    client.label(),
                    "cloud",
                )
            }
            Effective::Offline(why) => return Err(anyhow!("no brain can answer: {why}")),
        };
        Ok(json!({
            "message": reply.message,
            "done_reason": reply.done_reason,
            "model": label,
            "effective": effective,
        }))
    }

    /// Load the on-device brain now, so the first turn does not pay for it.
    ///
    /// Synchronous on purpose: the dispatcher is one thread, and a turn
    /// queued behind this would have paid the same load itself. The reply
    /// says which engine was readied — `mlx` (the weights onto the GPU) or
    /// `ollama` (the daemon told to load its model) — or that nothing needed
    /// doing, with the reason, when the cloud answers or nothing can.
    fn prepare(&self) -> Result<Value> {
        let started = std::time::Instant::now();
        let seconds = |t: std::time::Instant| t.elapsed().as_secs_f64();
        match self.effective() {
            Effective::OnDevice => match self.ondevice_engine() {
                Ok(Engine::Mlx) => {
                    #[cfg(feature = "mlx")]
                    {
                        let brain = self.mlx.as_ref().expect("ondevice_engine() checked this");
                        let already = brain.loaded();
                        brain.warm()?;
                        Ok(json!({
                            "engine": "mlx",
                            "model": brain.alias(),
                            "loaded": true,
                            "already": already,
                            "seconds": seconds(started),
                        }))
                    }
                    #[cfg(not(feature = "mlx"))]
                    unreachable!("pick_engine() cannot pick an engine that was not compiled")
                }
                Ok(_) => {
                    let client = self
                        .ai()
                        .local
                        .clone()
                        .expect("ondevice_engine() checked this");
                    client.load()?;
                    Ok(json!({
                        "engine": "ollama",
                        "model": client.config().model,
                        "loaded": true,
                        "already": false,
                        "seconds": seconds(started),
                    }))
                }
                Err(why) => unreachable!("effective() said on-device but no engine: {why}"),
            },
            Effective::Cloud => Ok(json!({
                "engine": Value::Null,
                "loaded": false,
                "why": "the cloud answers — nothing to load here",
                "seconds": seconds(started),
            })),
            Effective::Offline(why) => Ok(json!({
                "engine": Value::Null,
                "loaded": false,
                "why": why,
                "seconds": seconds(started),
            })),
        }
    }

    /// One turn, streamed: the same turn [`Self::run_turn`] runs, with the
    /// answer handed over as it is written. Public because the C ABI and the
    /// HTTP server both drive it — the daemon is one way in, not the only one.
    pub fn turn_stream(
        &self,
        who: Option<&str>,
        text: &str,
        sink: &mut crate::harness::Sink<'_>,
    ) -> Result<crate::harness::Turn> {
        let embedder = self.embedder();
        self.with_brain(Offline::Archive, &mut |brain| {
            Harness::new(&self.store, &*embedder, brain).turn_stream(who, text, sink)
        })
        .map(|(turn, _, _)| turn)
    }

    /// One raw model call, streamed. See [`Self::brain_chat`].
    pub fn brain_chat_stream(
        &self,
        messages: &[Message],
        tools: &[Value],
        sink: &mut crate::harness::Sink<'_>,
    ) -> Result<Value> {
        if messages.is_empty() {
            return Err(anyhow!("brain.chat needs messages"));
        }
        let (reply, label, effective) = self.with_brain(Offline::Refuse, &mut |brain| {
            brain.chat_stream(messages, tools, sink)
        })?;
        Ok(json!({
            "message": reply.message,
            "done_reason": reply.done_reason,
            "model": label,
            "effective": effective,
        }))
    }

    /// Hand whichever brain answers right now to `f`, with its label and
    /// which half of the world it is.
    ///
    /// The choice is four arms wide — MLX, the local daemon, the cloud, and
    /// the case where none of them can — and every caller that runs a model
    /// needs the same four. They live here once so that a new entry point
    /// cannot quietly disagree with the old ones about what "on-device"
    /// means, or about what happens when nothing can answer.
    fn with_brain<T>(
        &self,
        offline: Offline,
        f: &mut dyn FnMut(&dyn Brain) -> Result<T>,
    ) -> Result<(T, String, &'static str)> {
        match self.effective() {
            Effective::OnDevice => match self.ondevice_engine() {
                Ok(Engine::Mlx) => {
                    #[cfg(feature = "mlx")]
                    {
                        let brain = self.mlx.as_ref().expect("ondevice_engine() checked this");
                        let out = f(brain)?;
                        Ok((out, Brain::label(brain), "ondevice"))
                    }
                    #[cfg(not(feature = "mlx"))]
                    unreachable!("pick_engine() cannot pick an engine that was not compiled")
                }
                Ok(_) => {
                    // Cloned out, so the lock is not held for the length of
                    // a generation.
                    let client = self
                        .ai()
                        .local
                        .clone()
                        .expect("ondevice_engine() checked this");
                    let out = f(&client)?;
                    Ok((out, Brain::label(&client), "ondevice"))
                }
                Err(why) => unreachable!("effective() said on-device but no engine: {why}"),
            },
            Effective::Cloud => {
                let client = self.ai().cloud.clone().expect("effective() checked this");
                let out = f(&client)?;
                Ok((out, Brain::label(&client), "cloud"))
            }
            Effective::Offline(why) => match offline {
                Offline::Refuse => Err(anyhow!("no brain can answer: {why}")),
                Offline::Archive => {
                    // A turn with no model still has the archive, and
                    // answering out of it is the whole point of keeping one.
                    // A raw model call has no such consolation, which is why
                    // this is the caller's choice rather than a rule here.
                    let embedder = self.embedder();
                    let brain = LocalBrain {
                        store: &self.store,
                        embedder: &*embedder,
                        why,
                    };
                    let out = f(&brain)?;
                    Ok((out, Brain::label(&brain), "offline"))
                }
            },
        }
    }

    /// One turn, against whatever the provider setting resolves to.
    fn run_turn(&self, who: Option<&str>, text: &str) -> Result<crate::harness::Turn> {
        let embedder = self.embedder();
        match self.effective() {
            Effective::OnDevice => match self.ondevice_engine() {
                Ok(Engine::Mlx) => {
                    #[cfg(feature = "mlx")]
                    {
                        let brain = self.mlx.as_ref().expect("ondevice_engine() checked this");
                        Harness::new(&self.store, &*embedder, brain as &dyn Brain).turn(who, text)
                    }
                    #[cfg(not(feature = "mlx"))]
                    unreachable!("pick_engine() cannot pick an engine that was not compiled")
                }
                Ok(_) => {
                    // Cloned out, so the lock is not held for the length of
                    // a generation.
                    let client = self
                        .ai()
                        .local
                        .clone()
                        .expect("ondevice_engine() checked this");
                    Harness::new(&self.store, &*embedder, &client as &dyn Brain).turn(who, text)
                }
                Err(why) => unreachable!("effective() said on-device but no engine: {why}"),
            },
            Effective::Cloud => {
                let client = self.ai().cloud.clone().expect("effective() checked this");
                Harness::new(&self.store, &*embedder, &client as &dyn Brain).turn(who, text)
            }
            Effective::Offline(why) => {
                let brain = LocalBrain {
                    store: &self.store,
                    embedder: &*embedder,
                    why,
                };
                Harness::new(&self.store, &*embedder, &brain).turn(who, text)
            }
        }
    }

    /// Which robot should answer, with each robot's own archive voting.
    pub fn route(&self, prompt: &str) -> Result<router::Route> {
        let agents = self.store.agents()?;
        let evidence = search::archive_evidence(&self.store, prompt);
        Ok(router::route_with_archive(prompt, &agents, &evidence))
    }

    /// Handle one request. Never panics; every failure comes back as `ok:false`.
    pub fn handle(&self, req: &Value) -> Value {
        let op = req
            .get("op")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        match self.dispatch(&op, req) {
            Ok(data) => json!({ "ok": true, "op": op, "data": data }),
            Err(e) => json!({ "ok": false, "op": op, "error": e.to_string() }),
        }
    }

    fn dispatch(&self, op: &str, req: &Value) -> Result<Value> {
        let who = req.get("agent").and_then(Value::as_str);
        match op {
            "health" => {
                // Both computed before the lock is taken: `online` walks
                // `effective`, which locks.
                let provider = self.provider_info();
                let online = self.online();
                let ai = self.ai();
                Ok(json!({
                    "ok": true,
                    "online": online,
                    "provider": provider,
                    "offline_why": ai.cloud_why,
                    "model": ai.cloud.as_ref().map(|o| o.config().model.clone()),
                    "embed_model": ai.embedder.model(),
                    "embed_fallback": ai.fallback.as_ref().filter(|f| f.degraded()).map(|f| f.why()),
                    "provenance": ai.cloud.as_ref().map(|o| o.config().provenance().label()),
                    "report": ai.cloud.as_ref().map(|o| {
                        o.report().into_iter().map(|(t, tone)| json!({"text": t, "tone": tone}))
                            .collect::<Vec<_>>()
                    }),
                    "root": self.store.space.tilde(self.store.space.root()),
                }))
            }

            "stats" => self.store.stats(),

            "agents.list" => Ok(json!(self.store.agents()?)),

            "agents.get" => {
                let agent = self.store.resolve_agent(who)?;
                Ok(json!(agent))
            }

            "agents.create" => {
                let field = |k: &str, d: &str| -> String {
                    req.get(k)
                        .and_then(Value::as_str)
                        .map(str::to_string)
                        .filter(|s| !s.trim().is_empty())
                        .unwrap_or_else(|| d.to_string())
                };
                let slug = field("slug", "");
                if slug.trim().is_empty() {
                    return Err(anyhow!("agents.create needs a slug"));
                }
                if self.store.agent_by_slug(&slug)?.is_some() {
                    return Err(anyhow!("a robot called {slug:?} already exists"));
                }
                // `Seed` is `&'static str` all the way down because the shipped
                // roster is a constant; a runtime one has to be leaked to match.
                let seed = Seed {
                    slug: Box::leak(slug.into_boxed_str()),
                    name: Box::leak(field("name", "NEW").to_uppercase().into_boxed_str()),
                    kind: Box::leak(field("kind", "general").into_boxed_str()),
                    role: Box::leak(field("role", "SPECIALIST").to_uppercase().into_boxed_str()),
                    sprite: Box::leak(field("sprite", "nova").into_boxed_str()),
                    color: Box::leak(field("color", "cyan").into_boxed_str()),
                    persona: Box::leak(
                        field("persona", "You are a robot of the swarm.").into_boxed_str(),
                    ),
                    keywords: Box::leak(field("keywords", "").into_boxed_str()),
                };
                Ok(json!(self.store.create_agent(&seed)?))
            }

            "agents.delete" => {
                let agent = self
                    .store
                    .resolve_agent(who)?
                    .ok_or_else(|| anyhow!("agents.delete needs a robot"))?;
                Ok(json!({ "deleted": self.store.delete_agent(&agent.id)? }))
            }

            "page" => {
                let agent = self.store.resolve_agent(who)?;
                let page = self.store.page(agent.as_ref().map(|a| a.id.as_str()))?;
                let mut value = serde_json::to_value(&page)?;
                // The client draws pictures, so it needs real paths for them.
                for shelf in ["gallery", "papers"] {
                    if let Some(list) = value[shelf].as_array_mut() {
                        for item in list {
                            if let Some(rel) = item["path"].as_str() {
                                let abs = self.store.space.resolve(rel)?;
                                item["abs"] = json!(abs.to_string_lossy());
                            }
                        }
                    }
                }
                Ok(value)
            }

            "items" => {
                let agent = self.store.resolve_agent(who)?;
                let kind = req
                    .get("kind")
                    .and_then(Value::as_str)
                    .and_then(Kind::parse);
                let limit = req.get("limit").and_then(Value::as_i64).unwrap_or(50);
                Ok(json!(self.store.items(
                    agent.as_ref().map(|a| a.id.as_str()),
                    kind,
                    limit
                )?))
            }

            "item.add" => {
                let agent = self.store.resolve_agent(who)?;
                let item = self.store.add(NewItem {
                    agent_id: agent.as_ref().map(|a| a.id.clone()),
                    kind: req
                        .get("kind")
                        .and_then(Value::as_str)
                        .and_then(Kind::parse),
                    title: string_of(req, "title"),
                    body: string_of(req, "body"),
                    source_path: req
                        .get("path")
                        .and_then(Value::as_str)
                        .filter(|s| !s.trim().is_empty())
                        .map(str::to_string),
                    role: String::new(),
                    meta: req.get("meta").map(|m| m.to_string()),
                })?;
                // One vector for the row we just wrote, so it is findable now
                // rather than after the next reindex.
                if let Ok(vec) = self.embedder().embed_one(&item.indexed_text()) {
                    let _ = self
                        .store
                        .put_embedding(item.id, self.embedder().model(), &vec);
                }
                let mut value = serde_json::to_value(&item)?;
                if let Some(rel) = item.path.as_deref() {
                    value["abs"] = json!(self.store.space.resolve(rel)?.to_string_lossy());
                }
                Ok(value)
            }

            // The row is `item`, with `id` accepted for the CLI and HTTP.
            // Over the WebSocket `id` is the frame's own correlation
            // number, stamped by the client, so a request that named its
            // row `id` would be answered under the row's number and nobody
            // would be waiting there.
            "item.read" => {
                let id = item_of(req).ok_or_else(|| anyhow!("item.read needs an item"))?;
                let item = self
                    .store
                    .item(id)?
                    .ok_or_else(|| anyhow!("no item #{id}"))?;
                let mut value = serde_json::to_value(&item)?;
                if let Some(rel) = item.path.as_deref() {
                    value["abs"] = json!(self.store.space.resolve(rel)?.to_string_lossy());
                    if item.body.trim().is_empty() {
                        if let Ok(text) = self.store.space.read_text(rel) {
                            value["body"] = json!(text);
                        }
                    }
                }
                Ok(value)
            }

            "item.delete" => {
                let id = item_of(req).ok_or_else(|| anyhow!("item.delete needs an item"))?;
                Ok(json!({ "deleted": self.store.delete_item(id)? }))
            }

            // A chosen robot searches its own database; nobody chosen
            // searches every robot at once (`all` says so explicitly, and
            // `global` alone asks for what was filed with nobody chosen).
            "search" => {
                let query = string_of(req, "query");
                let mode = Mode::parse(&string_of(req, "mode"));
                let limit = req.get("limit").and_then(Value::as_i64).unwrap_or(10) as usize;
                let agent = self.store.resolve_agent(who)?;
                let scope = if req.get("all").and_then(Value::as_bool).unwrap_or(false) {
                    Scope::All
                } else if agent.is_none() && who.map(str::trim) == Some("global") {
                    Scope::Global
                } else {
                    Scope::of(agent.as_ref().map(|a| a.id.as_str()))
                };
                let embedder = self.embedder();
                let hits = search::search(&self.store, &*embedder, &query, &scope, mode, limit)?;
                // Which robot each hit came from, by name, so a search across
                // the swarm can say who knew.
                let names: std::collections::HashMap<String, String> = self
                    .store
                    .agents()?
                    .into_iter()
                    .map(|a| (a.id, a.name))
                    .collect();
                let mut hits = serde_json::to_value(&hits)?;
                if let Some(list) = hits.as_array_mut() {
                    for hit in list {
                        let owner = hit["item"]["agent_id"].as_str().map(str::to_string);
                        hit["agent_name"] = match owner.and_then(|id| names.get(&id)) {
                            Some(name) => json!(name),
                            None => json!("GLOBAL"),
                        };
                        if let Some(rel) = hit["item"]["path"].as_str() {
                            if let Ok(abs) = self.store.space.resolve(rel) {
                                hit["abs"] = json!(abs.to_string_lossy());
                            }
                        }
                    }
                }
                Ok(json!({
                    "mode": mode,
                    "scope": match &scope {
                        Scope::Agent(id) => json!({ "agent": id }),
                        Scope::Global => json!("global"),
                        Scope::All => json!("all"),
                    },
                    "hits": hits,
                }))
            }

            // Every photo, grouped by the robot whose folder holds it. One
            // robot when asked for one; all of them, and the global space,
            // otherwise.
            "gallery" => {
                let chosen = self.store.resolve_agent(who)?;
                let mut groups = Vec::new();
                let mut push = |agent: Option<crate::agent::Agent>| -> Result<()> {
                    let id = agent.as_ref().map(|a| a.id.clone());
                    let photos = self.store.items(id.as_deref(), Some(Kind::Image), 500)?;
                    let mut list = serde_json::to_value(&photos)?;
                    if let Some(items) = list.as_array_mut() {
                        for item in items {
                            if let Some(rel) = item["path"].as_str() {
                                item["abs"] =
                                    json!(self.store.space.resolve(rel)?.to_string_lossy());
                            }
                        }
                    }
                    let space_dir = agent
                        .as_ref()
                        .map(|a| a.space.clone())
                        .unwrap_or_else(|| Space::agent_space(None));
                    groups.push(json!({
                        "agent": agent,
                        "space": space_dir,
                        "folder": self.store.space.tilde(&self.store.space.resolve(&format!("{space_dir}/photos"))?),
                        "count": photos.len(),
                        "photos": list,
                    }));
                    Ok(())
                };
                match chosen {
                    Some(agent) => push(Some(agent))?,
                    None => {
                        for agent in self.store.agents()? {
                            push(Some(agent))?;
                        }
                        push(None)?;
                    }
                }
                let total: usize = groups
                    .iter()
                    .map(|g| g["count"].as_u64().unwrap_or(0) as usize)
                    .sum();
                Ok(json!({ "total": total, "groups": groups }))
            }

            // One robot's archive as one square picture, into its `paper/`
            // folder. `sprite` is the path of the face to paste in — the
            // client has the sprite sheets, the backend does not — and
            // `out` overrides where the file goes.
            "paper" => {
                let agent = self.store.resolve_agent(who)?;
                let sprite = req
                    .get("sprite")
                    .and_then(Value::as_str)
                    .filter(|s| !s.trim().is_empty())
                    .map(std::path::PathBuf::from);
                let out = req
                    .get("out")
                    .and_then(Value::as_str)
                    .filter(|s| !s.trim().is_empty())
                    .map(std::path::PathBuf::from);
                let saved = crate::paper::save(
                    &self.store,
                    agent.as_ref().map(|a| a.id.as_str()),
                    sprite.as_deref(),
                    out.as_deref(),
                )?;
                Ok(json!(saved))
            }

            // Rebuild a robot's own database and its three mirrors from the
            // global one — or every robot's, and the global folder's, when
            // no robot is named.
            "export" => {
                let agent = self.store.resolve_agent(who)?;
                let reports = match agent {
                    Some(a) => vec![self.store.export(Some(&a.id))?],
                    None if who.map(str::trim) == Some("global") => {
                        vec![self.store.export(None)?]
                    }
                    None => {
                        let mut all = Vec::new();
                        for a in self.store.agents()? {
                            all.push(self.store.export(Some(&a.id))?);
                        }
                        all.push(self.store.export(None)?);
                        all
                    }
                };
                Ok(json!({ "exported": reports }))
            }

            "route" => {
                let text = string_of(req, "text");
                Ok(json!(self.route(&text)?))
            }

            "messages" => {
                let agent = self.store.resolve_agent(who)?;
                let limit = req.get("limit").and_then(Value::as_i64).unwrap_or(50);
                Ok(json!(self
                    .store
                    .messages(agent.as_ref().map(|a| a.id.as_str()), limit)?))
            }

            "messages.clear" => {
                let agent = self.store.resolve_agent(who)?;
                Ok(json!({
                    "cleared": self.store.clear_messages(agent.as_ref().map(|a| a.id.as_str()))?
                }))
            }

            "reindex" => {
                let agent = self.store.resolve_agent(who)?;
                let embedder = self.embedder();
                Ok(json!({
                    "embedded": search::reindex(
                        &self.store,
                        &*embedder,
                        agent.as_ref().map(|a| a.id.as_str())
                    )?
                }))
            }

            "chat" => {
                let text = string_of(req, "text");
                Ok(json!(self.run_turn(who, &text)?))
            }

            "prepare" => self.prepare(),

            "provider" => Ok(self.provider_info()),

            "provider.set" => {
                let asked = string_of(req, "provider");
                let choice = Provider::parse(&asked).ok_or_else(|| {
                    anyhow!("no provider {asked:?} — use auto, ondevice or cloud")
                })?;
                self.set_provider(choice)?;
                Ok(self.provider_info())
            }

            "config" => Ok(self.config_info()),

            "brain.chat" => {
                let messages: Vec<Message> = serde_json::from_value(
                    req.get("messages").cloned().unwrap_or_else(|| json!([])),
                )
                .map_err(|e| anyhow!("bad messages: {e}"))?;
                if messages.is_empty() {
                    return Err(anyhow!("brain.chat needs messages"));
                }
                let tools: Vec<Value> = req
                    .get("tools")
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default();
                self.brain_chat(&messages, &tools)
            }

            "config.set" => self.set_config(req),

            // Answered here so `serve` and `listen` can both see it go past
            // and shut down after the reply is on the wire.
            "daemon.stop" => Ok(json!({ "stopping": true })),

            "" => Err(anyhow!("no op")),
            other => Err(anyhow!("unknown op {other:?}")),
        }
    }
}

/// The row an item op is about: `item`, else `id`.
fn item_of(req: &Value) -> Option<i64> {
    req.get("item")
        .and_then(Value::as_i64)
        .or_else(|| req.get("id").and_then(Value::as_i64))
}

fn string_of(req: &Value, key: &str) -> String {
    req.get(key)
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string()
}

/// Every op the backend answers, for `agentd ops` and the client's own help.
pub const OPS: &[&str] = &[
    "health",
    "stats",
    "agents.list",
    "agents.get",
    "agents.create",
    "agents.delete",
    "page",
    "items",
    "item.add",
    "item.read",
    "item.delete",
    "search",
    "gallery",
    "paper",
    "export",
    "route",
    "messages",
    "messages.clear",
    "reindex",
    "chat",
    "prepare",
    "provider",
    "provider.set",
    "config",
    "config.set",
    "brain.chat",
];

/// Which on-device engine answers, given the setting and the two checks.
///
/// `auto` tries MLX first — it is the engine this workspace was built for —
/// and the daemon second, and refuses with *both* reasons when neither can.
/// The checks are closures so the daemon is not dialled when the setting
/// rules it out.
pub fn pick_engine(
    wanted: Engine,
    mlx: impl FnOnce() -> std::result::Result<(), String>,
    daemon: impl FnOnce() -> std::result::Result<(), String>,
) -> std::result::Result<Engine, String> {
    match wanted {
        Engine::Off => Err("on-device AI is off (ondevice.engine=off)".into()),
        Engine::Mlx => mlx().map(|_| Engine::Mlx),
        Engine::Ollama => daemon().map(|_| Engine::Ollama),
        Engine::Auto => match mlx() {
            Ok(()) => Ok(Engine::Mlx),
            Err(m) => match daemon() {
                Ok(()) => Ok(Engine::Ollama),
                Err(d) => Err(format!("{m}; {d}")),
            },
        },
    }
}
