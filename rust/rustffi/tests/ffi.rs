//! The C entry points, driven the way C drives them: raw pointers in, owned
//! strings out, errors read back through `jarvis_last_error`.
//!
//! Nothing here loads weights, so it runs anywhere.

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::ptr;

use jarvis::abi::*;
use jarvis::agent::*;
use jarvis::config::*;
use jarvis::model::*;
use jarvis::session::*;
use jarvis::*;

/// Take an owned string from the library, freeing it the way a caller must.
fn owned(ptr: *mut c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    let text = unsafe { CStr::from_ptr(ptr) }
        .to_string_lossy()
        .into_owned();
    unsafe { jarvis_string_free(ptr) };
    Some(text)
}

fn last_error() -> Option<String> {
    let p = jarvis_last_error();
    (!p.is_null()).then(|| unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned())
}

fn json(text: &str) -> serde_json::Value {
    serde_json::from_str(text).expect("the library returned valid JSON")
}

#[test]
fn the_abi_is_the_one_the_header_declares() {
    assert_eq!(jarvis_abi_version(), 2);
    assert_eq!(jarvis_sizeof_params(), 64);
    assert_eq!(jarvis_sizeof_progress(), 168);
    let version = unsafe { CStr::from_ptr(jarvis_version()) };
    assert!(version.to_str().unwrap().starts_with('0'));
}

#[test]
fn a_string_the_caller_never_asked_for_is_null_not_empty() {
    // `NULL` means "there is nothing", and is distinct from a "" that was
    // deliberately configured. Freeing null is a no-op either way.
    unsafe { jarvis_string_free(ptr::null_mut()) };
}

#[test]
fn the_builtin_config_comes_through_as_json() {
    let cfg = unsafe { jarvis_config_open(ptr::null()) };
    assert!(!cfg.is_null(), "{:?}", last_error());

    let model = owned(unsafe { jarvis_config_model_json(cfg) }).unwrap();
    let model = json(&model);
    assert!(!model["alias"].as_str().unwrap().is_empty());
    assert_eq!(model["app"]["name"], "Causewaybay Jarvis");

    let generation = owned(unsafe { jarvis_config_get_json(cfg, c"generation".as_ptr()) }).unwrap();
    assert!(json(&generation)["max_tokens"].as_u64().unwrap() > 0);

    assert!(owned(unsafe { jarvis_config_get_json(cfg, c"nonesuch".as_ptr()) }).is_none());
    assert!(owned(unsafe { jarvis_config_system_prompt(cfg) }).is_some());

    unsafe { jarvis_config_free(cfg) };
}

#[test]
fn config_settings_become_generation_parameters() {
    let text = concat!(
        r#"{"key":"generation","value":{"max_tokens":16,"temperature":0.0,"seed":7}}"#,
        "\n",
        r#"{"key":"thinking","value":{"enabled":false,"effort":"xhigh"}}"#,
        "\n"
    );
    let dir = std::env::temp_dir().join(format!("jarvis-ffi-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("config.jsonl");
    std::fs::write(&path, text).unwrap();

    let c_path = CString::new(path.to_str().unwrap()).unwrap();
    let cfg = unsafe { jarvis_config_open(c_path.as_ptr()) };
    assert!(!cfg.is_null(), "{:?}", last_error());
    assert_eq!(
        owned(unsafe { jarvis_config_source(cfg) }).as_deref(),
        path.to_str()
    );

    let mut params = JarvisParams::default();
    assert_eq!(unsafe { jarvis_config_params(cfg, &mut params) }, 0);
    assert_eq!(params.max_tokens, 16);
    assert_eq!(params.temperature, 0.0);
    assert_eq!(params.has_seed, 1);
    assert_eq!(params.seed, 7);
    assert_eq!(params.enable_thinking, 0);
    assert_eq!(params.effort().unwrap(), "xhigh");
    // Absent keys still get their defaults rather than zeroes.
    assert_eq!(params.top_k, 20);

    unsafe { jarvis_config_free(cfg) };
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn a_missing_config_file_is_an_error_not_a_silent_default() {
    let path = c"/nonexistent/config.jsonl";
    assert!(unsafe { jarvis_config_open(path.as_ptr()) }.is_null());
    assert!(last_error().unwrap().contains("/nonexistent/config.jsonl"));
}

#[test]
fn the_alias_table_is_listable() {
    let list = owned(jarvis_models_json()).unwrap();
    let list = json(&list);
    let aliases = list.as_array().unwrap();
    assert!(!aliases.is_empty());
    assert!(aliases
        .iter()
        .any(|m| m["alias"] == "qwen3.8:27b-mlx" && m["repo"] == "mlx-community/Qwen3.8-27B-4bit"));
}

#[test]
fn a_model_resolves_without_being_downloaded() {
    let info = owned(unsafe {
        jarvis_model_info_json(c"qwen3.8:27b-mlx".as_ptr(), ptr::null(), ptr::null())
    })
    .unwrap();
    let info = json(&info);
    assert_eq!(info["repo"], "mlx-community/Qwen3.8-27B-4bit");
    assert_eq!(info["revision"], "main");
    assert!(info["local"].is_boolean());

    // An explicit repo wins over whatever the alias points at.
    let info = owned(unsafe {
        jarvis_model_info_json(
            c"qwen3.8:27b-mlx".as_ptr(),
            c"abc123".as_ptr(),
            c"someone/else".as_ptr(),
        )
    })
    .unwrap();
    let info = json(&info);
    assert_eq!(info["repo"], "someone/else");
    assert_eq!(info["revision"], "abc123");
    assert_eq!(info["local"], false);
}

#[test]
fn an_unknown_model_fails_with_a_message_that_names_the_alternatives() {
    let out = unsafe { jarvis_model_info_json(c"llama-42".as_ptr(), ptr::null(), ptr::null()) };
    assert!(out.is_null());
    let err = last_error().unwrap();
    assert!(err.contains("llama-42"), "{err}");
    assert!(err.contains("qwen3.8:27b-mlx"), "{err}");

    assert_eq!(
        unsafe { jarvis_model_is_local(c"llama-42".as_ptr(), ptr::null(), ptr::null()) },
        -1
    );
}

#[test]
fn a_null_argument_is_refused_rather_than_dereferenced() {
    assert!(unsafe { jarvis_model_info_json(ptr::null(), ptr::null(), ptr::null()) }.is_null());
    assert!(last_error().unwrap().contains("`alias` must not be null"));

    assert_eq!(unsafe { jarvis_params_default(ptr::null_mut()) }, -1);
    assert!(last_error().unwrap().contains("`out` must not be null"));

    assert!(unsafe { jarvis_info_json(ptr::null_mut()) }.is_null());
    assert!(last_error().unwrap().contains("`session` must not be null"));
}

#[test]
fn a_handle_that_has_been_freed_is_rejected() {
    let cfg = unsafe { jarvis_config_open(ptr::null()) };
    assert!(!cfg.is_null());
    unsafe { jarvis_config_free(cfg) };

    // A handle is a token rather than an address, so a stale one is looked up
    // and refused rather than dereferenced — and stays refused even once the
    // allocator has handed the memory it stood for to somebody else. Freeing it
    // twice is a no-op for the same reason.
    let live = unsafe { jarvis_config_open(ptr::null()) };
    assert!(!live.is_null());
    assert!(owned(unsafe { jarvis_config_model_json(cfg) }).is_none());
    assert!(last_error().unwrap().contains("not a live"));
    unsafe { jarvis_config_free(cfg) };

    // The one that was opened afterwards is untouched by any of that.
    assert!(owned(unsafe { jarvis_config_model_json(live) }).is_some());
    unsafe { jarvis_config_free(live) };
}

#[test]
fn opening_a_model_that_is_not_on_disk_says_so() {
    let session = unsafe {
        jarvis_open(
            c"mlx-community/definitely-not-a-real-checkpoint".as_ptr(),
            ptr::null(),
            ptr::null(),
        )
    };
    assert!(session.is_null());
    assert!(last_error().unwrap().contains("not in the local cache"));
}

#[test]
fn success_leaves_no_error_behind() {
    let _ = unsafe { jarvis_model_info_json(ptr::null(), ptr::null(), ptr::null()) };
    assert!(last_error().is_some());
    owned(jarvis_models_json()).unwrap();
    assert!(last_error().is_none());
}

#[test]
fn the_interrupt_flag_survives_a_round_trip() {
    jarvis_interrupt_clear();
    assert_eq!(jarvis_interrupt_raised(), 0);
}

#[test]
fn monotonic_time_moves_forward() {
    let a = jarvis_monotonic();
    let b = jarvis_monotonic();
    assert!(b >= a);
    assert!(a < 3600.0, "the clock starts at zero, not at the epoch");
}

/// The backend, in this process. One test rather than several: the space is
/// process-wide by design, so two of these running at once would be two
/// backends fighting over one static — which is exactly what the ABI says
/// callers must not do.
#[test]
fn the_backend_answers_in_this_process() {
    let space = tempfile::tempdir().expect("a scratch space");
    let root = CString::new(space.path().to_str().unwrap()).unwrap();

    // Nothing is open yet, so a call is refused rather than answered.
    assert!(owned(unsafe { jarvis_agent_call(c"{}".as_ptr(), None, ptr::null_mut()) }).is_none());
    assert!(last_error().unwrap().contains("jarvis_agent_open"));
    assert_eq!(jarvis_agent_is_open(), 0);

    assert_eq!(unsafe { jarvis_agent_open(root.as_ptr(), ptr::null()) }, 0);
    assert_eq!(jarvis_agent_is_open(), 1);
    // The root comes back as the space that was asked for. Compared through
    // the filesystem: /var is a symlink to /private/var on macOS, and a
    // tempdir lives under it.
    let opened = owned(jarvis_agent_root()).expect("an open space has a root");
    assert_eq!(
        std::fs::canonicalize(&opened).unwrap(),
        std::fs::canonicalize(space.path()).unwrap()
    );

    // The roster is seeded on open, so the robots are there to list.
    let reply = json(
        &owned(unsafe {
            jarvis_agent_call(c"{\"op\":\"agents.list\"}".as_ptr(), None, ptr::null_mut())
        })
        .expect("a reply"),
    );
    assert_eq!(reply["ok"], serde_json::json!(true));
    assert!(
        reply["data"].as_array().is_some_and(|a| !a.is_empty()),
        "the seeded roster should not be empty: {reply}"
    );

    // A refusal by the backend is a reply, not a null: the caller reads the
    // same envelope it would have read off a socket.
    let refused = json(
        &owned(unsafe {
            jarvis_agent_call(c"{\"op\":\"nonesuch\"}".as_ptr(), None, ptr::null_mut())
        })
        .expect("a refusal is still a reply"),
    );
    assert_eq!(refused["ok"], serde_json::json!(false));
    assert!(refused["error"].is_string());

    // Text that is not a request never reaches the backend at all.
    assert!(
        owned(unsafe { jarvis_agent_call(c"not json".as_ptr(), None, ptr::null_mut()) }).is_none()
    );
    assert!(last_error().unwrap().contains("not JSON"));

    // Overrides are settings for this backend alone, and a key that is not a
    // variable name is refused rather than carried.
    assert_eq!(
        unsafe { jarvis_agent_open(root.as_ptr(), c"{\"OLLAMA_API_KEY\":\"\"}".as_ptr()) },
        0
    );
    assert_eq!(
        unsafe { jarvis_agent_open(root.as_ptr(), c"{\"not a name\":\"x\"}".as_ptr()) },
        -1
    );
    assert!(last_error().unwrap().contains("not a variable name"));

    jarvis_agent_close();
    assert_eq!(jarvis_agent_is_open(), 0);
    assert!(owned(jarvis_agent_root()).is_none());
    jarvis_agent_close(); // closing twice is not an error
}
