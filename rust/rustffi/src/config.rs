//! `config.jsonl` across the boundary.
//!
//! Values come back as JSON text rather than as a struct per key: the file is
//! already JSON, every language that would bind to this has a parser, and a new
//! key needs no new symbol.

use std::os::raw::c_char;

use anyhow::anyhow;
use rustcore::config::Config;

use crate::abi::{drop_handle, opt_str_arg, out_string, str_arg, Handle, JarvisParams};
use crate::error::guard;

/// An opaque handle to a loaded configuration.
pub struct JarvisConfig {
    inner: Config,
}

impl Handle for JarvisConfig {
    const TAG: u64 = 0x4a5f_636f_6e66_6967; // "J_config"
}

/// Load `config.jsonl` from `path`, or discover it when `path` is null.
///
/// Discovery is the same walk `rustcli` does: `JARVIS_CONFIG`, then upwards
/// from the working directory, then beside the binary, then the compiled-in
/// defaults — skipping any candidate another user could have written.
///
/// # Safety
/// `path` must be null or a NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn jarvis_config_open(path: *const c_char) -> *mut JarvisConfig {
    guard(std::ptr::null_mut(), || {
        let inner = match opt_str_arg(path, "path")? {
            Some(path) => Config::load(path)?,
            None => Config::discover(),
        };
        Ok(JarvisConfig { inner }.into_handle())
    })
}

/// # Safety
/// `cfg` must be null or a handle from [`jarvis_config_open`], not yet freed.
#[no_mangle]
pub unsafe extern "C" fn jarvis_config_free(cfg: *mut JarvisConfig) {
    drop_handle(cfg);
}

/// Where the configuration was read from, or null for the compiled-in copy.
///
/// # Safety
/// As [`jarvis_config_free`].
#[no_mangle]
pub unsafe extern "C" fn jarvis_config_source(cfg: *mut JarvisConfig) -> *mut c_char {
    guard(std::ptr::null_mut(), || {
        let cfg = JarvisConfig::borrow(cfg, "config")?;
        match &cfg.inner.source {
            Some(path) => Ok(out_string(path.display().to_string())),
            None => Ok(std::ptr::null_mut()),
        }
    })
}

/// One key as JSON text, or null when the key is absent.
///
/// # Safety
/// As [`jarvis_config_free`]; `key` must be a NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn jarvis_config_get_json(
    cfg: *mut JarvisConfig,
    key: *const c_char,
) -> *mut c_char {
    guard(std::ptr::null_mut(), || {
        let cfg = JarvisConfig::borrow(cfg, "config")?;
        let key = str_arg(key, "key")?;
        match cfg.inner.raw(key) {
            Some(value) => Ok(out_string(serde_json::to_string(value)?)),
            None => Ok(std::ptr::null_mut()),
        }
    })
}

/// The system prompt, or null when it is unset or blank.
///
/// # Safety
/// As [`jarvis_config_free`].
#[no_mangle]
pub unsafe extern "C" fn jarvis_config_system_prompt(cfg: *mut JarvisConfig) -> *mut c_char {
    guard(std::ptr::null_mut(), || {
        let cfg = JarvisConfig::borrow(cfg, "config")?;
        match cfg.inner.system_prompt() {
            Some(text) => Ok(out_string(text)),
            None => Ok(std::ptr::null_mut()),
        }
    })
}

/// Fill `out` with the `generation` and `thinking` settings from this config.
///
/// # Safety
/// As [`jarvis_config_free`]; `out` must point at a writable `JarvisParams`.
#[no_mangle]
pub unsafe extern "C" fn jarvis_config_params(
    cfg: *mut JarvisConfig,
    out: *mut JarvisParams,
) -> i32 {
    guard(-1, || {
        let cfg = JarvisConfig::borrow(cfg, "config")?;
        if out.is_null() {
            return Err(anyhow!("`out` must not be null"));
        }
        out.write(JarvisParams::from_settings(
            &cfg.inner.generation(),
            &cfg.inner.thinking(),
        ));
        Ok(0)
    })
}

/// The `model` block as JSON: `{"alias":…, "repo":…, "revision":…}`.
///
/// # Safety
/// As [`jarvis_config_free`].
#[no_mangle]
pub unsafe extern "C" fn jarvis_config_model_json(cfg: *mut JarvisConfig) -> *mut c_char {
    guard(std::ptr::null_mut(), || {
        let cfg = JarvisConfig::borrow(cfg, "config")?;
        let model = cfg.inner.model();
        let app = cfg.inner.app();
        Ok(out_string(serde_json::to_string(&serde_json::json!({
            "alias": model.alias,
            "repo": model.repo,
            "revision": model.revision,
            "app": { "name": app.name, "version": app.version },
        }))?))
    })
}
