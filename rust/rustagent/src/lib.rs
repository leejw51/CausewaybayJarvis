//! **The AI-agent robot system.**
//!
//! A hundred robot sprites, a dozen of them with a job. Each is a GUID, a
//! persona, and a corner of `~/.causewaybayjarvis` holding its photos, its
//! files, its markdown and every word it has been told — because in this
//! design *an agent is its context*, and nothing else.
//!
//! ```text
//!   robots/  (LOVE)  ──jsonl──►  agentd  ──►  Backend
//!                                              ├─ Store      sqlite + the folder
//!                                              ├─ router     which robot answers
//!                                              ├─ search     BM25 + vectors, fused
//!                                              ├─ tools      what the model may call
//!                                              ├─ harness    one turn, end to end
//!                                              └─ ollama     ollama.com or a daemon
//! ```
//!
//! Everything here runs with no key and no network: the roster seeds, the
//! archive fills, BM25 works because SQLite has FTS5, semantic search falls
//! back to a hashing embedder, and the turn answers out of the archive rather
//! than failing. Add `OLLAMA_API_KEY` and the same pipeline runs against a
//! real model with real embeddings — nothing else changes.

pub mod agent;
pub mod context;
pub mod db;
pub mod embed;
pub mod harness;
pub mod http;
pub mod mirror;
pub mod ollama;
pub mod ondevice;
pub mod paper;
pub mod proto;
pub mod provider;
pub mod router;
pub mod search;
pub mod server;
pub mod setup;
pub mod space;
pub mod store;
pub mod tools;

pub use agent::{Agent, Seed, ROSTER};
pub use context::{Item, Kind, NewItem};
pub use embed::{cosine, Embedder, HashEmbedder, OllamaEmbedder};
pub use harness::{Brain, Harness, LocalBrain, Turn};
pub use ollama::{Message, Ollama, Provenance};
pub use proto::{Backend, OPS};
pub use provider::{Effective, Provider};
pub use router::{route, Route};
pub use search::{Hit, Mode, Scope};
pub use setup::{Engine, Setup};
pub use space::Space;
pub use store::{Export, Page, Store};

pub type Result<T> = anyhow::Result<T>;
