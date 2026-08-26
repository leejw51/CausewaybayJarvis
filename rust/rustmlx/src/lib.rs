//! Apple MLX backend for **Causewaybay Jarvis**.
//!
//! A Rust port of the Qwen3.5 / Qwen3.8 hybrid architecture onto `mlx-rs`.
//! Sixty-four decoder layers, of which sixteen are ordinary gated grouped-query
//! attention and forty-eight are [gated DeltaNet](delta) linear attention — so
//! only a quarter of the layers keep a cache that grows with the conversation.
//! Weights are read straight out of an MLX 4-bit checkpoint and stay packed:
//! every projection is a `quantized_matmul`.
//!
//! ```no_run
//! use rustcore::{Engine, Event, Flow, GenerationConfig, Message, RenderOptions};
//! use rustmlx::MlxEngine;
//!
//! # fn main() -> anyhow::Result<()> {
//! let spec = rustcore::models::resolve("qwen3.8:27b-mlx", "main")?;
//! let files = rustcore::hub::local(&spec)?;
//! let mut engine = MlxEngine::load(&files)?;
//!
//! let prompt = engine
//!     .template()
//!     .render(&[Message::user("hello")], &RenderOptions::default())?;
//! engine.generate(&prompt, &GenerationConfig::default(), &mut |event| {
//!     if let Event::Token(text) = event {
//!         print!("{text}");
//!     }
//!     Flow::Continue
//! })?;
//! # Ok(())
//! # }
//! ```

pub mod attention;
pub mod cache;
pub mod config;
pub mod delta;
pub mod engine;
pub mod kernel;
pub mod layers;
pub mod memory;
pub mod model;
pub mod sample;
pub mod weights;

pub use config::{LayerKind, ModelConfig, TextConfig};
pub use engine::MlxEngine;
pub use model::Model;
pub use weights::Weights;
