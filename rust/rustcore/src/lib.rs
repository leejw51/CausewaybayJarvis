//! Model-agnostic core for **Causewaybay Jarvis**, an on-device AI agent.
//!
//! This crate knows nothing about MLX. It owns the parts that would be identical
//! for any backend: reading `config.jsonl`, resolving a model alias to a Hugging
//! Face repository, downloading it, tokenizing, rendering the chat template, and
//! the streaming contract ([`Engine`]) an inference backend has to satisfy.
//!
//! The MLX backend lives in `rustmlx`; the front ends in `rustcli` and
//! `rusttui`.

pub mod chat;
pub mod config;
pub mod engine;
pub mod hub;
pub mod models;
pub mod tokenizer;

pub use chat::{ChatTemplate, Message, RenderOptions, Role};
pub use config::Config;
pub use engine::{Completion, Engine, EngineInfo, Event, Flow, GenerationConfig, Stats};
pub use hub::{DownloadProgress, ModelFiles};
pub use models::{ModelSpec, Quantization};
pub use tokenizer::{StreamDecoder, Tokenizer};

/// Anything in this crate that can fail returns this.
pub type Result<T> = anyhow::Result<T>;
