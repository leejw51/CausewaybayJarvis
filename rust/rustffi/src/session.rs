//! A loaded model plus the conversation being held with it.
//!
//! The Rust front ends keep the engine and the message list apart, because they
//! can. A C caller would then have to own two handles with a lifetime rule
//! between them, so here they are one object: the session holds the weights,
//! the transcript, and the result of the last turn.

use std::os::raw::{c_char, c_void};

use anyhow::{anyhow, Context};
use rustcore::engine::{Completion, Engine, StopReason};
use rustcore::{hub, Message, Role};
use rustmlx::MlxEngine;

use crate::abi::{
    drop_handle, event_bridge, opt_str_arg, out_json, out_string, str_arg, Handle, JarvisEventFn,
    JarvisParams,
};
use crate::error::guard;

pub struct JarvisSession {
    magic: u64,
    engine: MlxEngine,
    alias: String,
    repo: String,
    messages: Vec<Message>,
    last: Option<Completion>,
}

impl Handle for JarvisSession {
    const MAGIC: u64 = 0x4a5f_7365_7373_5f31; // "J_sess_1"
    fn magic(&self) -> u64 {
        self.magic
    }
}

impl JarvisSession {
    fn system(&self) -> Option<&Message> {
        self.messages.first().filter(|m| m.role == Role::System)
    }
}

fn stop_reason(reason: StopReason) -> &'static str {
    match reason {
        StopReason::EndOfTurn => "end_of_turn",
        StopReason::Length => "length",
        StopReason::Interrupted => "interrupted",
    }
}

fn completion_json(c: &Completion) -> serde_json::Value {
    let s = &c.stats;
    serde_json::json!({
        "text": c.text,
        "reasoning": c.reasoning,
        "stop_reason": stop_reason(c.stop_reason),
        "stats": {
            "prompt_tokens": s.prompt_tokens,
            "cached_prompt_tokens": s.cached_prompt_tokens,
            "prefill_tokens": s.prefill_tokens(),
            "generated_tokens": s.generated_tokens,
            "reasoning_tokens": s.reasoning_tokens,
            "prefill_seconds": s.prefill_seconds,
            "decode_seconds": s.decode_seconds,
            "prefill_tps": s.prefill_tps(),
            "decode_tps": s.decode_tps(),
            "peak_memory": s.peak_memory,
        },
    })
}

/// Load a checkpoint that is already on disk and open a session on it.
///
/// This does not download: call [`crate::model::jarvis_pull_start`] first when
/// [`crate::model::jarvis_model_is_local`] says the weights are missing. It
/// takes seconds and holds the whole model resident, so a caller usually wants
/// exactly one of these.
///
/// # Safety
/// The arguments must be null or NUL-terminated strings.
#[no_mangle]
pub unsafe extern "C" fn jarvis_open(
    alias: *const c_char,
    revision: *const c_char,
    repo: *const c_char,
) -> *mut JarvisSession {
    guard(std::ptr::null_mut(), || {
        let spec = crate::model::spec(
            str_arg(alias, "alias")?,
            opt_str_arg(revision, "revision")?,
            opt_str_arg(repo, "repo")?,
        )?;
        let files = hub::local(&spec)?;
        let engine = MlxEngine::load_named(&files, Some(&spec.alias))
            .with_context(|| format!("loading {}", spec.repo))?;
        Ok(Box::into_raw(Box::new(JarvisSession {
            magic: JarvisSession::MAGIC,
            engine,
            alias: spec.alias,
            repo: spec.repo,
            messages: Vec::new(),
            last: None,
        })))
    })
}

/// Close a session and release the weights.
///
/// # Safety
/// `session` must be null or a live handle from [`jarvis_open`].
#[no_mangle]
pub unsafe extern "C" fn jarvis_close(session: *mut JarvisSession) {
    drop_handle(session, &mut |s: &mut JarvisSession| s.magic = 0);
}

/// What is loaded, as JSON.
///
/// # Safety
/// As [`jarvis_close`].
#[no_mangle]
pub unsafe extern "C" fn jarvis_info_json(session: *mut JarvisSession) -> *mut c_char {
    guard(std::ptr::null_mut(), || {
        let session = JarvisSession::borrow(session, "session")?;
        let info = session.engine.info();
        out_json(&serde_json::json!({
            "alias": session.alias,
            "repo": session.repo,
            "model": info.model,
            "architecture": info.architecture,
            "quantization": info.quantization,
            "parameters": info.parameters,
            "context_length": info.context_length,
            "weight_bytes": info.weight_bytes,
            "vocabulary": session.engine.tokenizer().vocab_size(),
            "cache_bytes": session.engine.cache_bytes(),
            "cached_tokens": session.engine.cached_tokens(),
            "messages": session.messages.len(),
        }))
    })
}

/// Replace the system prompt, dropping the cache it invalidates. A null or
/// empty `text` removes it.
///
/// # Safety
/// As [`jarvis_close`]; `text` must be null or a NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn jarvis_set_system(
    session: *mut JarvisSession,
    text: *const c_char,
) -> i32 {
    guard(-1, || {
        let session = JarvisSession::borrow(session, "session")?;
        let text = opt_str_arg(text, "text")?;
        let had_system = session.system().is_some();
        match (text, had_system) {
            (Some(text), true) => session.messages[0] = Message::system(text),
            (Some(text), false) => session.messages.insert(0, Message::system(text)),
            (None, true) => {
                session.messages.remove(0);
            }
            (None, false) => return Ok(0),
        }
        // Every later token was conditioned on the old system block.
        session.engine.reset();
        Ok(0)
    })
}

/// Forget the conversation, keeping the system prompt.
///
/// # Safety
/// As [`jarvis_close`].
#[no_mangle]
pub unsafe extern "C" fn jarvis_reset(session: *mut JarvisSession) -> i32 {
    guard(-1, || {
        let session = JarvisSession::borrow(session, "session")?;
        let system = session.system().cloned();
        session.messages.clear();
        session.messages.extend(system);
        session.last = None;
        session.engine.reset();
        Ok(0)
    })
}

/// The transcript as a JSON array of `{"role":…, "content":…}`.
///
/// # Safety
/// As [`jarvis_close`].
#[no_mangle]
pub unsafe extern "C" fn jarvis_messages_json(session: *mut JarvisSession) -> *mut c_char {
    guard(std::ptr::null_mut(), || {
        let session = JarvisSession::borrow(session, "session")?;
        Ok(out_string(serde_json::to_string_pretty(&session.messages)?))
    })
}

/// Replace the transcript with one that was saved earlier.
///
/// # Safety
/// As [`jarvis_close`]; `json` must be a NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn jarvis_messages_load(
    session: *mut JarvisSession,
    json: *const c_char,
) -> i32 {
    guard(-1, || {
        let session = JarvisSession::borrow(session, "session")?;
        let messages: Vec<Message> =
            serde_json::from_str(str_arg(json, "json")?).context("reading the transcript")?;
        session.messages = messages;
        session.last = None;
        session.engine.reset();
        Ok(0)
    })
}

/// The result of the last turn as JSON, or null if there has not been one.
///
/// # Safety
/// As [`jarvis_close`].
#[no_mangle]
pub unsafe extern "C" fn jarvis_last_json(session: *mut JarvisSession) -> *mut c_char {
    guard(std::ptr::null_mut(), || {
        let session = JarvisSession::borrow(session, "session")?;
        match &session.last {
            Some(c) => out_json(&completion_json(c)),
            None => Ok(std::ptr::null_mut()),
        }
    })
}

/// The exact string the model would be given for the conversation so far, with
/// `text` appended as a new user turn (or null for none). For debugging a
/// template, and for seeing what the cache is being asked to match.
///
/// # Safety
/// As [`jarvis_close`]; `params` must point at a `JarvisParams`.
#[no_mangle]
pub unsafe extern "C" fn jarvis_render(
    session: *mut JarvisSession,
    text: *const c_char,
    params: *const JarvisParams,
) -> *mut c_char {
    guard(std::ptr::null_mut(), || {
        let session = JarvisSession::borrow(session, "session")?;
        let params = params.as_ref().ok_or_else(|| anyhow!("`params` is null"))?;
        let mut messages = session.messages.clone();
        if let Some(text) = opt_str_arg(text, "text")? {
            messages.push(Message::user(text));
        }
        Ok(out_string(
            session
                .engine
                .template()
                .render(&messages, &params.render()?)?,
        ))
    })
}

/// Take one turn: append `text` as a user message, stream the answer through
/// `callback`, and append the reply to the transcript.
///
/// Returns 0 on success and -1 on failure, leaving the transcript unchanged if
/// the turn could not be taken at all. A turn the callback stopped early still
/// counts as a success — the reply is whatever had been generated by then, and
/// `jarvis_last_json` reports `"interrupted"`.
///
/// # Safety
/// As [`jarvis_close`]. `callback` may be null; when it is not, it must be safe
/// to call with `user` from this thread until the call returns.
#[no_mangle]
pub unsafe extern "C" fn jarvis_send(
    session: *mut JarvisSession,
    text: *const c_char,
    params: *const JarvisParams,
    callback: JarvisEventFn,
    user: *mut c_void,
) -> i32 {
    guard(-1, || {
        let session = JarvisSession::borrow(session, "session")?;
        let text = str_arg(text, "text")?;
        let params = params.as_ref().ok_or_else(|| anyhow!("`params` is null"))?;
        anyhow::ensure!(!text.trim().is_empty(), "there is nothing to answer");

        let render = params.render()?;
        session.messages.push(Message::user(text));
        let prompt = match session.engine.template().render(&session.messages, &render) {
            Ok(prompt) => prompt,
            Err(e) => {
                session.messages.pop();
                return Err(e);
            }
        };

        let mut bridge = event_bridge(callback, user);
        let completion = match session
            .engine
            .generate(&prompt, &params.generation(), &mut bridge)
        {
            Ok(completion) => completion,
            Err(e) => {
                session.messages.pop();
                return Err(e);
            }
        };

        let mut reply = Message::assistant(completion.text.clone());
        if let Some(reasoning) = &completion.reasoning {
            reply = reply.with_reasoning(reasoning.clone());
        }
        session.messages.push(reply);
        session.last = Some(completion);
        Ok(0)
    })
}

/// Run a raw, already-templated prompt without touching the transcript.
///
/// The KV cache is shared with the conversation, so a raw completion in the
/// middle of a chat costs the next turn its cached prefix. Used for benchmarks
/// and for callers doing their own templating.
///
/// # Safety
/// As [`jarvis_send`].
#[no_mangle]
pub unsafe extern "C" fn jarvis_generate(
    session: *mut JarvisSession,
    prompt: *const c_char,
    params: *const JarvisParams,
    callback: JarvisEventFn,
    user: *mut c_void,
) -> i32 {
    guard(-1, || {
        let session = JarvisSession::borrow(session, "session")?;
        let prompt = str_arg(prompt, "prompt")?;
        let params = params.as_ref().ok_or_else(|| anyhow!("`params` is null"))?;

        let mut bridge = event_bridge(callback, user);
        let completion = session
            .engine
            .generate(prompt, &params.generation(), &mut bridge)?;
        session.last = Some(completion);
        Ok(0)
    })
}

/// Tokens the KV and recurrent caches currently cover.
///
/// # Safety
/// As [`jarvis_close`].
#[no_mangle]
pub unsafe extern "C" fn jarvis_cached_tokens(session: *mut JarvisSession) -> u64 {
    guard(0, || {
        let session = JarvisSession::borrow(session, "session")?;
        Ok(session.engine.cached_tokens() as u64)
    })
}

/// Bytes those caches occupy.
///
/// # Safety
/// As [`jarvis_close`].
#[no_mangle]
pub unsafe extern "C" fn jarvis_cache_bytes(session: *mut JarvisSession) -> u64 {
    guard(0, || {
        let session = JarvisSession::borrow(session, "session")?;
        Ok(session.engine.cache_bytes())
    })
}

/// Encode text with the model's own tokenizer and return the token count.
/// -1 on failure.
///
/// # Safety
/// As [`jarvis_close`]; `text` must be a NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn jarvis_count_tokens(
    session: *mut JarvisSession,
    text: *const c_char,
) -> i64 {
    guard(-1, || {
        let session = JarvisSession::borrow(session, "session")?;
        let ids = session.engine.tokenizer().encode(str_arg(text, "text")?)?;
        Ok(ids.len() as i64)
    })
}

/// Cut `text` down to at most `max_tokens` tokens, on a token boundary.
///
/// Encoding and decoding again is the only way to land exactly on one, and a
/// caller filling a context window — or building a prompt of a known length for
/// a benchmark — needs that rather than a character count.
///
/// # Safety
/// As [`jarvis_close`]; `text` must be a NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn jarvis_truncate(
    session: *mut JarvisSession,
    text: *const c_char,
    max_tokens: usize,
) -> *mut c_char {
    guard(std::ptr::null_mut(), || {
        let session = JarvisSession::borrow(session, "session")?;
        let tokenizer = session.engine.tokenizer();
        let ids = tokenizer.encode(str_arg(text, "text")?)?;
        let keep = ids.len().min(max_tokens);
        Ok(out_string(tokenizer.decode(&ids[..keep])?))
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use rustcore::engine::Stats;

    #[test]
    fn a_completion_reports_both_rates_and_why_it_stopped() {
        let json = completion_json(&Completion {
            text: "4".into(),
            reasoning: Some("two plus two".into()),
            stop_reason: StopReason::Interrupted,
            stats: Stats {
                prompt_tokens: 100,
                cached_prompt_tokens: 80,
                generated_tokens: 10,
                prefill_seconds: 0.2,
                decode_seconds: 1.0,
                ..Default::default()
            },
        });
        assert_eq!(json["text"], "4");
        assert_eq!(json["reasoning"], "two plus two");
        assert_eq!(json["stop_reason"], "interrupted");
        assert_eq!(json["stats"]["prefill_tokens"], 20);
        assert_eq!(json["stats"]["decode_tps"], 10.0);
    }

    #[test]
    fn no_reasoning_block_is_null_rather_than_missing() {
        let json = completion_json(&Completion {
            text: "hi".into(),
            reasoning: None,
            stop_reason: StopReason::EndOfTurn,
            stats: Stats::default(),
        });
        assert!(json["reasoning"].is_null());
    }
}
