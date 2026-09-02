//! One turn, end to end.
//!
//! ```text
//!   route ──► retrieve ──► call ──┬──► tool ──► call ──┐
//!                                 │      ▲             │
//!                                 │      └─────────────┘
//!                                 └──► answer ──► remember
//! ```
//!
//! **Route** picks the robot when none was chosen ([`crate::router`]).
//! **Retrieve** searches that robot's archive with BM25 and vectors together
//! and folds the hits into the prompt ([`crate::search`]). **Call** is the
//! model. **Tool** is the loop that lets it act before it speaks, capped at
//! [`MAX_STEPS`] so a model that keeps calling cannot spin. **Remember**
//! writes both sides of the turn back into the archive and indexes them, which
//! is what makes the next turn know about this one.
//!
//! The model sits behind [`Brain`] rather than being called directly, so a
//! scripted one can drive the whole pipeline in a test, and so the machine
//! with no key still answers — see [`LocalBrain`].

use anyhow::Result;
use serde::Serialize;
use serde_json::Value;

use crate::agent::Agent;
use crate::embed::Embedder;
use crate::ollama::{Message, Ollama, Reply};
use crate::router;
use crate::search::{self, Mode, Scope};
use crate::store::Store;
use crate::tools;

/// How many times round the tool loop before the turn is cut off.
pub const MAX_STEPS: usize = 4;
/// How many archive hits are folded into the prompt.
pub const RETRIEVE: usize = 5;
/// How much of the transcript goes back to the model.
pub const HISTORY: i64 = 12;

/// Whatever is answering. `Ollama` in production; a script in the tests.
/// What a streaming brain hands back as it goes: the visible answer a piece
/// at a time, and — for a model that thinks out loud — the reasoning
/// separately, so a client can show one and not the other. Returning
/// `false` from the sink asks the brain to stop generating.
pub type Sink<'a> = dyn FnMut(Chunk<'_>) -> bool + 'a;

/// One piece of a streaming answer.
#[derive(Debug, Clone, Copy)]
pub enum Chunk<'a> {
    /// A piece of the visible answer.
    Token(&'a str),
    /// A piece of the model's thinking, when it emits one.
    Reasoning(&'a str),
    /// Prompt ingestion, before any token: `done` of `total`.
    Prefill { done: usize, total: usize },
    /// A tool the harness ran between steps, already labelled for reading.
    /// Not model output: it is what the turn *did* while the reader waited.
    Tool(&'a str),
}

pub trait Brain {
    fn chat(&self, messages: &[Message], tools: &[Value]) -> Result<Reply>;
    /// One word for the console: the model name, or `OFFLINE`.
    fn label(&self) -> String;
    /// Does this brain understand `tool_calls`?
    fn uses_tools(&self) -> bool {
        true
    }

    /// The same turn, delivered as it is generated.
    ///
    /// The default is honest rather than fake: a brain with nothing to
    /// stream answers in full and hands the whole thing over as one chunk,
    /// so a caller written against this never has to ask which kind of
    /// brain it got. [`streams`] says whether it was worth asking.
    fn chat_stream(
        &self,
        messages: &[Message],
        tools: &[Value],
        sink: &mut Sink<'_>,
    ) -> Result<Reply> {
        let reply = self.chat(messages, tools)?;
        let text = reply.message.content.clone();
        if !text.is_empty() {
            sink(Chunk::Token(&text));
        }
        Ok(reply)
    }

    /// Does `chat_stream` actually arrive in pieces?
    fn streams(&self) -> bool {
        false
    }
}

impl Brain for Ollama {
    fn chat(&self, messages: &[Message], tools: &[Value]) -> Result<Reply> {
        Ollama::chat(self, messages, tools)
    }
    fn label(&self) -> String {
        self.config().model.clone()
    }
    fn chat_stream(
        &self,
        messages: &[Message],
        tools: &[Value],
        sink: &mut Sink<'_>,
    ) -> Result<Reply> {
        Ollama::chat_stream(self, messages, tools, sink)
    }
    fn streams(&self) -> bool {
        true
    }
}

/// What one turn did.
#[derive(Debug, Clone, Serialize)]
pub struct Turn {
    /// The robot that answered. `None` is the global space.
    pub agent: Option<AgentBrief>,
    /// Was the robot chosen by the router rather than by the operator?
    pub routed: bool,
    /// Did the router actually match, or is this the general robot by default?
    pub confident: bool,
    pub reply: String,
    /// The tools that ran, in order, as console labels.
    pub tools: Vec<String>,
    /// What retrieval put in front of the model.
    pub retrieved: Vec<Retrieved>,
    pub model: String,
    /// The row ids of the two messages this turn wrote.
    pub user_item: i64,
    pub reply_item: i64,
}

#[derive(Debug, Clone, Serialize)]
pub struct AgentBrief {
    pub id: String,
    pub slug: String,
    pub name: String,
    pub kind: String,
    pub sprite: String,
    pub color: String,
}

impl From<&Agent> for AgentBrief {
    fn from(a: &Agent) -> Self {
        Self {
            id: a.id.clone(),
            slug: a.slug.clone(),
            name: a.name.clone(),
            kind: a.kind.clone(),
            sprite: a.sprite.clone(),
            color: a.color.clone(),
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct Retrieved {
    pub id: i64,
    pub kind: String,
    pub title: String,
    pub score: f32,
    pub via: String,
}

pub struct Harness<'a> {
    pub store: &'a Store,
    pub embedder: &'a dyn Embedder,
    pub brain: &'a dyn Brain,
}

impl<'a> Harness<'a> {
    pub fn new(store: &'a Store, embedder: &'a dyn Embedder, brain: &'a dyn Brain) -> Self {
        Self {
            store,
            embedder,
            brain,
        }
    }

    /// Run a turn. `who` is the robot the operator locked on, or `None` to let
    /// the router decide.
    pub fn turn(&self, who: Option<&str>, prompt: &str) -> Result<Turn> {
        self.turn_with(who, prompt, None)
    }

    /// The same turn, delivered as it is written.
    ///
    /// The answer arrives through `sink` a piece at a time, and the tools
    /// the turn runs on the way are announced through it too, so a client
    /// can show "searching the archive" instead of a still cursor. The
    /// [`Turn`] that comes back at the end is the same one `turn` returns —
    /// streaming is how it is delivered, not a different result.
    pub fn turn_stream(
        &self,
        who: Option<&str>,
        prompt: &str,
        sink: &mut Sink<'_>,
    ) -> Result<Turn> {
        self.turn_with(who, prompt, Some(sink))
    }

    fn turn_with(
        &self,
        who: Option<&str>,
        prompt: &str,
        mut sink: Option<&mut Sink<'_>>,
    ) -> Result<Turn> {
        let prompt = prompt.trim();
        if prompt.is_empty() {
            anyhow::bail!("nothing to say");
        }

        // ---- route -------------------------------------------------------
        let chosen = self.store.resolve_agent(who)?;
        let roster = self.store.agents()?;
        let (agent, routed, confident) = match chosen {
            Some(a) => (Some(a), false, true),
            None => {
                let r = router::route_with_archive(
                    prompt,
                    &roster,
                    &search::archive_evidence(self.store, prompt),
                );
                match r
                    .agent
                    .and_then(|c| roster.iter().find(|a| a.id == c.id).cloned())
                {
                    Some(a) => (Some(a), true, r.confident),
                    None => (None, true, false),
                }
            }
        };
        let agent_id = agent.as_ref().map(|a| a.id.clone());

        // ---- remember what was asked, before anything can fail ------------
        let user_item = self
            .store
            .add_message(agent_id.as_deref(), "user", prompt)?
            .id;

        // ---- retrieve ----------------------------------------------------
        let scope = Scope::of(agent_id.as_deref());
        let hits = search::search(
            self.store,
            self.embedder,
            prompt,
            &scope,
            Mode::Hybrid,
            RETRIEVE,
        )
        .unwrap_or_default();
        // The turn we just wrote is not context for itself.
        let hits: Vec<_> = hits
            .into_iter()
            .filter(|h| h.item.id != user_item)
            .collect();
        let retrieved: Vec<Retrieved> = hits
            .iter()
            .map(|h| Retrieved {
                id: h.item.id,
                kind: h.item.kind.clone(),
                title: h.item.title.clone(),
                score: h.score,
                via: h.via.to_string(),
            })
            .collect();

        // ---- build the conversation --------------------------------------
        // One system message, persona and retrieved context together. The
        // Qwen chat template — the on-device path — refuses a system message
        // anywhere but first, and one is the cleaner shape for the cloud too.
        let mut system = match &agent {
            Some(a) => a.system_prompt(),
            None => GLOBAL_PROMPT.to_string(),
        };
        let block = search::as_context_block(&hits);
        if !block.is_empty() {
            system.push_str("\n\n");
            system.push_str(&block);
        }
        let mut messages: Vec<Message> = vec![Message::system(system)];
        for past in self.store.messages(agent_id.as_deref(), HISTORY)? {
            if past.id == user_item {
                continue;
            }
            let role = if past.role.is_empty() {
                "user".to_string()
            } else {
                past.role.clone()
            };
            messages.push(Message::new(&role, past.body));
        }
        messages.push(Message::user(prompt));

        // ---- call, with the tool loop ------------------------------------
        let schema = if self.brain.uses_tools() {
            tools::schema()
        } else {
            Vec::new()
        };
        let ctx = tools::Ctx {
            store: self.store,
            embedder: self.embedder,
            agent_id: agent_id.clone(),
        };
        let mut ran: Vec<String> = Vec::new();
        let mut answer = String::new();

        for step in 0..=MAX_STEPS {
            let reply = match sink.as_deref_mut() {
                Some(sink) => self.brain.chat_stream(&messages, &schema, sink)?,
                None => self.brain.chat(&messages, &schema)?,
            };
            let calls = reply.tool_calls().to_vec();
            if calls.is_empty() || step == MAX_STEPS {
                answer = reply.text().to_string();
                if answer.is_empty() && !calls.is_empty() {
                    answer = format!(
                        "I ran {} but ran out of steps before answering.",
                        ran.join(", ")
                    );
                }
                break;
            }
            messages.push(reply.message.clone());
            for call in calls {
                let args = call.function.args();
                let line = tools::run(&ctx, &call.function.name, &args);
                let label = tools::label(&call.function.name, &args);
                if let Some(sink) = sink.as_deref_mut() {
                    sink(Chunk::Tool(&label));
                }
                ran.push(label);
                messages.push(Message::tool(&call.function.name, line));
            }
        }

        if answer.trim().is_empty() {
            answer = "The link came back empty, sir.".into();
        }

        // ---- remember ----------------------------------------------------
        let reply_item = self
            .store
            .add_message(agent_id.as_deref(), "assistant", &answer)?
            .id;
        // Index what the turn added, so the next one can retrieve it.
        let _ = search::reindex(self.store, self.embedder, agent_id.as_deref());

        Ok(Turn {
            agent: agent.as_ref().map(AgentBrief::from),
            routed,
            confident,
            reply: answer,
            tools: ran,
            retrieved,
            model: self.brain.label(),
            user_item,
            reply_item,
        })
    }
}

const GLOBAL_PROMPT: &str = "You are the Causeway Bay swarm speaking as a whole, with no \
    single robot locked on. Answer briefly and say which robot should take this if one \
    obviously should.";

/// The brain for a machine with no key and no daemon.
///
/// It does not pretend to be a model. It runs the same retrieval the real turn
/// would, answers with what the archive actually holds, and says the link is
/// down — which is more use than an error, and keeps every other part of the
/// pipeline exercised.
pub struct LocalBrain<'a> {
    pub store: &'a Store,
    pub embedder: &'a dyn Embedder,
    pub why: String,
}

impl Brain for LocalBrain<'_> {
    fn chat(&self, messages: &[Message], _tools: &[Value]) -> Result<Reply> {
        let prompt = messages
            .iter()
            .rev()
            .find(|m| m.role == "user")
            .map(|m| m.content.clone())
            .unwrap_or_default();
        let hits = search::search(
            self.store,
            self.embedder,
            &prompt,
            &Scope::All,
            Mode::Hybrid,
            3,
        )
        .unwrap_or_default();

        let mut out = format!("OFFLINE — {}.", self.why);
        if hits.is_empty() {
            out.push_str(" Nothing in the archive matches that yet.");
        } else {
            out.push_str(" From the archive:");
            for hit in hits {
                out.push_str(&format!("\n• #{} {}", hit.item.id, hit.item.summary(180)));
            }
        }
        Ok(Reply {
            message: Message::assistant(out),
            done_reason: "offline".into(),
        })
    }

    fn label(&self) -> String {
        "OFFLINE".into()
    }

    fn uses_tools(&self) -> bool {
        false
    }
}
