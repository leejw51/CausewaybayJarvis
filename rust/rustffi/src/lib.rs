//! A C ABI for **Causewaybay Jarvis**, so the agent can be driven from anything
//! with an FFI. The Lua chat client in `lua/` is the reference consumer.
//!
//! The library is `libjarvis`. `include/jarvis.h` is the canonical declaration
//! of everything below; a binding either includes it or mirrors it, and checks
//! [`jarvis_abi_version`](abi::jarvis_abi_version) at load time.
//!
//! Four rules hold everywhere:
//!
//! * **Strings in** are NUL-terminated UTF-8, borrowed for the call only.
//! * **Strings out** are owned by the caller and freed with
//!   [`jarvis_string_free`](abi::jarvis_string_free). Structured results come
//!   back as JSON text rather than as more structs to keep in step.
//! * **Failure** is a null pointer or a negative number, with the reason in
//!   [`jarvis_last_error`](error::jarvis_last_error) — thread-local, valid
//!   until the next call on that thread.
//! * **Nothing unwinds.** Every entry point catches panics and turns them into
//!   an error.
//!
//! A session is not `Sync`: MLX drives one GPU queue, and the whole engine
//! expects to be driven from a single thread. Use it from the thread that
//! opened it. Downloads are the exception, and they run behind a polling
//! handle for exactly that reason — see [`model::jarvis_pull_start`].
//!
//! ```c
//! JarvisParams p;
//! jarvis_params_default(&p);
//! JarvisSession *s = jarvis_open("qwen3.8:27b-mlx", NULL, NULL);
//! if (!s) { fprintf(stderr, "%s\n", jarvis_last_error()); return 1; }
//! jarvis_set_system(s, "You are Jarvis.");
//! jarvis_send(s, "why is the sky blue?", &p, on_event, NULL);
//! jarvis_close(s);
//! ```

pub mod abi;
pub mod config;
pub mod error;
pub mod model;
pub mod session;

use std::os::raw::c_char;
use std::sync::atomic::{AtomicBool, Ordering};

pub use abi::{
    jarvis_abi_version, jarvis_monotonic, jarvis_params_default, jarvis_sizeof_params,
    jarvis_sizeof_progress, jarvis_string_free, JarvisEventFn, JarvisParams, JarvisProgress,
};
pub use config::JarvisConfig;
pub use error::jarvis_last_error;
pub use model::JarvisPull;
pub use session::JarvisSession;

/// The version of this library, as `x.y.z`. Static storage; do not free.
#[no_mangle]
pub extern "C" fn jarvis_version() -> *const c_char {
    concat!(env!("CARGO_PKG_VERSION"), "\0").as_ptr().cast()
}

/// MLX's current allocation, in bytes.
#[no_mangle]
pub extern "C" fn jarvis_memory_active() -> u64 {
    rustmlx::memory::active()
}

/// The high-water mark since the last turn began.
#[no_mangle]
pub extern "C" fn jarvis_memory_peak() -> u64 {
    rustmlx::memory::peak()
}

/* ---------------------------------------------------------- interrupts ---- */

static INTERRUPTED: AtomicBool = AtomicBool::new(false);

/// Take over Ctrl-C, so a long answer can be stopped without killing the
/// process. The handler only sets a flag; the caller polls
/// [`jarvis_interrupt_raised`] from inside its event callback and returns
/// non-zero to stop the turn.
///
/// This exists because a signal handler cannot safely re-enter most language
/// runtimes — a LuaJIT callback invoked from one would be undefined behaviour,
/// but reading an atomic between tokens is fine.
///
/// Returns 0 on success, or -1 if a handler was already installed (by this
/// library or anything else in the process).
#[no_mangle]
pub extern "C" fn jarvis_interrupt_install() -> i32 {
    error::guard(-1, || {
        ctrlc::set_handler(|| INTERRUPTED.store(true, Ordering::Relaxed))?;
        Ok(0)
    })
}

/// 1 if Ctrl-C has been pressed since the flag was last cleared.
#[no_mangle]
pub extern "C" fn jarvis_interrupt_raised() -> i32 {
    INTERRUPTED.load(Ordering::Relaxed) as i32
}

#[no_mangle]
pub extern "C" fn jarvis_interrupt_clear() {
    INTERRUPTED.store(false, Ordering::Relaxed);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_version_is_a_readable_c_string() {
        let v = unsafe { std::ffi::CStr::from_ptr(jarvis_version()) };
        assert_eq!(v.to_str().unwrap(), env!("CARGO_PKG_VERSION"));
    }

    #[test]
    fn the_interrupt_flag_is_set_and_cleared() {
        jarvis_interrupt_clear();
        assert_eq!(jarvis_interrupt_raised(), 0);
        INTERRUPTED.store(true, Ordering::Relaxed);
        assert_eq!(jarvis_interrupt_raised(), 1);
        jarvis_interrupt_clear();
        assert_eq!(jarvis_interrupt_raised(), 0);
    }
}
