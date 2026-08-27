//! The shapes that cross the boundary: strings, handles, parameters, events.

use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_void};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Mutex, MutexGuard};

use anyhow::{anyhow, Result};
use rustcore::config::{GenerationSettings, ThinkingConfig};
use rustcore::engine::{Event, Flow, GenerationConfig};
use rustcore::RenderOptions;

/// Bumped whenever a struct layout or a signature below changes. A binding
/// checks it at load time; see `jarvis_abi_version`.
pub const ABI_VERSION: u32 = 1;

/// Borrow a required C string argument.
///
/// # Safety
/// `ptr` must be null or a NUL-terminated string that outlives the call.
pub unsafe fn str_arg<'a>(ptr: *const c_char, name: &str) -> Result<&'a str> {
    if ptr.is_null() {
        return Err(anyhow!("`{name}` must not be null"));
    }
    CStr::from_ptr(ptr)
        .to_str()
        .map_err(|_| anyhow!("`{name}` is not valid UTF-8"))
}

/// Borrow an optional C string argument. Null and empty both mean "absent".
///
/// # Safety
/// As [`str_arg`].
pub unsafe fn opt_str_arg<'a>(ptr: *const c_char, name: &str) -> Result<Option<&'a str>> {
    if ptr.is_null() {
        return Ok(None);
    }
    let s = str_arg(ptr, name)?;
    Ok((!s.is_empty()).then_some(s))
}

/// Hand a string to the caller. Freed with `jarvis_string_free`.
pub fn out_string(text: impl Into<String>) -> *mut c_char {
    let text = text.into().replace('\0', "\u{fffd}");
    match CString::new(text) {
        Ok(c) => c.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

pub fn out_json(value: &serde_json::Value) -> Result<*mut c_char> {
    Ok(out_string(serde_json::to_string(value)?))
}

/// Release a string returned by this library. Null is fine.
///
/// # Safety
/// `text` must have come from this library and must not be freed twice.
#[no_mangle]
pub unsafe extern "C" fn jarvis_string_free(text: *mut c_char) {
    if !text.is_null() {
        drop(CString::from_raw(text));
    }
}

/// The layout `jarvis_abi_version` promises.
#[no_mangle]
pub extern "C" fn jarvis_abi_version() -> u32 {
    ABI_VERSION
}

#[no_mangle]
pub extern "C" fn jarvis_sizeof_params() -> usize {
    std::mem::size_of::<JarvisParams>()
}

#[no_mangle]
pub extern "C" fn jarvis_sizeof_progress() -> usize {
    std::mem::size_of::<JarvisProgress>()
}

/// Seconds from an arbitrary fixed point. For throttling a progress display in
/// a language whose own clock only counts CPU time.
#[no_mangle]
pub extern "C" fn jarvis_monotonic() -> f64 {
    use std::sync::OnceLock;
    use std::time::Instant;
    static ORIGIN: OnceLock<Instant> = OnceLock::new();
    ORIGIN.get_or_init(Instant::now).elapsed().as_secs_f64()
}

/* ------------------------------------------------------------ handles ---- */

/// Every handle this library has handed out and not yet freed.
///
/// A tag written *inside* the allocation cannot be the check on its own, for
/// two reasons. Reading one back through a pointer that has already been freed
/// is undefined behaviour; and the allocator is free to hand the same block out
/// again for the next session, at which point a stale pointer reads a perfectly
/// valid tag and starts addressing somebody else's session.
///
/// So what a caller holds is not the address of anything. It is a token from a
/// counter that only ever goes up, looked up here on the way back in. A token
/// is never reused, so a handle that has been closed stays refused for the life
/// of the process, and nothing is dereferenced until the lookup has said which
/// live object the token stands for.
///
/// A `Vec` and a linear scan: a process holds a session, a config and a
/// download at once, not thousands of them.
static LIVE: Mutex<Vec<Entry>> = Mutex::new(Vec::new());

/// Tokens are spaced out and never start at zero, so that one is null only when
/// the library failed and looks like a pointer everywhere it has to.
static NEXT_TOKEN: AtomicUsize = AtomicUsize::new(8);

struct Entry {
    /// What the caller was given, in place of an address.
    token: usize,
    tag: u64,
    /// What it stands for.
    object: *mut (),
    /// Set while a call that hands control back to the caller's language is in
    /// flight on this handle. See [`Busy`].
    busy: bool,
}

// The pointer is only ever handed back to the thread that is allowed to use it;
// this list carries it rather than dereferencing it.
unsafe impl Send for Entry {}

/// A poisoned lock only means a panic happened while the list was borrowed; the
/// list is still a list, and refusing every handle from then on would be worse
/// than carrying on with it.
fn live() -> MutexGuard<'static, Vec<Entry>> {
    LIVE.lock().unwrap_or_else(|e| e.into_inner())
}

fn find(live: &[Entry], token: usize, tag: u64) -> Option<usize> {
    live.iter().position(|e| e.token == token && e.tag == tag)
}

/// An opaque pointer handed to the caller, checked on the way back in.
pub trait Handle: Sized {
    /// Distinguishes one kind of handle from another, so a `JarvisConfig *`
    /// passed where a `JarvisSession *` belongs is refused rather than used.
    const TAG: u64;

    /// Box this value and register it. What comes back is the caller's handle:
    /// opaque, never dereferenced by anyone but this module.
    fn into_handle(self) -> *mut Self {
        let object = Box::into_raw(Box::new(self));
        let token = NEXT_TOKEN.fetch_add(8, Ordering::Relaxed);
        live().push(Entry {
            token,
            tag: Self::TAG,
            object: object.cast(),
            busy: false,
        });
        token as *mut Self
    }

    /// # Safety
    /// `ptr` must be null, or a handle this library returned.
    unsafe fn borrow<'a>(ptr: *mut Self, name: &str) -> Result<&'a mut Self> {
        if ptr.is_null() {
            return Err(anyhow!("`{name}` must not be null"));
        }
        let found = {
            let live = live();
            find(&live, ptr as usize, Self::TAG).map(|i| (live[i].object, live[i].busy))
        };
        match found {
            None => Err(anyhow!("`{name}` is not a live {name} handle")),
            Some((_, true)) => Err(anyhow!(
                "`{name}` is already inside a call — this library cannot be \
                 re-entered on the same handle from an event callback"
            )),
            Some((object, false)) => Ok(&mut *object.cast::<Self>()),
        }
    }
}

/// Free a handle, retiring its token first so that it is refused from here on —
/// including by a second free of the same handle.
///
/// A handle that is busy is left alone: freeing it would pull the object out
/// from under the call still running on it, which is worse than leaking it.
///
/// # Safety
/// `ptr` must be null, or a handle this library returned.
pub unsafe fn drop_handle<T: Handle>(ptr: *mut T) {
    if ptr.is_null() {
        return;
    }
    let mut live = live();
    let Some(i) = find(&live, ptr as usize, T::TAG) else {
        return;
    };
    if live[i].busy {
        crate::error::set_error("this handle is inside a call and cannot be freed yet");
        return;
    }
    let object = live.swap_remove(i).object;
    drop(live);
    drop(Box::from_raw(object.cast::<T>()));
}

/// Marks a handle busy for as long as this value lives.
///
/// A turn hands control back to the caller's language for every token, and that
/// language can call straight back in. Doing so on the handle whose `&mut` the
/// outer call still holds would alias it — undefined behaviour — so while the
/// flag is set, [`Handle::borrow`] refuses the handle instead of handing out a
/// second reference, and [`drop_handle`] declines to free it.
pub struct Busy {
    token: Option<usize>,
    tag: u64,
}

impl Busy {
    pub fn claim<T: Handle>(handle: &T) -> Self {
        let object = handle as *const T as *mut ();
        let mut live = live();
        let token = live
            .iter_mut()
            .find(|e| std::ptr::eq(e.object, object) && e.tag == T::TAG)
            .map(|e| {
                e.busy = true;
                e.token
            });
        Self { token, tag: T::TAG }
    }
}

impl Drop for Busy {
    fn drop(&mut self) {
        let Some(token) = self.token else { return };
        let mut live = live();
        if let Some(i) = find(&live, token, self.tag) {
            live[i].busy = false;
        }
    }
}

/* --------------------------------------------------------- parameters ---- */

/// Everything one turn needs. Lay this out by hand rather than deriving it from
/// the Rust types: a binding has to be able to write the same struct.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct JarvisParams {
    /// Sampler seed, honoured only when `has_seed` is non-zero.
    pub seed: u64,
    pub max_tokens: u32,
    pub top_k: u32,
    pub repetition_context: u32,
    pub has_seed: i32,
    /// Let the model open a `<think>` block.
    pub enable_thinking: i32,
    /// Keep earlier `<think>` blocks in the prompt, which is what lets the KV
    /// cache be reused from one turn to the next.
    pub preserve_thinking: i32,
    pub temperature: f32,
    pub top_p: f32,
    pub min_p: f32,
    pub repetition_penalty: f32,
    /// `low`, `medium` or `xhigh`, NUL-padded.
    pub reasoning_effort: [c_char; 16],
}

impl JarvisParams {
    pub fn effort(&self) -> Result<&str> {
        // Safety: the array is part of `self`, so all 16 bytes are readable.
        // The read is bounded by that length rather than by a NUL: a caller
        // that filled the field to the brim left no terminator behind, and
        // running off the end of the struct looking for one is not an option.
        let bytes: &[u8] =
            unsafe { std::slice::from_raw_parts(self.reasoning_effort.as_ptr().cast(), 16) };
        let end = bytes.iter().position(|&b| b == 0).unwrap_or(bytes.len());
        let s = std::str::from_utf8(&bytes[..end])
            .map_err(|_| anyhow!("`reasoning_effort` is not valid UTF-8"))?;
        Ok(if s.is_empty() { "low" } else { s })
    }

    fn set_effort(&mut self, effort: &str) {
        self.reasoning_effort = [0; 16];
        for (slot, byte) in self
            .reasoning_effort
            .iter_mut()
            .take(15)
            .zip(effort.as_bytes())
        {
            *slot = *byte as c_char;
        }
    }

    pub fn generation(&self) -> GenerationConfig {
        GenerationConfig {
            max_tokens: self.max_tokens as usize,
            temperature: self.temperature,
            top_p: self.top_p,
            top_k: self.top_k as usize,
            min_p: self.min_p,
            repetition_penalty: self.repetition_penalty,
            repetition_context: self.repetition_context as usize,
            seed: (self.has_seed != 0).then_some(self.seed),
        }
    }

    pub fn render(&self) -> Result<RenderOptions> {
        let effort = self.effort()?;
        // Reject an unknown effort here rather than inside the template, where
        // it would surface halfway through a turn.
        rustcore::chat::reasoning_instructions(effort)?;
        Ok(RenderOptions {
            add_generation_prompt: true,
            enable_thinking: self.enable_thinking != 0,
            reasoning_effort: effort.to_string(),
            preserve_thinking: self.preserve_thinking != 0,
            tools: None,
        })
    }

    pub fn from_settings(generation: &GenerationSettings, thinking: &ThinkingConfig) -> Self {
        let mut p = Self {
            seed: generation.seed.unwrap_or(0),
            max_tokens: generation.max_tokens as u32,
            top_k: generation.top_k as u32,
            repetition_context: generation.repetition_context as u32,
            has_seed: generation.seed.is_some() as i32,
            enable_thinking: thinking.enabled as i32,
            preserve_thinking: 1,
            temperature: generation.temperature,
            top_p: generation.top_p,
            min_p: generation.min_p,
            repetition_penalty: generation.repetition_penalty,
            reasoning_effort: [0; 16],
        };
        p.set_effort(&thinking.effort);
        p
    }
}

impl Default for JarvisParams {
    fn default() -> Self {
        Self::from_settings(&GenerationSettings::default(), &ThinkingConfig::default())
    }
}

/// Fill `out` with the compiled-in defaults.
///
/// # Safety
/// `out` must point at writable storage of `jarvis_sizeof_params()` bytes.
#[no_mangle]
pub unsafe extern "C" fn jarvis_params_default(out: *mut JarvisParams) -> i32 {
    crate::error::guard(-1, || {
        if out.is_null() {
            return Err(anyhow!("`out` must not be null"));
        }
        out.write(JarvisParams::default());
        Ok(0)
    })
}

/* ------------------------------------------------------------- events ---- */

pub const EVENT_PREFILL: i32 = 0;
pub const EVENT_REASONING: i32 = 1;
pub const EVENT_TOKEN: i32 = 2;
pub const EVENT_REASONING_DONE: i32 = 3;

/// Called for every event of a turn, on the thread that started it.
///
/// `text` is NUL-terminated and `len` bytes long, and is only valid for the
/// duration of the call. Return zero to continue, non-zero to stop generating.
pub type JarvisEventFn = Option<
    unsafe extern "C" fn(
        kind: i32,
        text: *const c_char,
        len: usize,
        a: u64,
        b: u64,
        user: *mut c_void,
    ) -> i32,
>;

/// Adapt a C callback into the closure `Engine::generate` wants.
///
/// # Safety
/// `callback`, if set, must be safe to call with `user` for the whole turn.
pub unsafe fn event_bridge(
    callback: JarvisEventFn,
    user: *mut c_void,
) -> impl FnMut(Event) -> Flow {
    move |event| {
        let Some(callback) = callback else {
            return Flow::Continue;
        };
        let (kind, text, a, b) = match &event {
            Event::Prefill { done, total } => (EVENT_PREFILL, None, *done as u64, *total as u64),
            Event::Reasoning(t) => (EVENT_REASONING, Some(t), 0, 0),
            Event::Token(t) => (EVENT_TOKEN, Some(t), 0, 0),
            Event::ReasoningDone => (EVENT_REASONING_DONE, None, 0, 0),
        };
        // One allocation per chunk, against a forward pass over 27B parameters.
        let owned = text.map(|t| CString::new(t.replace('\0', "\u{fffd}")).unwrap_or_default());
        let (ptr, len) = match &owned {
            Some(c) => (c.as_ptr(), c.as_bytes().len()),
            None => (std::ptr::null(), 0),
        };
        if callback(kind, ptr, len, a, b, user) == 0 {
            Flow::Continue
        } else {
            Flow::Stop
        }
    }
}

/* ----------------------------------------------------------- progress ---- */

/// A snapshot of a download in flight. Plain data with no pointers, so a caller
/// can allocate one on its own stack and hand it to `jarvis_pull_poll`.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct JarvisProgress {
    pub files_total: u64,
    pub files_done: u64,
    pub bytes_total: u64,
    pub bytes_done: u64,
    pub finished: i32,
    pub _reserved: i32,
    /// The file that most recently made progress, NUL-padded and truncated.
    pub current: [c_char; 128],
}

impl From<&rustcore::hub::DownloadProgress> for JarvisProgress {
    fn from(p: &rustcore::hub::DownloadProgress) -> Self {
        let mut out = Self {
            files_total: p.files_total as u64,
            files_done: p.files_done as u64,
            bytes_total: p.bytes_total,
            bytes_done: p.bytes_done,
            finished: p.finished as i32,
            _reserved: 0,
            current: [0; 128],
        };
        if let Some(name) = &p.current {
            for (slot, byte) in out.current.iter_mut().take(127).zip(name.as_bytes()) {
                *slot = *byte as c_char;
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Debug)]
    struct Probe(u32);
    impl Handle for Probe {
        const TAG: u64 = 0x5f5f_7072_6f62_655f; // "__probe_"
    }

    struct Other;
    impl Handle for Other {
        const TAG: u64 = 0x5f5f_6f74_6865_725f; // "__other_"
    }

    #[test]
    fn a_handle_round_trips_to_the_object_it_stands_for() {
        let handle = Probe(7).into_handle();
        assert!(!handle.is_null());
        assert_eq!(unsafe { Probe::borrow(handle, "probe") }.unwrap().0, 7);
        unsafe { drop_handle(handle) };
    }

    #[test]
    fn a_freed_handle_stays_refused_however_the_allocator_reuses_the_memory() {
        let first = Probe(1).into_handle();
        unsafe { drop_handle(first) };

        // The allocator is very likely to hand the same block straight back.
        // The handle is a token rather than that address, so the stale one is
        // refused instead of silently addressing the new object.
        let second = Probe(2).into_handle();
        assert_ne!(first, second, "a token is never reused");
        assert!(unsafe { Probe::borrow(first, "probe") }.is_err());
        assert_eq!(unsafe { Probe::borrow(second, "probe") }.unwrap().0, 2);

        // And freeing the stale one again does not touch the live object.
        unsafe { drop_handle(first) };
        assert_eq!(unsafe { Probe::borrow(second, "probe") }.unwrap().0, 2);
        unsafe { drop_handle(second) };
    }

    #[test]
    fn a_handle_of_the_wrong_kind_is_refused() {
        let probe = Probe(1).into_handle();
        assert!(unsafe { Other::borrow(probe.cast(), "other") }.is_err());
        unsafe { drop_handle(probe) };
    }

    #[test]
    fn a_busy_handle_cannot_be_re_entered_or_freed() {
        let handle = Probe(3).into_handle();
        {
            let object = unsafe { Probe::borrow(handle, "probe") }.unwrap();
            let _busy = Busy::claim(&*object);

            // What a call from inside an event callback would do.
            let refused = unsafe { Probe::borrow(handle, "probe") };
            assert!(refused.unwrap_err().to_string().contains("re-entered"));
            unsafe { drop_handle(handle) };
        }
        // The turn is over, so both work again.
        assert_eq!(unsafe { Probe::borrow(handle, "probe") }.unwrap().0, 3);
        unsafe { drop_handle(handle) };
        assert!(unsafe { Probe::borrow(handle, "probe") }.is_err());
    }

    #[test]
    fn the_structs_are_the_size_the_header_says() {
        // 8 + 3×4 + 3×4 + 4×4 + 16, with nothing for the compiler to pad.
        assert_eq!(jarvis_sizeof_params(), 64);
        assert_eq!(jarvis_sizeof_progress(), 168);
    }

    #[test]
    fn defaults_match_the_shipped_config() {
        let mut p = JarvisParams {
            ..Default::default()
        };
        unsafe { jarvis_params_default(&mut p) };
        assert_eq!(p.max_tokens, 2048);
        assert_eq!(p.effort().unwrap(), "low");
        assert_eq!(p.has_seed, 0);
        assert!(p.generation().seed.is_none());
        assert!(p.render().unwrap().enable_thinking);
    }

    #[test]
    fn an_effort_the_model_does_not_know_is_refused() {
        let mut p = JarvisParams::default();
        p.set_effort("turbo");
        assert_eq!(p.effort().unwrap(), "turbo");
        assert!(p.render().is_err());
    }

    #[test]
    fn an_unterminated_effort_buffer_still_reads() {
        let p = JarvisParams {
            reasoning_effort: [b'x' as c_char; 16],
            ..Default::default()
        };
        assert_eq!(p.effort().unwrap(), "xxxxxxxxxxxxxxxx");
    }

    #[test]
    fn a_long_file_name_is_truncated_not_overrun() {
        let progress = rustcore::hub::DownloadProgress {
            current: Some("x".repeat(500)),
            bytes_done: 7,
            ..Default::default()
        };
        let c = JarvisProgress::from(&progress);
        assert_eq!(c.bytes_done, 7);
        assert_eq!(c.current[127], 0);
        assert_eq!(c.current[126], b'x' as c_char);
    }
}
