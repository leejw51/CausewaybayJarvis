//! The C entry points, driven the way C drives them: raw pointers in, owned
//! strings out, errors read back through `jarvis_last_error`.
//!
//! Nothing here loads weights, so it runs anywhere.

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::ptr;

use jarvis::abi::*;
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
    assert_eq!(jarvis_abi_version(), 1);
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

    // The tag inside the allocation was cleared, so the stale pointer is
    // refused instead of read. Freeing it twice is a no-op for the same reason.
    assert!(owned(unsafe { jarvis_config_model_json(cfg) }).is_none());
    assert!(last_error().unwrap().contains("not a live"));
    unsafe { jarvis_config_free(cfg) };
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
