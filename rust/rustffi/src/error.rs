//! Errors across a C boundary: a thread-local slot, and a wrapper that stops a
//! Rust panic from unwinding into the caller.
//!
//! Every entry point returns a sentinel on failure — null for pointers, a
//! negative number for status codes — and leaves the reason in
//! [`jarvis_last_error`].

use std::cell::RefCell;
use std::ffi::CString;
use std::os::raw::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};

thread_local! {
    static LAST_ERROR: RefCell<Option<CString>> = const { RefCell::new(None) };
}

pub fn set_error(message: impl Into<String>) {
    // A message with an interior NUL cannot be a C string; a lossy one beats
    // losing the error entirely.
    let text = message.into().replace('\0', "\u{fffd}");
    let c = CString::new(text).unwrap_or_else(|_| CString::new("error").unwrap());
    LAST_ERROR.with(|slot| *slot.borrow_mut() = Some(c));
}

pub fn clear_error() {
    LAST_ERROR.with(|slot| *slot.borrow_mut() = None);
}

/// The last error on this thread, or `NULL` if the last call succeeded.
///
/// The pointer stays valid until the next call into this library on the same
/// thread. Copy it if you need to keep it.
#[no_mangle]
pub extern "C" fn jarvis_last_error() -> *const c_char {
    LAST_ERROR.with(|slot| match &*slot.borrow() {
        Some(c) => c.as_ptr(),
        None => std::ptr::null(),
    })
}

/// Run `f`, converting an error or a panic into `fallback` plus a message.
///
/// The closure is asserted unwind-safe: a panic here is a bug in this library
/// rather than an expected control flow, and the alternative — letting it
/// unwind into C — is undefined behaviour.
pub fn guard<T>(fallback: T, f: impl FnOnce() -> anyhow::Result<T>) -> T {
    clear_error();
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(Ok(value)) => value,
        Ok(Err(err)) => {
            set_error(format!("{err:#}"));
            fallback
        }
        Err(panic) => {
            set_error(format!("panic: {}", panic_message(&panic)));
            fallback
        }
    }
}

fn panic_message(panic: &Box<dyn std::any::Any + Send>) -> String {
    if let Some(s) = panic.downcast_ref::<&str>() {
        (*s).to_string()
    } else if let Some(s) = panic.downcast_ref::<String>() {
        s.clone()
    } else {
        "unknown".to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_failure_leaves_a_readable_message() {
        let n = guard(-1, || anyhow::bail!("no such model `llama-42`"));
        assert_eq!(n, -1);
        let msg = unsafe { std::ffi::CStr::from_ptr(jarvis_last_error()) };
        assert_eq!(msg.to_str().unwrap(), "no such model `llama-42`");
    }

    #[test]
    fn success_clears_the_previous_error() {
        guard(-1, || anyhow::bail!("boom"));
        assert_eq!(guard(0, || Ok(0)), 0);
        assert!(jarvis_last_error().is_null());
    }

    #[test]
    fn a_panic_is_caught_rather_than_unwound_into_c() {
        let n = guard(-1, || panic!("held it wrong"));
        assert_eq!(n, -1);
        let msg = unsafe { std::ffi::CStr::from_ptr(jarvis_last_error()) };
        assert!(msg.to_str().unwrap().contains("held it wrong"));
    }
}
