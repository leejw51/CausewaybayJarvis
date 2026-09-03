//! The robot backend, in the caller's own process.
//!
//! Everything `agentd` serves — the archive, the roster, both searches, a
//! turn against the model with its tools — reached by calling a function
//! instead of by opening a socket to another process.
//!
//! ```c
//! jarvis_agent_open("/Users/me/.causewaybayjarvis", NULL);
//! char *reply = jarvis_agent_call("{\"op\":\"agents.list\"}", NULL, NULL);
//! puts(reply);                       /* {"ok":true,"op":"agents.list",…} */
//! jarvis_string_free(reply);
//! ```
//!
//! The reply is the same envelope the daemon would put on the wire, because
//! it is the same dispatch: [`rustagent::server::answer`]. A caller that can
//! already read one protocol therefore needs no second one, and an op cannot
//! behave differently here than it does over a socket.
//!
//! **One space per process.** The backend holds an open SQLite database and,
//! in a turn, the model — fifteen gigabytes that only make sense loaded once.
//! [`jarvis_agent_open`] replaces whatever was open before, and every call is
//! serialised behind one lock: a second thread's call waits rather than
//! racing, which is what the daemon's single dispatcher thread does too.
//!
//! **Streaming** works as it does for a session: the callback fires on the
//! calling thread as the turn is written — [`EVENT_TOKEN`] for the answer,
//! [`EVENT_REASONING`] for thinking, [`EVENT_TOOL`] for what the turn ran,
//! [`EVENT_PREFILL`] with `a` of `b` tokens read — and returning non-zero
//! stops the turn. Ops that are not a turn never call it. Pass `NULL` and the
//! whole thing is one blocking call that answers when it is done.

use std::ffi::CString;
use std::os::raw::{c_char, c_void};
use std::sync::Mutex;

use anyhow::{anyhow, Result};
use serde_json::Value;

use rustagent::harness::Chunk;
use rustagent::proto::Backend;
use rustagent::setup::Overrides;
use rustagent::space::Space;

use crate::abi::{
    opt_str_arg, out_json, out_string, str_arg, JarvisEventFn, EVENT_PREFILL, EVENT_REASONING,
    EVENT_TOKEN, EVENT_TOOL,
};
use crate::error::guard;

/// The one open space. `None` until [`jarvis_agent_open`] succeeds.
static AGENT: Mutex<Option<Backend>> = Mutex::new(None);

fn open_space() -> Result<std::sync::MutexGuard<'static, Option<Backend>>> {
    // A poisoned lock means a panic escaped a call while it was held. The
    // backend behind it is of unknown soundness, so say so rather than hand
    // it back: the caller can reopen and get a clean one.
    AGENT.lock().map_err(|_| {
        anyhow!("the backend panicked in an earlier call — call jarvis_agent_open again")
    })
}

/// Open a space: the archive, the roster and whatever brain the setup names.
///
/// `root` is the directory to open — `~/.causewaybayjarvis` when it is NULL,
/// or wherever `JARVIS_HOME` points. `overrides_json` is a JSON object of
/// environment-shaped settings for this backend alone, the in-process
/// equivalent of the variables a caller puts on `agentd`'s command line; NULL
/// is none. Returns 0, or -1 with the reason in `jarvis_last_error`.
///
/// Opening again closes what was open first, model included.
///
/// # Safety
/// Both pointers, if not NULL, must be NUL-terminated UTF-8, valid for the
/// call.
#[no_mangle]
pub unsafe extern "C" fn jarvis_agent_open(
    root: *const c_char,
    overrides_json: *const c_char,
) -> i32 {
    guard(-1, || {
        let root = opt_str_arg(root, "root")?;
        let overrides = match opt_str_arg(overrides_json, "overrides_json")? {
            Some(text) => {
                let value: Value = serde_json::from_str(text)?;
                Overrides::from_json(&value).map_err(|e| anyhow!(e))?
            }
            None => Overrides::default(),
        };
        let space = match root {
            Some(root) => Space::at(root)?,
            None => Space::discover()?,
        };
        // Dropped before the new one is built, so two backends never hold the
        // same database — or, in an mlx build, two copies of the model.
        let mut slot = open_space()?;
        *slot = None;
        *slot = Some(Backend::at_with(space, overrides)?);
        Ok(0)
    })
}

/// Is a space open?
#[no_mangle]
pub extern "C" fn jarvis_agent_is_open() -> i32 {
    guard(0, || Ok(i32::from(open_space()?.is_some())))
}

/// The root of the open space, or NULL when none is open. Free with
/// `jarvis_string_free`.
#[no_mangle]
pub extern "C" fn jarvis_agent_root() -> *mut c_char {
    guard(std::ptr::null_mut(), || {
        let slot = open_space()?;
        let backend = slot
            .as_ref()
            .ok_or_else(|| anyhow!("no space is open — call jarvis_agent_open first"))?;
        Ok(out_string(
            backend.store.space.root().to_string_lossy().to_string(),
        ))
    })
}

/// One request, answered. The reply is the protocol envelope as JSON text,
/// owned by the caller; free it with `jarvis_string_free`.
///
/// A refusal *by the backend* — an unknown op, a missing argument — is a
/// reply like any other, with `"ok": false` and an `"error"` in it. NULL is
/// returned only when the request never reached the backend at all: no space
/// open, or text that is not JSON. The reason is in `jarvis_last_error`.
///
/// `callback` is optional and fires only for `chat` and `brain.chat`, on this
/// thread, as the turn is written. Return 0 from it to continue, non-zero to
/// stop the turn and take the partial answer.
///
/// # Safety
/// `request_json` must be NUL-terminated UTF-8, valid for the call.
/// `callback`, if set, must be safe to call with `user` until this returns —
/// and must not call back into this library on the same space, which would
/// deadlock on the lock this call holds.
#[no_mangle]
pub unsafe extern "C" fn jarvis_agent_call(
    request_json: *const c_char,
    callback: JarvisEventFn,
    user: *mut c_void,
) -> *mut c_char {
    guard(std::ptr::null_mut(), || {
        let text = str_arg(request_json, "request_json")?;
        let request: Value =
            serde_json::from_str(text).map_err(|e| anyhow!("request_json is not JSON: {e}"))?;

        let slot = open_space()?;
        let backend = slot
            .as_ref()
            .ok_or_else(|| anyhow!("no space is open — call jarvis_agent_open first"))?;

        let mut sink = |chunk: Chunk<'_>| {
            let Some(callback) = callback else {
                return true;
            };
            let (kind, text, a, b) = match chunk {
                Chunk::Prefill { done, total } => (EVENT_PREFILL, None, done as u64, total as u64),
                Chunk::Reasoning(t) => (EVENT_REASONING, Some(t), 0, 0),
                Chunk::Token(t) => (EVENT_TOKEN, Some(t), 0, 0),
                Chunk::Tool(t) => (EVENT_TOOL, Some(t), 0, 0),
            };
            // One allocation per chunk, against a turn that is doing rather
            // more than that between them.
            let owned = text.map(|t| CString::new(t.replace('\0', "\u{fffd}")).unwrap_or_default());
            let (ptr, len) = match &owned {
                Some(c) => (c.as_ptr(), c.as_bytes().len()),
                None => (std::ptr::null(), 0),
            };
            unsafe { callback(kind, ptr, len, a, b, user) == 0 }
        };

        out_json(&rustagent::server::answer(backend, &request, &mut sink))
    })
}

/// Close the space: the database, and the model with it. A no-op when none is
/// open. Not required before exit — the process closing does the same thing —
/// but it is how a caller gives back the memory a turn's model is holding.
#[no_mangle]
pub extern "C" fn jarvis_agent_close() {
    guard((), || {
        *open_space()? = None;
        Ok(())
    })
}
